import AppKit
import Combine
import Foundation
import UtataneClaudeCode
import UtataneNetwork

/// Connects the ghost (speech), the transcript window and push-to-talk to one resident Claude Code session.
@MainActor
final class ClaudeCodeController {
    /// Opens the Claude Code settings page, used when `claude` or the working directory is missing.
    var onOpenSettings: (() -> Void)?

    private let settings: ClaudeCodeSettings
    private let speak: (String) -> Void
    private let transcript = ClaudeCodeTranscriptModel()
    private lazy var windowController = ClaudeCodeTranscriptWindowController(model: transcript)
    private let voiceInput = ClaudeCodeVoiceInput()
    private let router = VoiceCommandRouter()

    private var session: ClaudeCodeSession?
    private var process: ClaudeCodeProcess?
    private var sessionConfiguration: ClaudeCodeLaunchConfiguration?
    private var eventTask: Task<Void, Never>?
    private var lastSessionID: String?
    /// The current session was created to resume a stored conversation and has not reported its start yet.
    private var isAwaitingResumedStart = false
    /// Set by `shutdown()`: nothing is routed or launched afterwards.
    private var isShutDown = false
    /// An instruction heard by voice, waiting for「はい」/「いいえ」after being read back.
    private var pendingReadback: String?
    /// The approval shown on screen and the session it belongs to. At most one at a time.
    private var currentApproval: (request: ClaudeCodeApprovalRequest, session: ClaudeCodeSession)?
    /// Suppresses repeating the same progress phrase for consecutive tool calls.
    private var lastProgressPhrase: String?
    private var settingsObservation: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    private var showObserver: NSObjectProtocol?
    private var hasShownAccessibilityNotice = false

