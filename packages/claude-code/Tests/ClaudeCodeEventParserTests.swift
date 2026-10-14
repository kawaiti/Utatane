import Testing
@testable import UtataneClaudeCode

@Test func `parses init, assistant text, tool use, tool result and result lines`() {
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"system","subtype":"init","session_id":"s1"}"#) == [.sessionStarted(id: "s1")])
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"読みます"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#) == [
        .assistantText("読みます"),
        .toolUse(id: "t1", name: "Bash", command: "ls")
    ])
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}"#) == [.toolResult(id: "t1", isError: true)])
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"完了","session_id":"s1"}"#) == [.finished(result: "完了", isError: false, sessionID: "s1")])
}

@Test func `ignores malformed lines and unknown event types`() {
    for line in ["", "{not json", #"{"type":"rate_limit_event"}"#, #"{"type":"assistant","message":{"content":[{"type":"thinking"}]}}"#] {
        #expect(ClaudeCodeEventParser.parse(line: line) == [])
    }
}

@Test func `error results without text fall back to a message for their subtype`() {
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s1"}"#)
        == [.finished(result: "やり取りの回数の上限に達しました", isError: true, sessionID: "s1")])
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":""}"#)
        == [.finished(result: "実行中にエラーが起きました", isError: true, sessionID: nil)])
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"result","subtype":"error_something_new","is_error":true}"#)
        == [.finished(result: "エラーが起きました (error_something_new)", isError: true, sessionID: nil)])
    // A result with text keeps its text; a successful empty result stays empty.
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"失敗"}"#)
        == [.finished(result: "失敗", isError: true, sessionID: nil)])
    #expect(ClaudeCodeEventParser.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":""}"#)
        == [.finished(result: "", isError: false, sessionID: nil)])
}
