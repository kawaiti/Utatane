import Testing
@testable import UtataneClaudeCode

private let router = VoiceCommandRouter()

@Test func `approve words approve while awaiting approval`() {
    for text in ["はい", "許可", "OK", "ok", "オーケー", "いいよ", "実行", "お願いします"] {
        #expect(router.route(text, state: .awaitingApproval, awaitingReadback: false) == .approve)
    }
}

@Test func `deny words deny while awaiting approval`() {
    for text in ["いいえ", "拒否", "やめて", "だめ", "ダメ", "キャンセル"] {
        #expect(router.route(text, state: .awaitingApproval, awaitingReadback: false) == .deny)
    }
}

@Test func `readback answers strip punctuation`() {
    #expect(router.route("はい。", state: .idle, awaitingReadback: true) == .approve)
    #expect(router.route("いいえ、", state: .idle, awaitingReadback: true) == .deny)
    #expect(router.route("やめて！", state: .idle, awaitingReadback: true) == .deny)
}

@Test func `other text is ignored while awaiting approval or readback`() {
    #expect(router.route("テストを実行して", state: .awaitingApproval, awaitingReadback: false) == .ignore)
    #expect(router.route("テストを実行して", state: .idle, awaitingReadback: true) == .ignore)
}

@Test func `idle text becomes an instruction`() {
    #expect(router.route("テストを実行して", state: .idle, awaitingReadback: false) == .instruction("テストを実行して"))
    #expect(router.route("  はい  ", state: .idle, awaitingReadback: false) == .instruction("はい"))
}

@Test func `interrupt words interrupt in any state`() {
    for text in ["止めて", "とめて", "中断", "ストップ"] {
        #expect(router.route(text, state: .idle, awaitingReadback: false) == .interrupt)
        #expect(router.route(text, state: .running, awaitingReadback: false) == .interrupt)
        #expect(router.route(text, state: .awaitingApproval, awaitingReadback: false) == .interrupt)
    }
}

@Test func `yamete interrupts unless awaiting an answer`() {
    #expect(router.route("やめて", state: .idle, awaitingReadback: false) == .interrupt)
    #expect(router.route("やめて", state: .running, awaitingReadback: false) == .interrupt)
}

@Test func `running state reports busy for new instructions`() {
    #expect(router.route("別の作業をして", state: .running, awaitingReadback: false) == .busy)
}

@Test func `whitespace only is ignored in every state`() {
    for state in [ClaudeCodeSessionState.idle, .running, .awaitingApproval] {
        #expect(router.route("  　", state: state, awaitingReadback: false) == .ignore)
        #expect(router.route("\n", state: state, awaitingReadback: true) == .ignore)
    }
}

@Test func `command words match whole phrases only`() {
    #expect(router.route("テストを止めないで", state: .idle, awaitingReadback: false) == .instruction("テストを止めないで"))
    #expect(router.route("はいはい了解", state: .awaitingApproval, awaitingReadback: false) == .ignore)
    #expect(router.route("ストップウォッチを作って", state: .idle, awaitingReadback: false) == .instruction("ストップウォッチを作って"))
}

@Test func `polite interrupt forms interrupt`() {
    for text in ["止めてください", "とめてください", "止めて下さい", "やめてください", "やめて下さい。"] {
        #expect(router.route(text, state: .running, awaitingReadback: false) == .interrupt, "\(text)")
        #expect(router.route(text, state: .idle, awaitingReadback: false) == .interrupt, "\(text)")
    }
    #expect(router.route("止めてください", state: .awaitingApproval, awaitingReadback: false) == .interrupt)
    #expect(router.route("やめてください", state: .awaitingApproval, awaitingReadback: false) == .deny)
}

@Test func `polite forms still match whole phrases only`() {
    #expect(router.route("ログ出力を止めてください", state: .idle, awaitingReadback: false) == .instruction("ログ出力を止めてください"))
    #expect(router.route("ください", state: .idle, awaitingReadback: false) == .instruction("ください"))
    #expect(router.route("中断してください", state: .running, awaitingReadback: false) == .busy)
}
