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

/// Runs one resident `claude` child process via `Foundation.Process`.
///
/// Calling `start` while a process is already running terminates the old one first (its stream ends),
/// then launches the new one.
public final class ClaudeCodeProcess: ClaudeCodeProcessing, @unchecked Sendable {
    private struct Running {
        let process: Process
        let stdin: FileHandle
        let continuation: AsyncStream<String>.Continuation
    }

    private let lock = NSLock()
    private var running: Running?

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
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let splitter = LineSplitter()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
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
            continuation.finish()
            throw error
        }
        // The parent's copies of the child-side ends must be closed so EOF can be observed.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()

        let current = Running(process: process, stdin: stdinPipe.fileHandleForWriting, continuation: continuation)
        lock.withLock { running = current }
        return stream
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
