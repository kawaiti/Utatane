import Testing
@testable import UtataneClaudeCode

private let first = ClaudeCodeApprovalID(rawValue: 1)
private let second = ClaudeCodeApprovalID(rawValue: 2)

@Test func `voice answers resolve the approval that was current when listening began`() {
    #expect(VoiceApprovalBinding.action(for: .approve, listeningBoundTo: first, current: first)
        == .resolve(first, allow: true))
    #expect(VoiceApprovalBinding.action(for: .deny, listeningBoundTo: first, current: first)
        == .resolve(first, allow: false))
}

@Test func `a late answer bound to an earlier approval is ignored for a newer one`() {
    #expect(VoiceApprovalBinding.action(for: .approve, listeningBoundTo: first, current: second)
        == .ignoreStale)
    #expect(VoiceApprovalBinding.action(for: .deny, listeningBoundTo: first, current: second)
        == .ignoreStale)
}

@Test func `an answer that began with no approval pending never resolves a later approval`() {
    #expect(VoiceApprovalBinding.action(for: .approve, listeningBoundTo: nil, current: first)
        == .ignoreStale)
}

@Test func `an answer bound to an approval that is gone is ignored instead of confirming a readback`() {
    #expect(VoiceApprovalBinding.action(for: .approve, listeningBoundTo: first, current: nil)
        == .ignoreStale)
}

@Test func `without any approval involved the command is left to the readback flow`() {
    #expect(VoiceApprovalBinding.action(for: .approve, listeningBoundTo: nil, current: nil) == .none)
    #expect(VoiceApprovalBinding.action(for: .deny, listeningBoundTo: nil, current: nil) == .none)
    #expect(VoiceApprovalBinding.action(for: .interrupt, listeningBoundTo: first, current: first) == .none)
    #expect(VoiceApprovalBinding.action(for: .instruction("x"), listeningBoundTo: nil, current: nil) == .none)
}
