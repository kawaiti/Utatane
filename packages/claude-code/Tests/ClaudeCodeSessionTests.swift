import Foundation
import Testing
@testable import UtataneClaudeCode

/// Records calls and lets the test drive the stdout stream line by line.
private actor FakeClaudeProcess: ClaudeCodeProcessing {
    private(set) var startResumes: [String?] = []
    private(set) var sentMessages: [String] = []
    private(set) var interruptCount = 0
    private(set) var terminateCount = 0
    private var stdout: AsyncStream<String>.Continuation?

    func start(_ configuration: ClaudeCodeLaunchConfiguration, resume sessionID: String?) async throws -> AsyncStream<String> {
        startResumes.append(sessionID)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        stdout = continuation
        return stream
    }

    func send(userMessage: String) async throws {
        sentMessages.append(userMessage)
    }

    func interrupt() async {
        interruptCount += 1
    }

    func terminate() async {
        terminateCount += 1
    }

    func emit(_ line: String) {
        stdout?.yield(line)
    }

    func endStdout() {
        stdout?.finish()
    }
}

private let initLine = #"{"type":"system","subtype":"init","session_id":"s1"}"#
private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"完了","session_id":"s1"}"#

private func makeConfiguration() -> ClaudeCodeLaunchConfiguration {
    ClaudeCodeLaunchConfiguration(
        executable: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        workingDirectory: URL(fileURLWithPath: "/tmp/project"),
        model: nil,
        permissionMode: .default,
        mcpHelperPath: "/Apps/utatane-mcp"
    )
}

private func makeSession(
    _ process: FakeClaudeProcess,
    configuration: ClaudeCodeLaunchConfiguration? = makeConfiguration(),
    approvalTimeout: Duration = .seconds(45),
    directoryExists: Bool = true
) -> ClaudeCodeSession {
    ClaudeCodeSession(configuration: configuration, process: process, approvalTimeout: approvalTimeout, directoryExists: { _ in directoryExists })
}

/// Waits for a state that is reached without emitting an event (no fixed sleeps).
private func waitForState(_ expected: ClaudeCodeSessionState, of session: ClaudeCodeSession) async {
    while await session.state != expected {
        await Task.yield()
    }
}

/// Consumes the stream until an event matches, returning it.
private func nextEvent(
    _ iterator: inout AsyncStream<ClaudeCodeEvent>.AsyncIterator,
    where predicate: (ClaudeCodeEvent) -> Bool
) async -> ClaudeCodeEvent? {
    while let event = await iterator.next() {
        if predicate(event) { return event }
    }
    return nil
}

private func isFinished(_ event: ClaudeCodeEvent) -> Bool {
    if case .finished = event { return true }
    return false
}

@Test func `submit starts the process, tracks the session id and returns to idle on result`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    var events = await session.events().makeAsyncIterator()

    try await session.submit("ファイル一覧を見て")
    #expect(await session.state == .running)
    #expect(await process.startResumes == [nil])
    #expect(await process.sentMessages == ["ファイル一覧を見て"])

    await process.emit(initLine)
    #expect(await nextEvent(&events) { _ in true } == .sessionStarted(id: "s1"))
    #expect(await session.sessionID == "s1")

    await process.emit(resultLine)
    #expect(await nextEvent(&events, where: isFinished) == .finished(result: "完了", isError: false, sessionID: "s1"))
    #expect(await session.state == .idle)

    // The process stays resident: the next instruction is only sent.
    try await session.submit("次へ")
    #expect(await process.startResumes == [nil])
    #expect(await process.sentMessages == ["ファイル一覧を見て", "次へ"])
}

@Test func `submit while running or awaiting approval throws busy`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    try await session.submit("一つ目")
    await #expect(throws: ClaudeCodeError.busy) { try await session.submit("二つ目") }

    async let decision = session.requestApproval(toolName: "Bash", command: "ls")
    await waitForState(.awaitingApproval, of: session)
    await #expect(throws: ClaudeCodeError.busy) { try await session.submit("三つ目") }
    await session.resolveApproval(allow: false)
    _ = await decision
    #expect(await process.sentMessages == ["一つ目"])
}

