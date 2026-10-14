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
