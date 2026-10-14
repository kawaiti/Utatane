import Foundation

public enum VoiceCommand: Equatable, Sendable {
    case approve
    case deny
    case interrupt
    case instruction(String)
    case busy
    case ignore
}

public struct VoiceCommandRouter: Sendable {
    private static let approveWords: Set<String> = ["はい", "許可", "ok", "オーケー", "いいよ", "実行", "お願いします"]
    private static let denyWords: Set<String> = ["いいえ", "拒否", "だめ", "ダメ", "やめて", "キャンセル"]
    private static let interruptWords: Set<String> = ["止めて", "とめて", "中断", "ストップ"]
    private static let punctuation = CharacterSet(charactersIn: "。、.!！?？")
    /// Polite endings removed before matching deny and interrupt words, so「止めてください」is「止めて」.
    private static let politeSuffixes = ["ください", "下さい"]

    public init() {}

    public func route(_ text: String, state: ClaudeCodeSessionState, awaitingReadback: Bool) -> VoiceCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = String(String.UnicodeScalarView(
            trimmed.unicodeScalars.filter { !Self.punctuation.contains($0) }
        )).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return .ignore }

        // Still a whole-phrase match: only the polite ending is removed, and「ください」alone stays as is.
        let base = Self.politeSuffixes.first { normalized.hasSuffix($0) && normalized.count > $0.count }
            .map { String(normalized.dropLast($0.count)) } ?? normalized

        let awaitingAnswer = state == .awaitingApproval || awaitingReadback
        if awaitingAnswer {
            if Self.approveWords.contains(normalized) { return .approve }
            if Self.denyWords.contains(base) { return .deny }
            if Self.interruptWords.contains(base) { return .interrupt }
            return .ignore
        }
        if Self.interruptWords.contains(base) || base == "やめて" { return .interrupt }
        if state == .running { return .busy }
        return .instruction(trimmed)
    }
}
