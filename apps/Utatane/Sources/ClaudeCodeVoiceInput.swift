import Foundation
import UtatanePlatformMacOS

/// Push-to-talk for Claude Code: listens while the hotkey is held and hands over each recognized utterance.
///
/// Nothing is registered and no microphone or speech recognition permission is requested until
/// `enable(hotkey:)` is called; the recognizer itself is created on the first key press.
@MainActor
final class ClaudeCodeVoiceInput {
    var onUtterance: ((String) -> Void)?
    var onListeningChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private static let configuration = SpeechRecognitionConfiguration(
        localeIdentifier: "ja-JP",
        contextualStrings: ["はい", "いいえ", "止めて", "中断"]
    )

    private var monitor: ClaudeCodeHotkeyMonitor?
    private var recognizer: MacOSSpeechRecognizer?
    private var isHolding = false

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

    func disable() {
        monitor?.stop()
        monitor = nil
        isHolding = false
        recognizer?.stop()
        recognizer = nil
    }

    private func beginListening() {
        isHolding = true
        let recognizer = recognizer ?? makeRecognizer()
        self.recognizer = recognizer
        onListeningChange?(true)
        Task {
            do {
                try await recognizer.start(configuration: Self.configuration)
                // The key may have been released while permissions were being requested.
                if !isHolding {
                    recognizer.finish()
                }
            } catch {
                guard self.recognizer === recognizer else { return }
                isHolding = false
                onListeningChange?(false)
                onFailure?(Self.message(for: error))
            }
        }
    }

    private func endListening() {
        guard isHolding else { return }
        isHolding = false
        recognizer?.finish()
        onListeningChange?(false)
    }

    private func makeRecognizer() -> MacOSSpeechRecognizer {
        let recognizer = MacOSSpeechRecognizer()
        recognizer.onFinalResult = { [weak self] text in
            self?.onUtterance?(text)
        }
        recognizer.onError = { [weak self] _ in
            guard let self, self.isHolding else { return }
            self.isHolding = false
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
