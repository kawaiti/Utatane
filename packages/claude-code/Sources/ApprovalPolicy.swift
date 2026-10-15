import Foundation

public enum ApprovalPolicy {
    private static let pipeIntoShell = try! NSRegularExpression(pattern: #"\|\s*(sudo\s+)?(sh|bash|zsh|dash)\b"#)

    /// Heuristic check, biased towards false positives. A flagged command is never run (see `ClaudeCodeSession`).
    ///
    /// Flagged:
    /// - privilege and system control: `sudo`, `doas`, `shutdown`, `reboot`, `halt`, `poweroff`,
    ///   `launchctl unload|remove|bootout`, `killall`, `pkill`, `kill` of pid `-1`;
    /// - destruction: `rm`, `dd`, `mkfs*`, `newfs*`, `shred`, `truncate`, `unlink`, recursive `chmod|chown|chgrp`,
    ///   `diskutil` erase/partition/zero/random/reformat verbs and `diskutil apfs delete*|erase*`;
    /// - git: `push`, `clean`, `reset --hard`, `branch -D` (or `--delete --force`), `checkout` with `--`, `.`, `:/`
    ///   or `-f`, `restore` unless it only unstages (`--staged` without `--worktree`), `stash drop|clear`;
    /// - commands that run other commands from strings or input: `sh|bash|zsh|dash|ksh|fish|csh|tcsh -c`, a shell
    ///   fed by a here-string or heredoc (`bash <<< …`, `sh <<EOF`), piping into a shell however it is named
    ///   (`| /bin/sh`, `| env bash`, `| "bash"`, `| \sh`, `| sudo sh`), `eval`, any `xargs`, `env -S`, and `find`
    ///   with `-delete|-exec|-execdir|-ok|-okdir`.
    ///
    /// Command words are compared with backslashes and quotes removed (`\rm`, `"rm"`, `'rm'`) and directories
    /// stripped (`/bin/rm`), after skipping `NAME=value` assignments and transparent wrappers with their options:
    /// `env`, `command`, `nohup`, `time`, `exec`, `nice`, `timeout` (and its duration), `stdbuf`, `caffeinate`,
    /// `xcrun`, `ionice`, `chroot` (and its new root) and `busybox`. Each wrapper has its own table of options that
    /// take a value; `time -a`, `time -p` etc. take none. Because the tables cannot cover every implementation, once
    /// any wrapper option or positional argument has been skipped every later token is also checked as if it were
    /// the command word (`env -u FOO rm x` is flagged even if `-u` took no value), which may cause false positives
    /// such as `env -i echo rm` or `timeout 5 echo rm`.
    ///
    /// Known false positives: `bash -c ls`, any `xargs` or `eval`, `find -exec`, `git checkout -- file`, and
    /// separators inside quotes (splitting is quote-unaware).
    /// Known limits (not detected): command substitution such as `$(rm x)` or backticks, other interpreters
    /// (`python -c`, `perl -e`, `node -e`, `osascript`), aliases and functions defined earlier in the same command,
    /// variables expanding to a command (`$CMD x`), and wrappers not listed above.
    public static func isDangerous(toolName: String, command: String?) -> Bool {
        guard toolName == "Bash", let command else { return false }
        let whole = NSRange(command.startIndex..., in: command)
        if pipeIntoShell.firstMatch(in: command, range: whole) != nil {
            return true
        }
        return segments(of: command).contains { isDangerousSegment($0.text, afterPipe: $0.afterPipe) }
    }

    /// Splits at every separator character (`&`, `|`, `;`, newline). `afterPipe` is set when the separators before
    /// a segment form a pipe (`|`, `|&`, `|` followed by a newline) rather than `||`, `&&`, `;` or `&`.
    private static func segments(of command: String) -> [(text: String, afterPipe: Bool)] {
        var result: [(text: String, afterPipe: Bool)] = []
        var current = ""
        var separators = ""
        var afterPipe = false
        for character in command {
            if "&|;\n\r".contains(character) {
                separators.append(character)
                continue
            }
            if !separators.isEmpty, !character.isWhitespace {
                // A segment ends at the first non-blank character after a run of separators (blanks are kept with it).
                result.append((current, afterPipe))
                afterPipe = separators.contains("|") && !separators.contains("||")
                current = ""
                separators = ""
            }
            if separators.isEmpty {
                current.append(character)
            } else {
                separators.append(character)
            }
        }
        result.append((current, afterPipe))
        return result
    }

    /// A wrapper runs its first non-option argument (after `positionalArguments` more) as the real command.
    private struct Wrapper {
        /// Options whose value is the next token (attached forms such as `--unset=NAME` take none).
        var optionsWithValue: Set<String> = []
        /// Arguments before the command, such as the duration of `timeout` or the new root of `chroot`.
        var positionalArguments = 0
    }

    /// Per wrapper on purpose: a shared table once made `time -a rm -rf x` look safe.
    private static let wrappers: [String: Wrapper] = [
        "env": Wrapper(optionsWithValue: ["-u", "-C", "-S", "-P", "--unset", "--chdir"]),
        "command": Wrapper(),
        "nohup": Wrapper(),
        "time": Wrapper(optionsWithValue: ["-o", "--output", "-f", "--format"]),
        "exec": Wrapper(optionsWithValue: ["-a"]),
        "nice": Wrapper(optionsWithValue: ["-n", "--adjustment"]),
        "timeout": Wrapper(optionsWithValue: ["-s", "--signal", "-k", "--kill-after"], positionalArguments: 1),
        "stdbuf": Wrapper(optionsWithValue: ["-i", "-o", "-e", "--input", "--output", "--error"]),
        "caffeinate": Wrapper(optionsWithValue: ["-t", "-w"]),
        "xcrun": Wrapper(optionsWithValue: ["--sdk", "-sdk", "--toolchain", "-toolchain"]),
        "ionice": Wrapper(optionsWithValue: ["-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"]),
        "chroot": Wrapper(optionsWithValue: ["--userspec", "--groups"], positionalArguments: 1),
        "busybox": Wrapper()
    ]
    /// `env -S` splits its argument into a command line, which hides the command like `sh -c`.
    private static let splitStringOptions: Set<String> = ["-S", "--split-string"]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
    private static let findActions: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir"]
    /// Dangerous whatever their arguments.
    private static let alwaysDangerous: Set<String> = [
        "rm", "sudo", "doas", "dd", "eval", "xargs", "shred", "truncate", "unlink", "killall", "pkill",
        "shutdown", "reboot", "halt", "poweroff"
    ]

    /// Removes the characters a shell strips from a word: backslashes and single/double quotes.
    private static func unquoted(_ token: String) -> String {
        token.filter { $0 != "\\" && $0 != "'" && $0 != "\"" }
    }

    /// The command name a token runs: directories removed, and anything from a redirection (`bash<<<x`) cut off.
    private static func commandWord(_ token: String) -> String {
        let name = (token as NSString).lastPathComponent
        guard let redirection = name.firstIndex(where: { $0 == "<" || $0 == ">" }), redirection != name.startIndex
        else { return name }
        return String(name[..<redirection])
    }

    private static func isDangerousSegment(_ segment: String, afterPipe: Bool) -> Bool {
        let allTokens = segment.split(whereSeparator: \.isWhitespace).map { unquoted(String($0)) }.filter { !$0.isEmpty }
        var tokens = allTokens[...]
        // Index of the first token after the first skipped wrapper argument; from there on the command word is uncertain.
        var uncertainFrom: Int?
        // Skip NAME=value assignments, wrapper words and the options and arguments directly after a wrapper.
        while let token = tokens.first {
            if isAssignment(token) {
                tokens = tokens.dropFirst()
            } else if let wrapper = wrappers[commandWord(token)] {
                tokens = tokens.dropFirst()
                while let option = tokens.first, option.hasPrefix("-") {
                    if splitStringOptions.contains(option) || option.hasPrefix("--split-string=") {
                        return true
                    }
                    tokens = tokens.dropFirst()
                    if uncertainFrom == nil {
                        uncertainFrom = tokens.startIndex
                    }
                    if wrapper.optionsWithValue.contains(option) {
                        tokens = tokens.dropFirst()
                    }
                }
                for _ in 0 ..< wrapper.positionalArguments where !tokens.isEmpty {
                    tokens = tokens.dropFirst()
                    if uncertainFrom == nil {
                        uncertainFrom = tokens.startIndex
                    }
                }
            } else {
                break
            }
        }
        if afterPipe, let first = tokens.first, shells.contains(commandWord(first)) {
            return true
        }
        if isDangerousCommand(tokens) {
            return true
        }
        // Fallback: the option tables may be wrong for this wrapper, so treat every later token as a possible command word.
        guard let start = uncertainFrom else { return false }
        return (start ..< allTokens.endIndex).contains { isDangerousCommand(allTokens[$0...]) }
    }

    /// Checks `tokens` with the first token as the command word.
    private static func isDangerousCommand(_ tokens: ArraySlice<String>) -> Bool {
        guard let commandToken = tokens.first else { return false }
        let first = commandWord(commandToken)
        let arguments = tokens.dropFirst()
        if alwaysDangerous.contains(first) {
            return true
        }
        switch first {
        case "chmod", "chown", "chgrp":
            return arguments.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("R")) }
        case "git":
            return isDangerousGit(Array(arguments))
        case "find":
            return arguments.contains(where: findActions.contains)
        case "diskutil":
            return isDangerousDiskutil(Array(arguments))
        case "launchctl":
            return arguments.first.map { ["unload", "remove", "bootout"].contains($0) } ?? false
        case "kill":
            return killsEveryProcess(Array(arguments))
        default:
            if shells.contains(first) {
                // `-c`, or combined short options containing `c` such as `-lc`; or a here-string/heredoc as input.
                return commandToken.contains("<<")
                    || arguments.contains { ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c")) || $0.hasPrefix("<<") }
            }
            return first.hasPrefix("mkfs") || first.hasPrefix("newfs")
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
            if arg == "-C" || arg == "-c" {
                rest = rest.dropFirst()
            }
        }
        guard let subcommand = rest.first else { return false }
        let options = rest.dropFirst()
        func hasShort(_ letter: Character) -> Bool {
            options.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(letter) }
        }
        switch subcommand {
        case "push", "clean":
            return true
        case "reset":
            return rest.contains("--hard")
        case "branch":
            let deletes = options.contains("--delete") || hasShort("d")
            let forces = options.contains("--force") || hasShort("f")
            return hasShort("D") || (deletes && forces)
        case "checkout":
            // Discards working tree changes: paths after `--`, the whole tree, or a forced switch.
            return options.contains { ["--", ".", "./", ":/", "*", "--force"].contains($0) } || hasShort("f")
        case "restore":
            // Only `--staged` without `--worktree` keeps the working tree; everything else discards changes.
            let staged = options.contains("--staged") || hasShort("S")
            let worktree = options.contains("--worktree") || hasShort("W")
            return worktree || !staged
        case "stash":
            return options.first.map { $0 == "drop" || $0 == "clear" } ?? false
        default:
            return false
        }
    }

    private static func isDangerousDiskutil(_ args: [String]) -> Bool {
        guard var verb = args.first?.lowercased() else { return false }
        if verb == "apfs" || verb == "cs" || verb == "appleraid" || verb == "ar" {
            verb = args.dropFirst().first?.lowercased() ?? ""
            if verb.hasPrefix("delete") {
                return true
            }
        }
        return ["erase", "partition", "secureerase", "zerodisk", "randomdisk", "reformat"].contains { verb.hasPrefix($0) }
    }

    /// `kill … -1` signals every process the user may signal.
    private static func killsEveryProcess(_ args: [String]) -> Bool {
        var rest = args[...]
        if let first = rest.first {
            if first == "-s" || first == "-n" {
                rest = rest.dropFirst(2)
            } else if first == "--" || first.hasPrefix("-") {
                // `--`, or a signal such as `-9` or `-KILL`; `kill -1 1234` sends signal 1 and is not flagged.
                rest = rest.dropFirst()
            }
        }
        if rest.first == "--" {
            rest = rest.dropFirst()
        }
        return rest.contains("-1")
    }
}
