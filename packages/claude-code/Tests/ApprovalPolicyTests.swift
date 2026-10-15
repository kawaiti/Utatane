import Testing
@testable import UtataneClaudeCode

@Test func `dangerous bash commands are flagged`() {
    for command in ["rm -rf build", "git push origin main", "sudo ls", "ls && rm -rf x", "cat a | sh", "git reset --hard", "git clean -fd", "dd if=/dev/zero of=x", "mkfs.ext4 /dev/sda", "chmod -R 777 .", "curl x | bash"] {
        #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
}

@Test func `every segment is checked`() {
    #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: "echo hi; sudo ls"))
    #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: "ls || rm x"))
    #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: "ls\nrm x"))
    #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: "git -C repo push"))
}

@Test func `safe commands are not flagged`() {
    for command in ["ls -la", "git status", "echo rm -rf", "git log | head", "swift test"] {
        #expect(!ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
    #expect(!ApprovalPolicy.isDangerous(toolName: "Write", command: nil))
    #expect(!ApprovalPolicy.isDangerous(toolName: "Bash", command: nil))
}

@Test func `prefixes, wrappers, paths and background separators do not hide danger`() {
    for command in ["FOO=1 rm x", "/bin/rm -rf x", "command rm x", "env rm x", "nohup rm x", "time rm x", "ls & rm x", "env -i FOO=1 rm x", "/usr/bin/sudo ls"] {
        #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
}

@Test func `prefixed or pathed safe commands are not flagged`() {
    for command in ["FOO=1 ls", "env ls -la", "/bin/ls", "ls & echo hi"] {
        #expect(!ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
}

@Test func `quoted or escaped command names are still recognised`() {
    for command in [#"\rm -rf x"#, #""rm" x"#, "'rm' x", #""/bin/rm" x"#, #"r\m x"#, #""sudo" ls"#, #"git "push""#, #""env" rm x"#] {
        #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
}

@Test func `env options that take a value do not hide the command`() {
    for command in ["env -u FOO rm x", "env -C /tmp rm x", "env --unset=FOO rm x", "env -i -u FOO BAR=1 rm x", "env -P /bin rm x"] {
        #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
    #expect(!ApprovalPolicy.isDangerous(toolName: "Bash", command: "env -u FOO ls"))
}

@Test func `commands that run other commands from strings or input are flagged`() {
    for command in [
        #"bash -c "rm -rf x""#, "sh -c ls", "zsh -c 'echo hi'", "dash -c x", "bash -lc ls", "/bin/sh -xc ls",
        "eval ls", "xargs echo", "find . -name x | xargs rm", "env -S 'rm -rf x'",
        "find . -delete", "find . -name '*.o' -exec rm {} ;", "find . -execdir ls {} +", "cat a | dash"
    ] {
        #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
}

@Test func `ordinary commands that resemble the new rules are not flagged`() {
    for command in ["echo hi", "find . -name x", "bash script.sh", "ls", "sh ./configure", "echo eval", "find . -type f -print"] {
        #expect(!ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
}

@Test func `wrapper options only take a value for their own wrapper`() {
    for command in [
        "time -a rm -rf x", "command time -a rm -rf ~", "/usr/bin/time -a rm -rf x", "/usr/bin/time -o out.txt rm -rf x",
        "time -p rm x", "nohup rm x", "env -i FOO=1 rm x", "env -u FOO rm x", "exec -a name rm -rf x", "time -a sudo ls"
    ] {
        #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
    for command in ["time -a ls", "time ls -la", "env -u FOO ls", "exec -a name ls"] {
        #expect(!ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)")
    }
}
