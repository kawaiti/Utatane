import AppKit
import SwiftUI
import UtataneClaudeCode

struct ClaudeCodeTranscriptEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case instruction
        case heard
        case assistant
        case toolUse
        case toolResult(isError: Bool)
        case result(isError: Bool)
        case approval
        case notice
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// A tool call waiting for the user's decision, shown with the real tool name and command.
struct ClaudeCodeApprovalRequest: Identifiable, Equatable {
    let id = UUID()
    let toolName: String
    let command: String?
    let filePath: String?
    /// Dangerous requests can only be allowed with the on-screen button.
    let isDangerous: Bool
    /// The session's id for this request, known once it is pending. The buttons resolve only this id.
    var approvalID: ClaudeCodeApprovalID?
}

@MainActor
final class ClaudeCodeTranscriptModel: ObservableObject {
    private static let maximumEntryCount = 500

    @Published private(set) var entries: [ClaudeCodeTranscriptEntry] = []
    @Published var pendingApproval: ClaudeCodeApprovalRequest?
    @Published var isRunning = false
    @Published var isListening = false
    @Published var draft = ""

    var onSubmit: ((String) -> Void)?
    var onResolve: ((ClaudeCodeApprovalID, Bool) -> Void)?
    var onInterrupt: (() -> Void)?
    var onNewSession: (() -> Void)?

    func append(_ kind: ClaudeCodeTranscriptEntry.Kind, _ text: String) {
        entries.append(ClaudeCodeTranscriptEntry(kind: kind, text: text))
        if entries.count > Self.maximumEntryCount {
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }
    }

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSubmit?(text)
    }
}

@MainActor
final class ClaudeCodeTranscriptWindowController: NSWindowController {
    private let model: ClaudeCodeTranscriptModel

    init(model: ClaudeCodeTranscriptModel) {
        self.model = model
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showTranscript() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ClaudeCodeTranscriptView(model: model)))
            window.title = "Claude Code"
            window.setContentSize(NSSize(width: 560, height: 600))
            window.minSize = NSSize(width: 420, height: 360)
            window.styleMask.insert([.resizable, .closable, .miniaturizable, .titled])
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct ClaudeCodeTranscriptView: View {
    @ObservedObject var model: ClaudeCodeTranscriptModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.entries) { entry in
                            ClaudeCodeTranscriptRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.entries.last?.id) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            if let request = model.pendingApproval {
                Divider()
                ClaudeCodeApprovalView(
                    request: request,
                    onResolve: { id, allow in model.onResolve?(id, allow) }
                )
                .padding(12)
            }
            Divider()
            HStack(spacing: 8) {
                if model.isListening {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .help(Text("聞き取り中"))
                }
                TextField("Claude Codeへの指示", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submitDraft() }
                Button("送信") {
                    model.submitDraft()
                }
                .disabled(model.isRunning || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("中断") {
                    model.onInterrupt?()
                }
                .disabled(!model.isRunning)
                Button("新しいセッション") {
                    model.onNewSession?()
                }
                .disabled(model.isRunning)
                .help(Text("この作業ディレクトリの会話を終え、次の指示から新しい会話を始めます"))
            }
            .padding(12)
        }
    }
}

private struct ClaudeCodeTranscriptRow: View {
    let entry: ClaudeCodeTranscriptEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(verbatim: entry.text)
                .textSelection(.enabled)
                .font(usesMonospace ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(isError ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isError: Bool {
        switch entry.kind {
        case let .toolResult(isError), let .result(isError): isError
        default: false
        }
    }

    private var usesMonospace: Bool {
        entry.kind == .toolUse || entry.kind == .approval
    }

    private var symbol: String {
        switch entry.kind {
        case .instruction: "person.fill"
        case .heard: "mic"
        case .assistant: "text.bubble"
        case .toolUse: "wrench.and.screwdriver"
        case .toolResult: "arrow.turn.down.right"
        case .result: "checkmark.circle"
        case .approval: "hand.raised"
        case .notice: "info.circle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .instruction, .heard: .accentColor
        case .approval: .orange
        default: .secondary
        }
    }
}

private struct ClaudeCodeApprovalView: View {
    let request: ClaudeCodeApprovalRequest
    let onResolve: (ClaudeCodeApprovalID, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("実行の許可を求めています", systemImage: request.isDangerous ? "exclamationmark.triangle.fill" : "hand.raised")
                .font(.headline)
                .foregroundStyle(request.isDangerous ? Color.red : Color.primary)
            Text(verbatim: request.toolName)
                .font(.system(.body, design: .monospaced).bold())
            if let filePath = request.filePath {
                Text(verbatim: filePath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let command = request.command {
                ScrollView {
                    Text(verbatim: command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            if request.isDangerous {
                Text("危険な操作のため、声では許可できません。内容を確認して許可ボタンを押してください。")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                // Each button carries the id of the request shown, so a click cannot decide a later request.
                if let approvalID = request.approvalID {
                    Button("拒否") { onResolve(approvalID, false) }
                    Button("許可") { onResolve(approvalID, true) }
                } else {
                    Button("拒否") {}.disabled(true)
                    Button("許可") {}.disabled(true)
                }
            }
        }
    }
}
