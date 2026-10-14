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
