import Foundation
import UtataneClaudeCode
import UtatanePlatformMacOS

/// Push-to-talk for Claude Code: listens while the hotkey is held and hands over what was said, once, on release.
///
/// Nothing is registered and no microphone or speech recognition permission is requested until
/// `enable(hotkey:)` is called; the recognizer itself is created on the first key press.
@MainActor
final class ClaudeCodeVoiceInput {
    /// Called on each key press; the returned approval is handed back with the utterance of that hold.
    var onHoldBegan: (() -> ClaudeCodeApprovalID?)?
    /// The whole hold's recognized text, joined, with the approval bound when the key went down.
    var onUtterance: ((String, ClaudeCodeApprovalID?) -> Void)?
    /// A hold ended without any recognized words.
    var onNothingHeard: (() -> Void)?
    var onListeningChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private static let configuration = SpeechRecognitionConfiguration(
        localeIdentifier: "ja-JP",
        contextualStrings: ["はい", "いいえ", "止めて", "中断"],
        finalizesAfterPause: false
    )

    private var monitor: ClaudeCodeHotkeyMonitor?
    private var recognizer: MacOSSpeechRecognizer?
    private var hold = PushToTalkHold()
    /// The recognizer is still starting (possibly waiting for a permission prompt).
    private var isStarting = false
    /// Releases the hold after `PushToTalkHold.maximumDuration` in case the key-up is never seen.
    private var holdCapTask: Task<Void, Never>?

    var isEnabled: Bool {
        monitor != nil
    }

    func enable(hotkey: ClaudeCodeHotkey) {
        disable()
        let monitor = ClaudeCodeHotkeyMonitor(hotkey: hotkey)
        monitor.onPress = { [weak self] in self?.beginListening() }
        monitor.onRelease = { [weak self] in self?.endListening() }
        monitor.start()
        self.monitor = monitor
    }

    /// Stops listening and drops the current hold; nothing heard so far is routed.
    func disable() {
        // Detach the callbacks first: `stop()` reports a release for an active hold, which must not route anything.
        monitor?.onPress = nil
        monitor?.onRelease = nil
        monitor?.stop()
        monitor = nil
        cancelHold()
        recognizer?.onFinalResult = nil
        recognizer?.onError = nil
        recognizer?.stop()
        recognizer = nil
    }

    private func beginListening() {
        guard let token = hold.begin(boundTo: onHoldBegan?()) else { return }
        let recognizer = recognizer ?? makeRecognizer()
        self.recognizer = recognizer
        onListeningChange?(true)
        holdCapTask = Task { [weak self] in
            guard (try? await Task.sleep(for: PushToTalkHold.maximumDuration)) != nil else { return }
            guard let self, self.hold.isHolding(token) else { return }
            // The key-up was probably lost; forget the monitor's held key so the next press works.
            self.monitor?.resetHold()
            self.endListening()
        }
        isStarting = true
        Task {
            do {
                try await recognizer.start(configuration: Self.configuration)
                guard self.recognizer === recognizer, isStarting else {
                    // Voice input was turned off while starting: make sure the microphone is off.
                    recognizer.stop()
                    return
                }
                isStarting = false
                if !hold.isActive {
                    recognizer.stop()
                } else if !hold.isHolding(token) {
                    // The key was released while permissions were being requested.
                    completeHold()
                }
            } catch {
                guard self.recognizer === recognizer else { return }
                isStarting = false
                guard hold.isActive else { return }
                cancelHold()
                onListeningChange?(false)
                onFailure?(Self.message(for: error))
            }
        }
    }

    private func endListening() {
        guard hold.isActive else { return }
        holdCapTask?.cancel()
        holdCapTask = nil
        hold.release()
        onListeningChange?(false)
        // While the recognizer is still starting, its start task completes the hold.
        guard !isStarting else { return }
        completeHold()
    }

    /// Stops the recognizer (delivering its pending partial text into the hold) and routes the hold once.
    private func completeHold() {
        recognizer?.finish()
        switch hold.complete() {
        case let .utterance(text, binding)?:
            onUtterance?(text, binding)
        case .nothingHeard?:
            onNothingHeard?()
        case nil:
            break
        }
    }

    private func cancelHold() {
        holdCapTask?.cancel()
        holdCapTask = nil
        isStarting = false
        hold.cancel()
    }

    private func makeRecognizer() -> MacOSSpeechRecognizer {
        let recognizer = MacOSSpeechRecognizer()
        recognizer.onFinalResult = { [weak self] text in
            self?.hold.append(text)
        }
        recognizer.onError = { [weak self] _ in
            guard let self, self.hold.isActive else { return }
            self.cancelHold()
            self.onListeningChange?(false)
            self.onFailure?("音声認識でエラーが起きました")
        }
        return recognizer
    }

    private static func message(for error: Error) -> String {
        switch error as? SpeechServiceError {
        case .microphonePermissionDenied?: "マイクの使用が許可されていません"
        case .recognitionPermissionDenied?: "音声認識が許可されていません"
        default: "音声認識を開始できませんでした"
        }
    }
}
