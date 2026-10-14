import Foundation

public enum ApprovalPolicy {
    private static let pipeIntoShell = try! NSRegularExpression(pattern: #"\|\s*(sudo\s+)?(sh|bash|zsh)\b"#)

    /// Heuristic check, biased towards false positives. Known limits (not detected):
    /// `bash -c "rm -rf x"`, command substitution such as `$(rm x)`, `xargs rm`.
    /// Splitting is quote-unaware, so separators inside quotes may cause false positives.
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

    private static func isDangerousSegment(_ segment: String) -> Bool {
        var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        // Skip NAME=value assignments, wrapper words and options directly after a wrapper.
        while let token = tokens.first {
            if isAssignment(token) {
                tokens = tokens.dropFirst()
            } else if wrapperWords.contains(token) {
                tokens = tokens.dropFirst()
                while let option = tokens.first, option.hasPrefix("-") { tokens = tokens.dropFirst() }
            } else {
                break
            }
        }
        guard let commandToken = tokens.first else { return false }
        let first = (commandToken as NSString).lastPathComponent
        switch first {
        case "rm", "sudo", "dd":
            return true
        case "chmod":
            return tokens.dropFirst().contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("R")) }
        case "git":
            return isDangerousGit(Array(tokens.dropFirst()))
        default:
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
