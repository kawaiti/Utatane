import Foundation

public enum ApprovalPolicy {
    private static let pipeIntoShell = try! NSRegularExpression(pattern: #"\|\s*(sudo\s+)?(sh|bash|zsh|dash)\b"#)

    /// Heuristic check, biased towards false positives.
    ///
    /// Flagged: `rm`, `sudo`, `dd`, `mkfs*`, recursive `chmod`, `git push|clean|reset --hard`, piping into a shell,
    /// `sh|bash|zsh|dash -c`, `eval`, any `xargs`, `env -S`, and `find` with `-delete|-exec|-execdir|-ok|-okdir`.
    /// Command words are compared with backslashes and quotes removed (`\rm`, `"rm"`, `'rm'`), after skipping
    /// `NAME=value` assignments and the wrappers `env`, `command`, `nohup`, `time`, `exec` with their options.
    /// An option swallows the next token only if it takes a value for that particular wrapper
    /// (`env -u|-C|-S|-P|--unset|--chdir`, `exec -a`, `time -o|--output|-f|--format`); `time -a`, `time -p` etc.
    /// do not. Because the option tables cannot cover every implementation, once any wrapper option has been
    /// skipped every later token is also checked as if it were the command word (`env -u FOO rm x` is flagged
    /// even if `-u` took no value), which may cause false positives such as `env -i echo rm`.
    ///
    /// Known limits (not detected): command substitution such as `$(rm x)` or backticks, other interpreters
    /// (`python -c`, `perl -e`, `node -e`), aliases and functions defined earlier in the same command, and
    /// variables expanding to a command (`$CMD x`). Splitting is quote-unaware, so separators inside quotes
    /// may cause false positives.
    public static func isDangerous(toolName: String, command: String?) -> Bool {
        guard toolName == "Bash", let command else { return false }
        let whole = NSRange(command.startIndex..., in: command)
        if pipeIntoShell.firstMatch(in: command, range: whole) != nil { return true }
        return segments(of: command).contains(where: isDangerousSegment)
    }

    private static func segments(of command: String) -> [String] {
        // Every separator character (`&`, `|`, `;`, newline) splits; `&&` and `||` just yield an empty segment.
        command.split(omittingEmptySubsequences: false) { "&|;\n\r".contains($0) }.map(String.init)
    }

    private static let wrapperWords: Set<String> = ["env", "command", "nohup", "time", "exec"]
    /// Per wrapper, the options whose value is the next token (attached forms such as `--unset=NAME` take none).
    /// `command` and `nohup` have no value-taking options.
    private static let wrapperOptionsWithValue: [String: Set<String>] = [
        "env": ["-u", "-C", "-S", "-P", "--unset", "--chdir"],
        "exec": ["-a"],
        "time": ["-o", "--output", "-f", "--format"],
    ]
    /// `env -S` splits its argument into a command line, which hides the command like `sh -c`.
    private static let splitStringOptions: Set<String> = ["-S", "--split-string"]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash"]
    private static let findActions: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir"]

    /// Removes the characters a shell strips from a word: backslashes and single/double quotes.
    private static func unquoted(_ token: String) -> String {
        token.filter { $0 != "\\" && $0 != "'" && $0 != "\"" }
    }

    private static func isDangerousSegment(_ segment: String) -> Bool {
        let allTokens = segment.split(whereSeparator: \.isWhitespace).map { unquoted(String($0)) }.filter { !$0.isEmpty }
        var tokens = allTokens[...]
        // Index of the first token after the first wrapper option; from there on the command word is uncertain.
        var uncertainFrom: Int?
        // Skip NAME=value assignments, wrapper words and options directly after a wrapper.
        while let token = tokens.first {
            let word = (token as NSString).lastPathComponent
            if isAssignment(token) {
                tokens = tokens.dropFirst()
            } else if wrapperWords.contains(word) {
                tokens = tokens.dropFirst()
                let valueOptions = wrapperOptionsWithValue[word] ?? []
                while let option = tokens.first, option.hasPrefix("-") {
                    if splitStringOptions.contains(option) || option.hasPrefix("--split-string=") { return true }
                    tokens = tokens.dropFirst()
                    if uncertainFrom == nil { uncertainFrom = tokens.startIndex }
                    if valueOptions.contains(option) { tokens = tokens.dropFirst() }
                }
            } else {
                break
            }
        }
        if isDangerousCommand(tokens) { return true }
        // Fallback: the option tables may be wrong for this wrapper, so treat every later token as a possible command word.
        guard let start = uncertainFrom else { return false }
        return (start..<allTokens.endIndex).contains { isDangerousCommand(allTokens[$0...]) }
    }

    /// Checks `tokens` with the first token as the command word.
    private static func isDangerousCommand(_ tokens: ArraySlice<String>) -> Bool {
        guard let commandToken = tokens.first else { return false }
        let first = (commandToken as NSString).lastPathComponent
        let arguments = tokens.dropFirst()
        switch first {
        case "rm", "sudo", "dd", "eval", "xargs":
            return true
        case "chmod":
            return arguments.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("R")) }
        case "git":
            return isDangerousGit(Array(arguments))
        case "find":
            return arguments.contains(where: findActions.contains)
        default:
            if shells.contains(first) {
                // `-c`, or combined short options containing `c` such as `-lc`.
                return arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }
            }
            return first.hasPrefix("mkfs")
        }
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        return token[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isDangerousGit(_ args: [String]) -> Bool {
        var rest = args[...]
        while let arg = rest.first, arg.hasPrefix("-") {
            rest = rest.dropFirst()
            if arg == "-C" || arg == "-c" { rest = rest.dropFirst() }
        }
        guard let subcommand = rest.first else { return false }
        switch subcommand {
        case "push", "clean": return true
        case "reset": return rest.contains("--hard")
        default: return false
        }
    }
}
