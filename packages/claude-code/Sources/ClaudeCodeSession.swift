import Foundation

/// Drives one resident `claude` process speaking stream-json over stdin/stdout.
public protocol ClaudeCodeProcessing: Sendable {
    /// Launches the process and returns its stdout split into lines. The stream ends when the process exits.
    func start(_ configuration: ClaudeCodeLaunchConfiguration, resume sessionID: String?) async throws -> AsyncStream<String>
    func send(userMessage: String) async throws
    func interrupt() async
    func terminate() async
    /// The last few kilobytes the process wrote to standard error, for explaining an abnormal exit.
    func standardErrorTail() async -> String
}

/// Identifies one approval request, so a decision can only resolve the request it was made for.
/// Ids are unique within the app process, across sessions, so an id from a retired session never matches a new one.
public struct ClaudeCodeApprovalID: Hashable, Sendable {
    let rawValue: UInt64

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UInt64 = 0

        func next() -> UInt64 {
            lock.withLock {
                last += 1
                return last
            }
        }
    }

    private static let counter = Counter()

    static func next() -> ClaudeCodeApprovalID {
        ClaudeCodeApprovalID(rawValue: counter.next())
    }
}

public enum ApprovalDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
}

public enum ClaudeCodeError: Error, Equatable {
    case busy
    case workingDirectoryMissing
    case executableNotFound
}

