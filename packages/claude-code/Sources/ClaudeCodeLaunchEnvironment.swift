import Foundation

/// The environment the `claude` child process runs with.
///
/// An app started from Finder inherits launchd's minimal `PATH`, so an npm-installed `claude`
/// (`#!/usr/bin/env node`) cannot find `node`. The executable's own directory and the common Homebrew
/// locations are therefore put in front of the inherited `PATH`.
public enum ClaudeCodeLaunchEnvironment {
    static let extraDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// `executableDirectory`, `/opt/homebrew/bin`, `/usr/local/bin`, then `inherited`; empty entries and
    /// duplicates (after the first occurrence) are dropped.
    public static func path(executableDirectory: String, inherited: String?) -> String {
        let inheritedEntries = (inherited ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        var seen = Set<String>()
        return ([executableDirectory] + extraDirectories + inheritedEntries)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// `inheriting` with `PATH` replaced as described in `path(executableDirectory:inherited:)`.
    public static func environment(executable: URL, inheriting environment: [String: String]) -> [String: String] {
        var environment = environment
        environment["PATH"] = path(executableDirectory: executable.deletingLastPathComponent().path, inherited: environment["PATH"])
        return environment
    }
}

/// Maps failure text (an error result or the tail of standard error) to what the ghost should say.
public enum ClaudeCodeFailureText {
    public static let loginMessage = "Claude Codeにログインしていません。ターミナルで claude を起動してログインしてください"

    /// Lower-cased fragments that indicate a missing or expired login. Kept deliberately small:
    /// `claude` prints e.g. "Invalid API key · Please run /login", "Not logged in", "Failed to authenticate".
    static let loginMarkers = ["login", "log in", "logged in", "authenticat", "api key"]

    /// The login message when `text` looks like a login problem, otherwise `nil`.
    public static func spokenMessage(for text: String) -> String? {
        let lowered = text.lowercased()
        return loginMarkers.contains(where: lowered.contains) ? loginMessage : nil
    }
}