    init(settings: ClaudeCodeSettings, speak: @escaping (String) -> Void) {
        self.settings = settings
        self.speak = speak
        transcript.onSubmit = { [weak self] text in self?.submitText(text) }
        transcript.onResolve = { [weak self] id, allow in self?.resolveApproval(id, allow: allow) }
        transcript.onInterrupt = { [weak self] in self?.interrupt() }
        transcript.onNewSession = { [weak self] in self?.startNewSession() }
        // Bind each hold-to-talk press to the approval pending at that moment (if any).
        voiceInput.onHoldBegan = { [weak self] in self?.currentApproval?.request.approvalID }
        voiceInput.onUtterance = { [weak self] text, boundApproval in
            self?.handleUtterance(text, boundTo: boundApproval)
        }
        voiceInput.onNothingHeard = { [weak self] in
            guard let self, self.acceptsVoice else { return }
            self.speak("聞き取れませんでした")
        }
        voiceInput.onListeningChange = { [weak self] listening in self?.transcript.isListening = listening }
        voiceInput.onFailure = { [weak self] message in self?.notify(message) }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        // Posted by the「Claude Code…」menu item.
        showObserver = NotificationCenter.default.addObserver(
            forName: .showUtataneClaudeCode,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTranscript() }
        }
    }

    /// Follows the voice input setting: the hotkey is registered only while it is on.
    func startIfEnabled() {
        guard settingsObservation == nil else { return }
        settingsObservation = settings.$voiceInputEnabled
            .combineLatest(settings.$hotkey)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, hotkey in
                MainActor.assumeIsolated { self?.configureVoiceInput(enabled: enabled, hotkey: hotkey) }
            }
    }

    /// Sends typed text as is; it is not read back.
    func submitText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingReadback = nil
        send(trimmed)
    }

    func showTranscript() {
        windowController.showTranscript()
    }

    /// Stops listening and terminates the `claude` process.
    func shutdown() {
        isShutDown = true
        settingsObservation = nil
        voiceInput.disable()
        pendingReadback = nil
        eventTask?.cancel()
        eventTask = nil
        session = nil
        sessionConfiguration = nil
        guard let process else { return }
        self.process = nil
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await process.terminate()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 3)
    }

    // MARK: - Approval

    /// Handles the `utatane-mcp` approve tool. Only an explicit user approval returns `"allow": true`.
    func handleApproveTool(payload: [String: Any]) async -> SSTPResponse {
        guard let session, currentApproval == nil else {
            return ClaudeCodeApprovalText.response(allow: false, reason: "承認を受け付けられる状態ではないため拒否しました")
        }
        guard let toolName = payload["tool_name"] as? String, !toolName.isEmpty else {
            return ClaudeCodeApprovalText.response(allow: false, reason: "要求の形式が不正なため拒否しました")
        }
        // The model can call the approve tool itself, so requests outside a running instruction are refused.
        guard await session.state == .running, self.session === session, currentApproval == nil else {
            return ClaudeCodeApprovalText.response(allow: false, reason: "実行中の指示がないため拒否しました")
        }
        let input = payload["input"] as? [String: Any] ?? [:]
        let command = input["command"] as? String
        let request = ClaudeCodeApprovalRequest(
            toolName: toolName,
            command: command,
            filePath: (input["file_path"] as? String) ?? (input["notebook_path"] as? String),
            isDangerous: ApprovalPolicy.isDangerous(toolName: toolName, command: command)
        )
        currentApproval = (request, session)
        transcript.pendingApproval = request
        transcript.append(.approval, ClaudeCodeApprovalText.describe(request))
        showTranscript()
        speak(ClaudeCodeApprovalText.prompt(for: request))

        let requestID = request.id
        let decision = await session.requestApproval(toolName: toolName, command: command) { [weak self] approvalID in
            Task { @MainActor in self?.approvalPresented(requestID: requestID, approvalID: approvalID) }
        }
        if currentApproval?.request.id == request.id {
            currentApproval = nil
            transcript.pendingApproval = nil
        }
        switch decision {
        case .allow:
            transcript.append(.approval, "許可しました")
            return ClaudeCodeApprovalText.response(allow: true, reason: nil)
        case let .deny(reason):
            transcript.append(.approval, "拒否しました: \(reason)")
            return ClaudeCodeApprovalText.response(allow: false, reason: reason)
        }
    }

    /// Records the session's id for the request on screen; until then its buttons stay disabled.
    private func approvalPresented(requestID: UUID, approvalID: ClaudeCodeApprovalID) {
        guard let current = currentApproval, current.request.id == requestID else { return }
        var request = current.request
        request.approvalID = approvalID
        currentApproval = (request, current.session)
        transcript.pendingApproval = request
    }

    /// Resolves only the approval `id`, and only while it is the one on screen; anything else is ignored.
    private func resolveApproval(_ id: ClaudeCodeApprovalID, allow: Bool) {
        guard let (request, session) = currentApproval, request.approvalID == id else { return }
        Task { await session.resolveApproval(id: id, allow: allow) }
    }

    // MARK: - Voice

    private func configureVoiceInput(enabled: Bool, hotkey: ClaudeCodeHotkey) {
        guard enabled else {
            voiceInput.disable()
            pendingReadback = nil
            transcript.isListening = false
            return
        }
        voiceInput.enable(hotkey: hotkey)
        if !ClaudeCodeHotkeyMonitor.canObserveOtherApps, !hasShownAccessibilityNotice {
            hasShownAccessibilityNotice = true
            transcript.append(.notice, "ほかのアプリを使っている間もホットキーで話しかけるには、システム設定の「プライバシーとセキュリティ」>「アクセシビリティ」でUtataneを許可してください。")
        }
    }

    /// Whether a spoken utterance may still be acted on: voice input is on and the app is not quitting.
    private var acceptsVoice: Bool {
        !isShutDown && settings.voiceInputEnabled && voiceInput.isEnabled
    }

    /// `boundApproval` is the approval that was pending when the hotkey was pressed for this utterance.
    private func handleUtterance(_ text: String, boundTo boundApproval: ClaudeCodeApprovalID?) {
        guard acceptsVoice else { return }
        transcript.append(.heard, text)
        Task {
            let state = await session?.state ?? .idle
            guard acceptsVoice else { return }
            if boundApproval != nil || currentApproval != nil, answerApproval(text, boundTo: boundApproval) {
                return
            }
            route(router.route(text, state: state, awaitingReadback: pendingReadback != nil))
        }
    }

    /// Applies a spoken「はい」/「いいえ」to an approval. Returns whether the utterance was consumed as an answer,
    /// including a stale answer that is dropped so it is never taken as an instruction or a readback reply.
    private func answerApproval(_ text: String, boundTo boundApproval: ClaudeCodeApprovalID?) -> Bool {
        let answer = router.route(text, state: .awaitingApproval, awaitingReadback: false)
        let current = currentApproval?.request
        if current != nil, current?.approvalID == nil, answer == .approve || answer == .deny {
            return true // The request is not registered yet; an answer cannot be bound to it.
        }
        switch VoiceApprovalBinding.action(
            for: answer,
            listeningBoundTo: boundApproval,
            current: current?.approvalID,
            currentIsDangerous: current?.isDangerous ?? false
        ) {
        case .none:
            return false
        case let .resolve(id, allow):
            resolveApproval(id, allow: allow)
        case .refuseDangerous:
            speak("危険な操作なので、画面の許可ボタンで確認してください")
        case .ignoreStale:
            transcript.append(.notice, "前の確認への返事として聞き取ったため、使いませんでした")
        }
        return true
    }

    private func route(_ command: VoiceCommand) {
        switch command {
        case .approve:
            // Approval answers were handled by `answerApproval`; here only a readback can be confirmed.
            if currentApproval == nil, let instruction = pendingReadback {
                pendingReadback = nil
                send(instruction)
            }
        case .deny:
            if currentApproval == nil, pendingReadback != nil {
                pendingReadback = nil
                speak("取りやめました")
            }
        case .interrupt:
            interrupt()
        case let .instruction(text):
            if settings.readbackEnabled {
                pendingReadback = text
                speak("『\(ClaudeCodeApprovalText.shortened(text, to: 80))』と指示します。よろしいですか?")
            } else {
                send(text)
            }
        case .busy:
            speak("作業中です")
        case .ignore:
            speak("聞き取れませんでした")
        }
    }

    private func interrupt() {
        pendingReadback = nil
        guard let session else { return }
        transcript.append(.notice, "中断しました")
        speak("中断します")
        Task { await session.interrupt() }
    }

    // MARK: - Session

    private func send(_ instruction: String) {
        guard !isShutDown else { return }
        Task {
            guard let session = await preparedSession() else { return }
            transcript.append(.instruction, instruction)
            lastProgressPhrase = nil
            transcript.isRunning = true
            do {
                try await session.submit(instruction)
            } catch {
                transcript.isRunning = await session.state != .idle
                report(error)
            }
        }
    }

    /// Returns the session for the current settings, replacing an idle session whose settings changed.
    private func preparedSession() async -> ClaudeCodeSession? {
        guard !isShutDown else { return nil }
        let configuration: ClaudeCodeLaunchConfiguration
        do {
            configuration = try ClaudeCodeLaunchSetup.configuration(from: settings)
        } catch {
            report(error)
            return nil
        }
        if let existing = session, sessionConfiguration != configuration {
            guard await existing.state == .idle else {
                report(ClaudeCodeError.busy)
                return nil
            }
            if session === existing {
                retireSession()
            }
        }
        if let session, sessionConfiguration == configuration {
            return session
        }
        retireSession()
        // Resume the conversation last used in this working directory, also after a restart or a settings change.
        let workingDirectory = configuration.workingDirectory.path
        let storedSessionID = settings.sessionID(forWorkingDirectory: workingDirectory)
        let process = ClaudeCodeProcess()
        let session = ClaudeCodeSession(configuration: configuration, process: process, initialSessionID: storedSessionID)
        self.session = session
        self.process = process
        sessionConfiguration = configuration
        lastSessionID = storedSessionID
        isAwaitingResumedStart = storedSessionID != nil
        if storedSessionID != nil {
            transcript.append(.notice, "前回の会話を再開します")
        }
        eventTask = Task { [weak self] in
            for await event in await session.events() {
                self?.handle(event, workingDirectory: workingDirectory)
            }
        }
        return session
    }

    /// Forgets the stored conversation for the current working directory; the next instruction starts a new one.
    private func startNewSession() {
        Task {
            if let session, await session.state != .idle {
                report(ClaudeCodeError.busy)
                return
            }
            pendingReadback = nil
            let directory = sessionConfiguration?.workingDirectory.path
                ?? (settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            if !directory.isEmpty {
                settings.setSessionID(nil, forWorkingDirectory: directory)
            }
            retireSession()
            lastSessionID = nil
            isAwaitingResumedStart = false
            transcript.append(.notice, "新しいセッションにしました。次の指示から新しい会話を始めます")
        }
    }

    private func retireSession() {
        eventTask?.cancel()
        eventTask = nil
        session = nil
        sessionConfiguration = nil
        if let process {
            self.process = nil
            Task.detached { await process.terminate() }
        }
    }

    private func handle(_ event: ClaudeCodeEvent, workingDirectory: String) {
        switch event {
        case let .sessionStarted(id):
            isAwaitingResumedStart = false
            settings.setSessionID(id, forWorkingDirectory: workingDirectory)
            if id != lastSessionID {
                lastSessionID = id
                transcript.append(.notice, "セッションを開始しました")
            }
        case let .assistantText(text):
            transcript.append(.assistant, text)
        case let .toolUse(_, name, command):
            transcript.append(.toolUse, command.map { "\(name): \($0)" } ?? name)
        case let .toolResult(_, isError):
            transcript.append(.toolResult(isError: isError), isError ? "ツールがエラーを返しました" : "ツールが完了しました")
        case let .finished(result, isError, sessionID):
            if let sessionID {
                settings.setSessionID(sessionID, forWorkingDirectory: workingDirectory)
            }
            transcript.append(.result(isError: isError), result.isEmpty ? "終わりました" : result)
            transcript.isRunning = false
            if isError, isAwaitingResumedStart {
                isAwaitingResumedStart = false
                transcript.append(.notice, "前回の会話を再開できなかった可能性があります。続けて失敗する場合は「新しいセッション」で新しく始めてください")
            }
        }
        guard let phrase = SpeechNarrator.narrate(event) else { return }
        if case .toolUse = event {
            guard phrase != lastProgressPhrase else { return }
            lastProgressPhrase = phrase
        } else {
            lastProgressPhrase = nil
        }
        speak(phrase)
    }

    private func report(_ error: Error) {
        var opensSettings = false
        let message: String
        if error is ClaudeCodeHelperMissing {
            message = "承認用のヘルパーが見つかりません"
        } else {
            switch error as? ClaudeCodeError {
            case .executableNotFound?:
                message = "claudeコマンドが見つかりません。設定でパスを確認してください"
                opensSettings = true
            case .workingDirectoryMissing?:
                message = "作業ディレクトリが見つかりません。設定で確認してください"
                opensSettings = true
            case .busy?:
                message = "作業中です"
            case nil:
                message = "Claude Codeを起動できませんでした"
            }
        }
        notify(message)
        if opensSettings {
            onOpenSettings?()
        }
    }

    private func notify(_ message: String) {
        transcript.append(.notice, message)
        speak(message)
    }
}
