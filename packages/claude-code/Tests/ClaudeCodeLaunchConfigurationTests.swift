import Foundation
import Testing
@testable import UtataneClaudeCode

private func makeConfiguration(model: String? = nil, mcpHelperPath: String = "/Apps/Utatane.app/Contents/MacOS/utatane-mcp") -> ClaudeCodeLaunchConfiguration {
    ClaudeCodeLaunchConfiguration(
        executable: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        workingDirectory: URL(fileURLWithPath: "/tmp/project"),
        model: model,
        permissionMode: .default,
        mcpHelperPath: mcpHelperPath
    )
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

@Test func `arguments contain the stream-json, permission and system prompt flags without resume`() {
    let arguments = makeConfiguration().arguments(resume: nil)
    #expect(arguments.contains("-p"))
    #expect(value(after: "--input-format", in: arguments) == "stream-json")
    #expect(value(after: "--output-format", in: arguments) == "stream-json")
    #expect(arguments.contains("--verbose"))
    #expect(value(after: "--permission-mode", in: arguments) == "default")
    #expect(value(after: "--permission-prompt-tool", in: arguments) == "mcp__utatane__approve")
    #expect(value(after: "--allowedTools", in: arguments) == "Read,Glob,Grep,LS")
    #expect(value(after: "--append-system-prompt", in: arguments) == "音声で読み上げられます。日本語で3文以内に要約して答えてください。詳細は画面に表示されます。")
    #expect(!arguments.contains("--resume"))
    #expect(!arguments.contains("--model"))
}

@Test func `mcp config is JSON pointing the utatane server at the helper, even with spaces and quotes`() throws {
    let helper = #"/Users/a b/Utatane "dev".app/Contents/MacOS/utatane-mcp"#
    let json = try #require(value(after: "--mcp-config", in: makeConfiguration(mcpHelperPath: helper).arguments(resume: nil)))
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let servers = try #require(object["mcpServers"] as? [String: Any])
    let utatane = try #require(servers["utatane"] as? [String: Any])
    #expect(utatane["command"] as? String == helper)
    #expect((utatane["args"] as? [Any])?.isEmpty == true)
}

@Test func `arguments include resume and model when given`() {
    let arguments = makeConfiguration(model: "sonnet").arguments(resume: "s1")
    #expect(value(after: "--resume", in: arguments) == "s1")
    #expect(value(after: "--model", in: arguments) == "sonnet")
}

@Test func `accept edits permission mode is passed through`() {
    var configuration = makeConfiguration()
    configuration.permissionMode = .acceptEdits
    #expect(value(after: "--permission-mode", in: configuration.arguments(resume: nil)) == "acceptEdits")
}

@Test func `locator prefers an existing explicit path`() {
    let home = URL(fileURLWithPath: "/Users/me")
    let located = ClaudeExecutableLocator.locate(explicitPath: "/custom/claude", home: home) { _ in true }
    #expect(located?.path == "/custom/claude")
}

@Test func `locator falls back to well-known locations in order`() {
    let home = URL(fileURLWithPath: "/Users/me")
    let expectations: [(Set<String>, String?)] = [
        (["/Users/me/.local/bin/claude", "/opt/homebrew/bin/claude"], "/Users/me/.local/bin/claude"),
        (["/opt/homebrew/bin/claude", "/usr/local/bin/claude"], "/opt/homebrew/bin/claude"),
        (["/usr/local/bin/claude", "/Users/me/.claude/local/claude"], "/usr/local/bin/claude"),
        (["/Users/me/.claude/local/claude"], "/Users/me/.claude/local/claude"),
        ([], nil)
    ]
    for (existing, expected) in expectations {
        for explicit in [nil, "/missing/claude"] {
            let located = ClaudeExecutableLocator.locate(explicitPath: explicit, home: home) { existing.contains($0) }
            #expect(located?.path == expected)
        }
    }
}