public actor ClaudeCodeSession {
    static let processEndedMessage = "プロセスが終了しました"
    static let deniedByUserReason = "利用者が拒否しました"
    static let timedOutReason = "承認がタイムアウトしました"
    static let interruptedReason = "中断されました"
    static let notRunningReason = "実行中の指示がないため拒否しました"
    /// The reason returned for every command `ApprovalPolicy` judges dangerous.
    public static let dangerousCommandReason = "危険なコマンドのため実行できません"

    private struct PendingApproval {
        let id: ClaudeCodeApprovalID
        let continuation: CheckedContinuation<ApprovalDecision, Never>
        var timeout: Task<Void, Never>?
    }

    public private(set) var state: ClaudeCodeSessionState = .idle
    public private(set) var sessionID: String?

    private let configuration: ClaudeCodeLaunchConfiguration?
    private let process: any ClaudeCodeProcessing
    private let approvalTimeout: Duration
    private let directoryExists: @Sendable (URL) -> Bool

    private let eventStream: AsyncStream<ClaudeCodeEvent>
    private let eventContinuation: AsyncStream<ClaudeCodeEvent>.Continuation

    /// Incremented per launched process so a stale stdout consumer cannot touch the current one.
    private var processGeneration: UInt64 = 0
    private var isProcessActive = false
    private var pendingApproval: PendingApproval?

    public init(
        configuration: ClaudeCodeLaunchConfiguration?,
        process: any ClaudeCodeProcessing,
        initialSessionID: String? = nil,
        approvalTimeout: Duration = .seconds(45),
        directoryExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.configuration = configuration
        self.process = process
        // A stored id from an earlier run: the first launch resumes that conversation with `--resume`.
        sessionID = initialSessionID
        self.approvalTimeout = approvalTimeout
        self.directoryExists = directoryExists
        // One unbounded stream created up front: events emitted before anyone subscribes are buffered, not lost.
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: ClaudeCodeEvent.self)
    }

    deinit {
        eventContinuation.finish()
    }

    /// The session's single event stream. It supports one consumer; every call returns the same stream.
    public func events() -> AsyncStream<ClaudeCodeEvent> {
        eventStream
    }

    /// Sends an instruction, launching (or relaunching with `--resume`) the process when none is running.
    public func submit(_ instruction: String) async throws {
        guard state == .idle else { throw ClaudeCodeError.busy }
        guard let configuration else { throw ClaudeCodeError.executableNotFound }
        guard directoryExists(configuration.workingDirectory) else { throw ClaudeCodeError.workingDirectoryMissing }
        // Claim the session before suspending so a reentrant submit sees `.busy`.
        state = .running
        do {
            if !isProcessActive {
                let lines = try await process.start(configuration, resume: sessionID)
                processGeneration += 1
                isProcessActive = true
                let generation = processGeneration
                Task { await self.consume(lines, generation: generation) }
            }
            try await process.send(userMessage: instruction)
        } catch {
            if state != .idle {
                state = .idle
            }
            throw error
        }
    }

    /// Suspends until the user decides, the timeout elapses (deny), or the session is interrupted (deny).
    ///
    /// A command `ApprovalPolicy` judges dangerous is denied at once with `dangerousCommandReason` and reported
    /// as `.commandBlocked`; it never becomes pending, so no button, voice answer or timeout can allow it.
    /// `presented` receives the request's id once it is pending; only `resolveApproval(id:allow:)` with that id
    /// can decide it. A request that is denied immediately (dangerous, not running, another one pending) is never
    /// presented.
    public func requestApproval(
        toolName: String,
        command: String?,
        presented: @escaping @Sendable (ClaudeCodeApprovalID) -> Void = { _ in }
    ) async -> ApprovalDecision {
        // Checked before anything else, so a dangerous request leaves the state and any pending approval untouched.
        if ApprovalPolicy.isDangerous(toolName: toolName, command: command) {
            eventContinuation.yield(.commandBlocked(toolName: toolName, command: command))
            return .deny(reason: Self.dangerousCommandReason)
        }
        guard state == .running, pendingApproval == nil else {
            return .deny(reason: Self.notRunningReason)
        }
        let id = ClaudeCodeApprovalID.next()
        state = .awaitingApproval
        return await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(id: id, continuation: continuation)
            presented(id)
            let timeout = approvalTimeout
            // Inherits the actor's isolation, so the completion runs on the actor.
            pendingApproval?.timeout = Task {
                guard await (try? Task.sleep(for: timeout)) != nil else { return }
                self.completeApproval(id: id, with: .deny(reason: Self.timedOutReason))
            }
        }
    }

    /// Resolves the approval `id` if it is still the pending one. A stale id (already resolved, timed out,
    /// interrupted, or an earlier request) does nothing, so a late answer can never decide a newer request.
    public func resolveApproval(id: ClaudeCodeApprovalID, allow: Bool) {
        completeApproval(id: id, with: allow ? .allow : .deny(reason: Self.deniedByUserReason))
    }

    /// Interrupts the current turn and denies any pending approval.
    public func interrupt() async {
        if let pendingApproval {
            completeApproval(id: pendingApproval.id, with: .deny(reason: Self.interruptedReason))
        }
        await process.interrupt()
    }

    /// The only place a continuation is resumed: it is cleared first, so a racing resolve/timeout/interrupt is a no-op.
    private func completeApproval(id: ClaudeCodeApprovalID, with decision: ApprovalDecision) {
        guard let pending = pendingApproval, pending.id == id else { return }
        pendingApproval = nil
        pending.timeout?.cancel()
        if state == .awaitingApproval {
            state = .running
        }
        pending.continuation.resume(returning: decision)
    }

    private func consume(_ lines: AsyncStream<String>, generation: UInt64) async {
        for await line in lines {
            guard generation == processGeneration else { return }
            for event in ClaudeCodeEventParser.parse(line: line) {
                apply(event)
            }
        }
        await processEnded(generation: generation)
    }

    /// Updates state before yielding, so a consumer seeing the event also sees its effect.
    private func apply(_ event: ClaudeCodeEvent) {
        switch event {
        case let .sessionStarted(id):
            sessionID = id
        case let .finished(_, _, id):
            if let id {
                sessionID = id
            }
            if let pendingApproval {
                completeApproval(id: pendingApproval.id, with: .deny(reason: Self.processEndedMessage))
            }
            state = .idle
        case .assistantText, .toolUse, .toolResult, .commandBlocked:
            break
        }
        eventContinuation.yield(event)
    }

    private func processEnded(generation: UInt64) async {
        guard generation == processGeneration else { return }
        isProcessActive = false
        if let pendingApproval {
            completeApproval(id: pendingApproval.id, with: .deny(reason: Self.processEndedMessage))
        }
        guard state != .idle else { return }
        // The state stays `.running` while standard error is read, so a reentrant submit is refused as busy.
        let standardError = await process.standardErrorTail().trimmingCharacters(in: .whitespacesAndNewlines)
        guard generation == processGeneration else { return }
        if let pendingApproval {
            completeApproval(id: pendingApproval.id, with: .deny(reason: Self.processEndedMessage))
        }
        guard state != .idle else { return }
        state = .idle
        let result = standardError.isEmpty ? Self.processEndedMessage : Self.processEndedMessage + "\n" + standardError
        eventContinuation.yield(.finished(result: result, isError: true, sessionID: sessionID))
    }
}