@Test func `submit refuses a missing working directory without starting the process`() async {
    let process = FakeClaudeProcess()
    let session = makeSession(process, directoryExists: false)
    await #expect(throws: ClaudeCodeError.workingDirectoryMissing) { try await session.submit("作業して") }
    #expect(await process.startResumes.isEmpty)
    #expect(await process.sentMessages.isEmpty)
    #expect(await session.state == .idle)
}

@Test func `submit without a configuration throws executable not found`() async {
    let process = FakeClaudeProcess()
    let session = makeSession(process, configuration: nil)
    await #expect(throws: ClaudeCodeError.executableNotFound) { try await session.submit("作業して") }
    #expect(await process.startResumes.isEmpty)
    #expect(await session.state == .idle)
}

@Test func `approval waits in awaiting approval and resolves to allow`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    try await session.submit("編集して")

    async let decision = session.requestApproval(toolName: "Edit", command: nil)
    await waitForState(.awaitingApproval, of: session)
    await session.resolveApproval(allow: true)
    await session.resolveApproval(allow: false) // second resolve is ignored
    #expect(await decision == .allow)
    #expect(await session.state == .running)
}

@Test func `approval resolved with deny returns deny`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    try await session.submit("消して")

    async let decision = session.requestApproval(toolName: "Bash", command: "rm -rf build")
    await waitForState(.awaitingApproval, of: session)
    await session.resolveApproval(allow: false)
    guard case .deny = await decision else {
        Issue.record("expected deny")
        return
    }
    #expect(await session.state == .running)
}

@Test func `approval times out as deny and cannot be resolved afterwards`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process, approvalTimeout: .milliseconds(50))
    try await session.submit("編集して")

    let decision = await session.requestApproval(toolName: "Write", command: nil)
    guard case .deny = decision else {
        Issue.record("expected deny after timeout, got \(decision)")
        return
    }
    #expect(await session.state == .running)
    await session.resolveApproval(allow: true)
    #expect(await session.state == .running)
}

@Test func `resolve approval without a pending request does nothing`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    await session.resolveApproval(allow: true)
    #expect(await session.state == .idle)

    try await session.submit("作業して")
    await session.resolveApproval(allow: false)
    #expect(await session.state == .running)
}

@Test func `stdout ending without result finishes with an error and the next submit resumes`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    var events = await session.events().makeAsyncIterator()
    try await session.submit("作業して")
    await process.emit(initLine)
    await process.endStdout()

    #expect(await nextEvent(&events, where: isFinished) == .finished(result: "プロセスが終了しました", isError: true, sessionID: "s1"))
    #expect(await session.state == .idle)

    try await session.submit("続けて")
    #expect(await process.startResumes == [nil, "s1"])
    #expect(await process.sentMessages == ["作業して", "続けて"])
}

@Test func `stdout ending while awaiting approval denies the pending request`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    var events = await session.events().makeAsyncIterator()
    try await session.submit("作業して")

    async let decision = session.requestApproval(toolName: "Bash", command: "make")
    await waitForState(.awaitingApproval, of: session)
    await process.endStdout()
    guard case .deny = await decision else {
        Issue.record("expected deny")
        return
    }
    #expect(await nextEvent(&events, where: isFinished) == .finished(result: "プロセスが終了しました", isError: true, sessionID: nil))
    #expect(await session.state == .idle)
}

@Test func `interrupt forwards to the process and denies a pending approval`() async throws {
    let process = FakeClaudeProcess()
    let session = makeSession(process)
    try await session.submit("作業して")

    async let decision = session.requestApproval(toolName: "Bash", command: "make")
    await waitForState(.awaitingApproval, of: session)
    await session.interrupt()
    guard case .deny = await decision else {
        Issue.record("expected deny")
        return
    }
    #expect(await process.interruptCount == 1)
    #expect(await session.state == .running)
}

@Test func `approval requested while idle is denied immediately`() async {
    let session = makeSession(FakeClaudeProcess())
    guard case .deny = await session.requestApproval(toolName: "Bash", command: "ls") else {
        Issue.record("expected deny")
        return
    }
    #expect(await session.state == .idle)
}
