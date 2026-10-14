import Foundation

public enum ClaudeCodeProcessError: Error, Equatable {
    case notRunning
}

/// Splits a byte stream into UTF-8 lines. Used from a single serial readability handler.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    /// Appends `data` and returns the complete, non-empty lines it finished.
    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if let line = Self.decode(lineData) {
                lines.append(line)
            }
        }
        return lines
    }

    /// Returns the trailing line that had no newline, if any.
    func flush() -> String? {
        defer { buffer.removeAll() }
        return Self.decode(buffer)
    }

    private static func decode(_ data: Data) -> String? {
        let line = String(decoding: data, as: UTF8.self)
        return line.isEmpty ? nil : line
    }
}

/// Keeps the last `limit` bytes written to standard error. Appended to from one readability handler.
private final class StandardErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()
    /// Signalled once standard error reaches EOF.
    let finished = DispatchSemaphore(value: 0)

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > limit {
                buffer.removeFirst(buffer.count - limit)
            }
        }
    }

    var text: String {
        let data = lock.withLock { buffer }
        // The cut may land inside a UTF-8 sequence; drop the resulting replacement characters at the start.
        return String(String(decoding: data, as: UTF8.self).drop { $0 == "\u{FFFD}" })
    }
}

/// Runs one resident `claude` child process via `Foundation.Process`.
///
/// Calling `start` while a process is already running terminates the old one first (its stream ends),
/// then launches the new one.
public final class ClaudeCodeProcess: ClaudeCodeProcessing, @unchecked Sendable {
    /// Bytes of standard error kept for `standardErrorTail()`.
    public static let standardErrorLimit = 4096
    /// How long the end of stdout waits for standard error to reach EOF, so the tail is complete.
    private static let standardErrorDrainTimeout: DispatchTimeInterval = .seconds(1)

    private struct Running {
        let process: Process
        let stdin: FileHandle
        let continuation: AsyncStream<String>.Continuation
    }

    private let lock = NSLock()
    private var running: Running?
    /// Standard error of the most recently started process; kept after it exits.
    private var standardError: StandardErrorTail?

    public init() {
        // A write to a closed pipe must surface as a thrown error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    public func start(_ configuration: ClaudeCodeLaunchConfiguration, resume sessionID: String?) async throws -> AsyncStream<String> {
        await terminate()

        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments(resume: sessionID)
        process.currentDirectoryURL = configuration.workingDirectory
        process.environment = ClaudeCodeLaunchEnvironment.environment(
            executable: configuration.executable,
            inheriting: ProcessInfo.processInfo.environment
        )
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let tail = StandardErrorTail(limit: Self.standardErrorLimit)
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                tail.finished.signal()
                return
            }
            tail.append(data)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let splitter = LineSplitter()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Let standard error catch up, so whoever sees the stream end can read the complete tail.
                _ = tail.finished.wait(timeout: .now() + Self.standardErrorDrainTimeout)
                if let last = splitter.flush() {
                    continuation.yield(last)
                }
                continuation.finish()
                return
            }
            for line in splitter.append(data) {
                continuation.yield(line)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            continuation.finish()
            throw error
        }
        // The parent's copies of the child-side ends must be closed so EOF can be observed.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let current = Running(process: process, stdin: stdinPipe.fileHandleForWriting, continuation: continuation)
        lock.withLock {
            running = current
            standardError = tail
        }
        return stream
    }

    public func standardErrorTail() async -> String {
        lock.withLock { standardError }?.text ?? ""
    }

    public func send(userMessage: String) async throws {
        let stdin = lock.withLock { running?.stdin }
        guard let stdin else { throw ClaudeCodeProcessError.notRunning }
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": userMessage]]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    public func interrupt() async {
        let process = lock.withLock { running?.process }
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
    }

    public func terminate() async {
        let current = lock.withLock {
            let current = running
            running = nil
            return current
        }
        guard let current else { return }
        try? current.stdin.close()
        if current.process.isRunning {
            current.process.terminate()
        }
        current.process.waitUntilExit()
        current.continuation.finish()
    }
}
