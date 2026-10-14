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
