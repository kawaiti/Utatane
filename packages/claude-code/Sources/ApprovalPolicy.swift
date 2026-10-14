import Foundation

public enum ApprovalPolicy {
    private static let pipeIntoShell = try! NSRegularExpression(pattern: #"\|\s*(sudo\s+)?(sh|bash|zsh)\b"#)

    public static func isDangerous(toolName: String, command: String?) -> Bool {
        guard toolName == "Bash", let command else { return false }
        let whole = NSRange(command.startIndex..., in: command)
        if pipeIntoShell.firstMatch(in: command, range: whole) != nil { return true }
        return segments(of: command).contains(where: isDangerousSegment)
    }

    private static func segments(of command: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(command)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if (char == "&" && next == "&") || (char == "|" && next == "|") {
                result.append(current)
                current = ""
                index += 2
                continue
            }
            if char == ";" || char == "|" || char == "\n" || char == "\r" {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index += 1
        }
        result.append(current)
        return result
    }

    private static func isDangerousSegment(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return false }
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
