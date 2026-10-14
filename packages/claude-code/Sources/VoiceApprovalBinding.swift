/// What a spoken「はい」/「いいえ」may do to an approval request.
public enum VoiceApprovalAction: Equatable, Sendable {
    /// No approval is involved; the command goes to the normal flow (readback and so on).
    case none
    case resolve(ClaudeCodeApprovalID, allow: Bool)
    /// A spoken approve for a dangerous request; only the on-screen button may allow it.
    case refuseDangerous
    /// The utterance began under a different approval, or under none; it must not decide the current one.
    case ignoreStale
}

public enum VoiceApprovalBinding {
    /// `listeningBoundTo` is the approval that was pending when push-to-talk was pressed.
    public static func action(
        for command: VoiceCommand,
        listeningBoundTo boundID: ClaudeCodeApprovalID?,
        current currentID: ClaudeCodeApprovalID?,
        currentIsDangerous: Bool
    ) -> VoiceApprovalAction {
        let allow: Bool
        switch command {
        case .approve: allow = true
        case .deny: allow = false
        case .interrupt, .instruction, .busy, .ignore: return .none
        }
        guard boundID != nil || currentID != nil else { return .none }
        guard let currentID, boundID == currentID else { return .ignoreStale }
        if allow, currentIsDangerous { return .refuseDangerous }
        return .resolve(currentID, allow: allow)
    }
}
