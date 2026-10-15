import Foundation
import Testing
@testable import UtataneClaudeCode

@Test func `PATH puts the executable directory and common install locations first`() {
    let path = ClaudeCodeLaunchEnvironment.path(
        executableDirectory: "/Users/me/.local/bin",
        inherited: "/usr/bin:/bin:/usr/sbin:/sbin"
    )
    #expect(path == "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
}

@Test func `PATH drops duplicates and empty entries, keeping the first occurrence`() {
    let path = ClaudeCodeLaunchEnvironment.path(
        executableDirectory: "/opt/homebrew/bin",
        inherited: "/usr/local/bin::/usr/bin:/opt/homebrew/bin:"
    )
    #expect(path == "/opt/homebrew/bin:/usr/local/bin:/usr/bin")
    #expect(ClaudeCodeLaunchEnvironment.path(executableDirectory: "/x", inherited: nil) == "/x:/opt/homebrew/bin:/usr/local/bin")
}

@Test func `environment replaces only PATH`() {
    let environment = ClaudeCodeLaunchEnvironment.environment(
        executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude"),
        inheriting: ["HOME": "/Users/me", "PATH": "/usr/bin"]
    )
    #expect(environment == ["HOME": "/Users/me", "PATH": "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin"])
}

@Test func `login related failures map to the login message`() {
    for text in [
        "Invalid API key · Please run /login",
        "Error: Not logged in",
        "Please log in to continue",
        "Failed to authenticate. API Error: 401",
        "OAuth token has expired. Please obtain a new token or run /login"
    ] {
        #expect(ClaudeCodeFailureText.spokenMessage(for: text) == ClaudeCodeFailureText.loginMessage, "\(text)")
    }
    #expect(ClaudeCodeFailureText.loginMessage == "Claude Codeにログインしていません。ターミナルで claude を起動してログインしてください")
}

@Test func `other failures are not mapped`() {
    for text in ["プロセスが終了しました", "env: node: No such file or directory", "やり取りの回数の上限に達しました", ""] {
        #expect(ClaudeCodeFailureText.spokenMessage(for: text) == nil, "\(text)")
    }
}

@Test func `the narrator speaks the login message for login failures`() {
    let event = ClaudeCodeEvent.finished(result: "プロセスが終了しました\nInvalid API key · Please run /login", isError: true, sessionID: nil)
    #expect(SpeechNarrator.narrate(event) == ClaudeCodeFailureText.loginMessage)
}

@Test func `the narrator speaks only the first line of a multi-line failure`() {
    let event = ClaudeCodeEvent.finished(result: "プロセスが終了しました\nenv: node: No such file or directory", isError: true, sessionID: nil)
    #expect(SpeechNarrator.narrate(event) == "うまくいきませんでした: プロセスが終了しました")
}
