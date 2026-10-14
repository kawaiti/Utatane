import Foundation

/// Turns session events into short Japanese phrases for the ghost to speak. The full text stays in the transcript.
public enum SpeechNarrator {
    static let resultLimit = 120
    static let errorLimit = 60

    private static let readingTools: Set<String> = ["Read", "Glob", "Grep", "LS"]
    private static let editingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public static func narrate(_ event: ClaudeCodeEvent) -> String? {
        switch event {
        case let .toolUse(_, name, _):
            if readingTools.contains(name) { return "ファイルを読んでいます" }
            if name == "Bash" { return "コマンドを実行しています" }
            if editingTools.contains(name) { return "ファイルを書き換えています" }
            return nil
        case let .finished(result, isError, _):
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if isError {
                return "うまくいきませんでした: " + String(trimmed.prefix(errorLimit))
            }
            if trimmed.isEmpty { return "終わりました" }
            return trimmed.count > resultLimit ? String(trimmed.prefix(resultLimit)) + "…" : trimmed
        case .sessionStarted, .assistantText, .toolResult:
            return nil
        }
    }
}
