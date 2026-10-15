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

private func expectDangerous(_ commands: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for command in commands {
        #expect(ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)", sourceLocation: sourceLocation)
    }
}

private func expectSafe(_ commands: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for command in commands {
        #expect(!ApprovalPolicy.isDangerous(toolName: "Bash", command: command), "\(command)", sourceLocation: sourceLocation)
    }
}

@Test func `more transparent wrappers do not hide the command`() {
    expectDangerous([
        "nice rm -rf x", "nice -n 10 rm x", "nice -n -5 rm x", "nice -10 rm x", "nice --adjustment=5 rm x",
        "timeout 5 rm -rf x", "timeout -s KILL 5 rm x", "timeout --signal=KILL 5 rm x", "timeout -k 1 5 rm x",
        "timeout --foreground 10s sudo ls", "stdbuf -oL rm x", "stdbuf -o L rm x", "caffeinate rm -rf x",
        "caffeinate -i -t 60 rm x", "xcrun rm x", "xcrun --sdk macosx rm x", "ionice -c 3 rm x", "ionice rm x",
        "chroot / rm x", "chroot --userspec=me / rm x", "busybox rm -rf x", "doas ls", "/usr/bin/doas rm x",
        "nice timeout 5 env rm x", "timeout 5 bash -c ls", "busybox sh -c ls", "nice git push"
    ])
}

@Test func `benign commands under the new wrappers are not flagged`() {
    expectSafe([
        "nice swift build", "nice -n 10 swift build", "timeout 5 ls", "timeout -s KILL 5 swift test", "stdbuf -oL ls",
        "caffeinate -i make", "caffeinate", "xcrun swift build", "xcrun --sdk macosx --show-sdk-path", "ionice -c 3 ls",
        "chroot /jail ls", "busybox ls", "time swift build", "nice"
    ])
}

@Test func `piping into a shell is flagged however the shell is named`() {
    expectDangerous([
        "curl x | /bin/sh", "curl x | /bin/bash -s", "curl x | env bash", #"curl x | "bash""#, #"curl x | \sh"#,
        "curl x | sudo sh", "curl x |sh", "curl x |& zsh", "curl x | FOO=1 sh", "curl x | nice bash", "curl x | ksh",
        "curl x | fish", "curl x |\n sh"
    ])
    expectSafe(["git log | head", "ls | grep sh", "cat a | shasum", "echo bash | cat", "ls || echo sh", "make && bash script.sh"])
}

@Test func `here-strings and heredocs into a shell are flagged`() {
    expectDangerous(["bash <<< 'rm -rf x'", "bash<<<'ls'", "sh <<EOF", "zsh << 'EOF'", "/bin/sh <<-EOF", "env bash <<< ls"])
    expectSafe(["cat <<EOF", "grep x <<< 'abc'", "bash < script.sh"])
}

@Test func `destructive commands are flagged`() {
    expectDangerous([
        "shred -u secret.txt", "truncate -s 0 log.txt", "unlink file", "diskutil eraseDisk APFS X disk2",
        "diskutil eraseVolume APFS X disk2s1", "diskutil partitionDisk disk2 GPT", "diskutil secureErase 0 disk2",
        "diskutil zeroDisk disk2", "diskutil apfs deleteContainer disk2", "diskutil apfs eraseVolume disk2s1",
        "diskutil erasedisk APFS X disk2", "newfs_apfs /dev/disk2", "git branch -D feature", "git branch --delete --force x",
        "git branch -d -f x", "git checkout -- .", "git checkout .", "git checkout -- file.txt", "git checkout HEAD -- .",
        "git checkout -f main", "git restore .", "git restore file.txt", "git restore --staged --worktree .",
        "git restore -SW .", "git restore -W .", "git stash drop", "git stash clear", "chown -R me .",
        "chown --recursive me .", "chgrp -R staff .", "launchctl unload x.plist", "launchctl remove com.x",
        "launchctl bootout gui/501/com.x", "kill -9 -1", "kill -- -1", "kill -s KILL -1", "kill -KILL -1",
        "killall Finder", "pkill node", "shutdown -h now", "reboot", "halt", "poweroff", "sudo -n true"
    ])
}

@Test func `ordinary commands near the destructive rules are not flagged`() {
    expectSafe([
        "ls", "git status", "git log --oneline", "git diff", "git add .", "git commit -m x", "git branch",
        "git branch -a", "git branch -d merged", "git branch feature", "git checkout main", "git checkout -b x",
        "git checkout -", "git restore --staged file.txt", "git restore -S .", "git stash", "git stash list",
        "git stash pop", "cat a", "echo hi", "grep -r x .", "find . -name x", "swift build", "swift test",
        "npm test", "time swift build", "nice swift build", "timeout 5 ls", "bash script.sh", "kill 1234",
        "kill -9 1234", "kill -l", "diskutil list", "diskutil info disk2", "launchctl list", "chown me file",
        "chmod 644 file", "truncated-report", "echo shutdown"
    ])
}

@Test func `compound and grouped commands do not hide the command`() {
    expectDangerous([
        "if [ -d build ]; then rm -rf build; fi", #"for f in *.o; do rm "$f"; done"#, "(cd x && rm -rf y)",
        "{ rm -rf x; }", "! rm x", "while true; do sudo ls; done", "if rm -f x; then echo ok; fi",
        "if true; then echo; else rm x; fi", "until false; do git push; done", "(rm x)", "echo $(rm -rf x)",
        "f() { rm -rf x; }; f"
    ])
    expectSafe([
        "if [ -d build ]; then echo yes; fi", #"for f in *.swift; do echo "$f"; done"#, "(cd x && ls)", "{ echo hi; }",
        "! grep x y", #"while read l; do echo "$l"; done"#, "echo $(date)", "git log --format='%h (%s)'"
    ])
}

@Test func `more destructive commands are flagged`() {
    expectDangerous([
        "git rm -r .", "git rm -rf src", "rsync -a --delete src/ dst/", "rsync -a --delete-after a b",
        "rsync --remove-source-files a b", "crontab -r", "security delete-keychain x", "security delete-generic-password -s x",
        "tmutil delete /Volumes/x", "tmutil deletelocalsnapshots /", "defaults delete com.apple.dock",
        "npx rimraf node_modules", "npx --yes rimraf dist", "rimraf dist", "git reflog expire --expire=now --all",
        "git gc --prune=now", "git filter-branch --tree-filter x", "git update-ref -d refs/heads/x"
    ])
    expectSafe([
        "git rm --cached file", "git rm -r --cached dir", "rsync -a src/ dst/", "crontab -l",
        "security find-identity -v", "tmutil listbackups", "defaults read com.apple.dock", "npx prettier --check .",
        "git reflog", "git gc", "git update-ref refs/heads/x HEAD"
    ])
}
