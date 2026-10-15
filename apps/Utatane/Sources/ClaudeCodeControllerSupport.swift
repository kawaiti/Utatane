import Foundation
import UtataneClaudeCode
import UtataneNetwork

/// What the ghost says and the approve tool answers for an approval request.
enum ClaudeCodeApprovalText {
    /// `reason` is always a fixed message from the controller or `ClaudeCodeSession`, never request content.
    static func response(allow: Bool, reason: String?) -> SSTPResponse {
        var object: [String: Any] = ["allow": allow]
        if !allow {
            object["reason"] = (reason ?? "拒否しました").filter { !$0.isNewline }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return SSTPResponse(statusCode: 500, reason: "Serialization Error") }
        return SSTPResponse(script: json)
    }

    static func describe(_ request: ClaudeCodeApprovalRequest) -> String {
        [request.toolName, request.filePath, request.command].compactMap(\.self).joined(separator: "\n")
    }

    static func prompt(for request: ClaudeCodeApprovalRequest) -> String {
        let question = if let command = request.command {
            "「\(shortened(command, to: 40))」を実行してよいですか?"
        } else if let filePath = request.filePath {
            "\((filePath as NSString).lastPathComponent)を書き換えてよいですか?"
        } else {
            "\(request.toolName)を実行してよいですか?"
        }
        return request.isDangerous ? "危険な操作です。\(question)画面の許可ボタンで確認してください。" : question
    }

    static func shortened(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

/// The `utatane-mcp` helper is missing, so Claude Code is never launched without the approval tool.
struct ClaudeCodeHelperMissing: Error {}

/// Builds the launch configuration from the settings and locates `claude` and the approval helper.
@MainActor
enum ClaudeCodeLaunchSetup {
    static func configuration(from settings: ClaudeCodeSettings) throws -> ClaudeCodeLaunchConfiguration {
        guard let helperPath = helperPath() else { throw ClaudeCodeHelperMissing() }
        let fileManager = FileManager.default
        guard let executable = ClaudeExecutableLocator.locate(
            explicitPath: settings.executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
            home: fileManager.homeDirectoryForCurrentUser,
            fileExists: { fileManager.isExecutableFile(atPath: $0) }
        ) else { throw ClaudeCodeError.executableNotFound }
        let directory = settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { throw ClaudeCodeError.workingDirectoryMissing }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeCodeLaunchConfiguration(
            executable: executable,
            workingDirectory: URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true),
            model: model.isEmpty ? nil : model,
            permissionMode: settings.permissionMode,
            mcpHelperPath: helperPath
        )
    }

    /// `UTATANE_MCP_PATH` when it names an executable, otherwise the helper inside the app bundle.
    private static func helperPath() -> String? {
        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["UTATANE_MCP_PATH"], !path.isEmpty,
           fileManager.isExecutableFile(atPath: path)
        {
            return path
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/utatane-mcp").path
        return fileManager.isExecutableFile(atPath: bundled) ? bundled : nil
    }
}
