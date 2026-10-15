import Foundation

/// One push-to-talk hold: collects every recognizer result while the key is held and hands them over once,
/// joined, after release.
///
/// The speech recognizer may split one utterance into several results on a pause; routing each of them
/// separately would turn the second half into a stray reply. The approval pending when the key went down
/// stays bound to the joined utterance.
public struct PushToTalkHold: Sendable {
    /// A hold longer than this is released automatically, so a lost key-up cannot leave the microphone on.
    public static let maximumDuration: Duration = .seconds(60)

    public enum Outcome: Equatable, Sendable {
        case utterance(String, boundTo: ClaudeCodeApprovalID?)
        /// The hold ended without any recognized words.
        case nothingHeard
    }

    private enum Phase {
        case idle
        case holding
        /// The key is up; results still arriving while the recognizer finishes belong to this hold.
        case released
    }

    private var phase: Phase = .idle
    private var fragments: [String] = []
    private var binding: ClaudeCodeApprovalID?
    private var generation: UInt64 = 0

    public init() {}

    /// Whether a hold is in progress (held, or released and not yet completed).
    public var isActive: Bool {
        phase != .idle
    }

    /// Starts a hold bound to `approval` and returns its token, or `nil` while another hold is still active.
    public mutating func begin(boundTo approval: ClaudeCodeApprovalID?) -> UInt64? {
        guard phase == .idle else { return nil }
        generation += 1
        phase = .holding
        fragments = []
        binding = approval
        return generation
    }

    /// Whether the hold `token` is still held (not released or cancelled); used by the duration cap.
    public func isHolding(_ token: UInt64) -> Bool {
        phase == .holding && generation == token
    }

    /// Adds a recognizer result; ignored when no hold is active.
    public mutating func append(_ fragment: String) {
        guard phase != .idle else { return }
        fragments.append(fragment)
    }

    /// The key went up. Call `complete()` once the recognizer has delivered its last result.
    public mutating func release() {
        guard phase == .holding else { return }
        phase = .released
    }

    /// Ends the hold and returns what to route, or `nil` when no hold was active.
    public mutating func complete() -> Outcome? {
        guard phase != .idle else { return nil }
        let text = Self.join(fragments)
        let outcome: Outcome = text.isEmpty ? .nothingHeard : .utterance(text, boundTo: binding)
        reset()
        return outcome
    }

    /// Drops the hold without routing anything (voice input turned off, quitting, recognizer failure).
    public mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        phase = .idle
        fragments = []
        binding = nil
    }

    /// Joins recognizer results: trims each, drops empty ones, and puts a space only between two ASCII characters
    /// (English words), never next to Japanese text.
    public static func join(_ fragments: [String]) -> String {
        var joined = ""
        for fragment in fragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = joined.last, let first = trimmed.first, last.isASCII, first.isASCII {
                joined.append(" ")
            }
            joined.append(trimmed)
        }
        return joined
    }
}
