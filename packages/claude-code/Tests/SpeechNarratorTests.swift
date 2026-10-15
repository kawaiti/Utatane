import Testing
@testable import UtataneClaudeCode

@Test func `read-only tools narrate reading files`() {
    for name in ["Read", "Glob", "Grep", "LS"] {
        #expect(SpeechNarrator.narrate(.toolUse(id: "t", name: name, command: nil)) == "ファイルを読んでいます")
    }
}

@Test func `Bash narrates running a command`() {
    #expect(SpeechNarrator.narrate(.toolUse(id: "t", name: "Bash", command: "ls")) == "コマンドを実行しています")
}

@Test func `editing tools narrate rewriting files`() {
    for name in ["Edit", "Write", "MultiEdit", "NotebookEdit"] {
        #expect(SpeechNarrator.narrate(.toolUse(id: "t", name: name, command: nil)) == "ファイルを書き換えています")
    }
}

@Test func `other tools are not narrated`() {
    #expect(SpeechNarrator.narrate(.toolUse(id: "t", name: "WebFetch", command: nil)) == nil)
    #expect(SpeechNarrator.narrate(.toolUse(id: "t", name: "mcp__utatane__approve", command: nil)) == nil)
}

@Test func `text, tool results and session start are not narrated`() {
    #expect(SpeechNarrator.narrate(.assistantText("考えています")) == nil)
    #expect(SpeechNarrator.narrate(.toolResult(id: "t", isError: false)) == nil)
    #expect(SpeechNarrator.narrate(.toolResult(id: "t", isError: true)) == nil)
    #expect(SpeechNarrator.narrate(.sessionStarted(id: "s")) == nil)
}

@Test func `short successful result is spoken trimmed`() {
    let event = ClaudeCodeEvent.finished(result: "  テストは全部通りました。\n", isError: false, sessionID: nil)
    #expect(SpeechNarrator.narrate(event) == "テストは全部通りました。")
}

@Test func `successful result of exactly 120 characters is not truncated`() {
    let text = String(repeating: "あ", count: 120)
    #expect(SpeechNarrator.narrate(.finished(result: text, isError: false, sessionID: nil)) == text)
}

@Test func `long successful result is cut to 120 characters with an ellipsis`() {
    let text = String(repeating: "あ", count: 120) + "いうえお"
    let narrated = SpeechNarrator.narrate(.finished(result: text, isError: false, sessionID: "s"))
    #expect(narrated == String(repeating: "あ", count: 120) + "…")
}

@Test func `empty successful result says it finished`() {
    #expect(SpeechNarrator.narrate(.finished(result: " \n ", isError: false, sessionID: nil)) == "終わりました")
}

@Test func `failed result speaks the first 60 characters`() {
    let text = String(repeating: "い", count: 60) + "うえお"
    let narrated = SpeechNarrator.narrate(.finished(result: text, isError: true, sessionID: nil))
    #expect(narrated == "うまくいきませんでした: " + String(repeating: "い", count: 60))
    #expect(SpeechNarrator.narrate(.finished(result: "プロセスが終了しました", isError: true, sessionID: "s"))
        == "うまくいきませんでした: プロセスが終了しました")
}

@Test func `failed result with a subtype message is not spoken empty`() throws {
    let line = #"{"type":"result","subtype":"error_max_turns","is_error":true}"#
    let event = try #require(ClaudeCodeEventParser.parse(line: line).first)
    #expect(SpeechNarrator.narrate(event) == "うまくいきませんでした: やり取りの回数の上限に達しました")
    #expect(SpeechNarrator.narrate(.finished(result: "  ", isError: true, sessionID: nil)) == "うまくいきませんでした")
}

@Test func `a blocked command is narrated as not executable`() {
    #expect(SpeechNarrator.narrate(.commandBlocked(toolName: "Bash", command: "rm -rf x")) == "危険なコマンドなので実行できません")
}
