import Foundation

public enum ClaudeCodePermissionMode: String, Sendable {
    case `default`
    case acceptEdits
}

public struct ClaudeCodeLaunchConfiguration: Sendable, Equatable {
    public static let approvalToolName = "mcp__utatane__approve"
    public static let autoAllowedTools = "Read,Glob,Grep,LS"
    /// Only the user's own settings are loaded. A working directory's `.claude/settings.json` and
    /// `settings.local.json` could otherwise allow tools or add `PreToolUse` hooks that bypass the approval tool.
    /// The flag comes from the Claude Code CLI documentation and has not been checked against a real `claude`.
    /// User-level rules and hooks in `~/.claude/settings.json` still apply.
    public static let settingSources = "user"
    public static let appendedSystemPrompt = "音声で読み上げられます。日本語で3文以内に要約して答えてください。詳細は画面に表示されます。"

    public var executable: URL
    public var workingDirectory: URL
    public var model: String?
    public var permissionMode: ClaudeCodePermissionMode
    /// Absolute path of the `utatane-mcp` helper.
    public var mcpHelperPath: String

    public init(executable: URL, workingDirectory: URL, model: String?, permissionMode: ClaudeCodePermissionMode, mcpHelperPath: String) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionMode = permissionMode
        self.mcpHelperPath = mcpHelperPath
    }

    public func arguments(resume sessionID: String?) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode.rawValue,
            "--permission-prompt-tool", Self.approvalToolName,
            "--allowedTools", Self.autoAllowedTools,
            "--setting-sources", Self.settingSources,
            "--append-system-prompt", Self.appendedSystemPrompt,
            "--mcp-config", mcpConfigJSON
        ]
        if let model {
            arguments += ["--model", model]
        }
        if let sessionID {
            arguments += ["--resume", sessionID]
        }
        return arguments
    }

    /// `{"mcpServers":{"utatane":{"command":<mcpHelperPath>,"args":[]}}}`, serialized so that paths are escaped correctly.
    private var mcpConfigJSON: String {
        let object: [String: Any] = ["mcpServers": ["utatane": ["command": mcpHelperPath, "args": [String]()]]]
        // Serializing string/array/dictionary values cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ClaudeExecutableLocator {
    /// Returns `explicitPath` if it exists, otherwise the first existing well-known install location, otherwise `nil`.
    public static func locate(explicitPath: String?, home: URL, fileExists: (String) -> Bool) -> URL? {
        if let explicitPath, !explicitPath.isEmpty, fileExists(explicitPath) {
            return URL(fileURLWithPath: explicitPath)
        }
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path
        ]
        return candidates.first(where: fileExists).map { URL(fileURLWithPath: $0) }
    }
}
