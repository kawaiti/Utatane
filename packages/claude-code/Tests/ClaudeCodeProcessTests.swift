import Foundation
import Testing
@testable import UtataneClaudeCode

@Suite(.timeLimit(.minutes(1)))
struct ClaudeCodeProcessTests {
    /// Creates a unique temp directory holding an executable script that echoes every stdin line to stdout.
    private func makeEchoConfiguration() throws -> (ClaudeCodeLaunchConfiguration, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("echo.sh")
        try "#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' \"$line\"; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let configuration = ClaudeCodeLaunchConfiguration(
            executable: script,
            workingDirectory: directory,
            model: nil,
            permissionMode: .default,
            mcpHelperPath: "/dev/null"
        )
        return (configuration, directory)
    }

    private func decodeUserMessage(_ line: String) throws -> (type: String?, role: String?, content: String?) {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = object["message"] as? [String: Any]
        return (object["type"] as? String, message?["role"] as? String, message?["content"] as? String)
    }

    @Test
    func `streams stdout lines and writes stream-json user messages to stdin`() async throws {
        let (configuration, directory) = try makeEchoConfiguration()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = ClaudeCodeProcess()

        let lines = try await process.start(configuration, resume: nil)
        var iterator = lines.makeAsyncIterator()

        try await process.send(userMessage: "こんにちは")
        let first = try decodeUserMessage(#require(await iterator.next()))
        #expect(first.type == "user")
        #expect(first.role == "user")
        #expect(first.content == "こんにちは")

        let tricky = "say \"hi\"\nthen leave"
        try await process.send(userMessage: tricky)
        let second = try decodeUserMessage(#require(await iterator.next()))
        #expect(second.content == tricky)

        await process.terminate()
        #expect(await iterator.next() == nil)
    }

    @Test
    func `starting again terminates the previous process and ends its stream`() async throws {
        let (configuration, directory) = try makeEchoConfiguration()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = ClaudeCodeProcess()

        let oldLines = try await process.start(configuration, resume: nil)
        let newLines = try await process.start(configuration, resume: "abc")

        var oldIterator = oldLines.makeAsyncIterator()
        #expect(await oldIterator.next() == nil)

        var newIterator = newLines.makeAsyncIterator()
        try await process.send(userMessage: "hello")
        let line = try decodeUserMessage(#require(await newIterator.next()))
        #expect(line.content == "hello")

        await process.terminate()
        #expect(await newIterator.next() == nil)
    }

    @Test
    func `terminate and interrupt are safe when nothing is running`() async {
        let process = ClaudeCodeProcess()
        await process.interrupt()
        await process.terminate()
        await process.terminate()
    }

    @Test
    func `send without a running process throws`() async {
        let process = ClaudeCodeProcess()
        await #expect(throws: ClaudeCodeProcessError.notRunning) {
            try await process.send(userMessage: "hello")
        }
    }
}
