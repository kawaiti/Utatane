import Testing
@testable import UtataneClaudeCode

@Test func `fragments are joined without spaces between Japanese text`() {
    #expect(PushToTalkHold.join(["テストを", "実行して"]) == "テストを実行して")
    #expect(PushToTalkHold.join(["READMEを読んで", "まとめて"]) == "READMEを読んでまとめて")
}

@Test func `fragments are joined with a space between ASCII words`() {
    #expect(PushToTalkHold.join(["run the", "tests"]) == "run the tests")
    #expect(PushToTalkHold.join(["swift", "テストを実行"]) == "swiftテストを実行")
    #expect(PushToTalkHold.join(["hello,", "world"]) == "hello, world")
    #expect(PushToTalkHold.join(["git status", "を見て"]) == "git statusを見て")
}

@Test func `empty and whitespace fragments are dropped and the rest trimmed`() {
    #expect(PushToTalkHold.join(["", "  はい ", "\n"]) == "はい")
    #expect(PushToTalkHold.join(["", " "]) == "")
    #expect(PushToTalkHold.join([]) == "")
}

@Test func `a hold delivers all its fragments once, joined, with its binding`() {
    var hold = PushToTalkHold()
    let approval = ClaudeCodeApprovalID(rawValue: 7)
    _ = hold.begin(boundTo: approval)
    hold.append("テストを")
    hold.append("実行して")
    hold.release()
    // A pending partial delivered while the recognizer finishes still belongs to the hold.
    hold.append("ください")
    #expect(hold.complete() == .utterance("テストを実行してください", boundTo: approval))
    #expect(hold.complete() == nil)
    hold.append("遅れて届いた")
    #expect(hold.complete() == nil)
}

@Test func `a hold that recognized nothing reports nothing heard`() {
    var hold = PushToTalkHold()
    _ = hold.begin(boundTo: nil)
    hold.append("  ")
    hold.release()
    #expect(hold.complete() == .nothingHeard)
}

@Test func `a cancelled hold routes nothing`() {
    var hold = PushToTalkHold()
    _ = hold.begin(boundTo: nil)
    hold.append("rm を実行")
    hold.cancel()
    #expect(!hold.isActive)
    #expect(hold.complete() == nil)
    hold.release()
    #expect(hold.complete() == nil)
}

@Test func `fragments outside a hold are ignored`() {
    var hold = PushToTalkHold()
    hold.append("前のホールド")
    _ = hold.begin(boundTo: nil)
    hold.append("今回")
    hold.release()
    #expect(hold.complete() == .utterance("今回", boundTo: nil))
}

@Test func `the duration cap applies only to the hold it was armed for`() throws {
    var hold = PushToTalkHold()
    #expect(PushToTalkHold.maximumDuration == .seconds(60))
    let firstToken = hold.begin(boundTo: nil)
    let first = try #require(firstToken)
    #expect(hold.isHolding(first))
    hold.release()
    #expect(!hold.isHolding(first)) // already released: the cap does nothing
    _ = hold.complete()
    let secondToken = hold.begin(boundTo: nil)
    let second = try #require(secondToken)
    #expect(!hold.isHolding(first))
    #expect(hold.isHolding(second))
}

@Test func `a new press while a hold is active is ignored`() {
    var hold = PushToTalkHold()
    let first = hold.begin(boundTo: ClaudeCodeApprovalID(rawValue: 1))
    #expect(first != nil)
    #expect(hold.begin(boundTo: nil) == nil)
    hold.append("はい")
    hold.release()
    #expect(hold.begin(boundTo: nil) == nil) // still waiting for the recognizer to finish
    #expect(hold.complete() == .utterance("はい", boundTo: ClaudeCodeApprovalID(rawValue: 1)))
}
