import Foundation
import Testing
@testable import UtataneMCP

@Test func `initializes and lists SSP compatible tools`() async throws {
    let server = MCPServer(client: UtataneBridgeClient())
    let initialized = try #require(await server.handle([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": ["protocolVersion": "2025-06-18"]
    ]))
    let result = try #require(initialized["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")

    let listed = try #require(await server.handle([
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list"
    ]))
    let listResult = try #require(listed["result"] as? [String: Any])
    let tools = try #require(listResult["tools"] as? [[String: Any]])
    #expect(Set(tools.compactMap { $0["name"] as? String }) == [
        "get_active_ghost_list", "get_expression_table", "SakuraScript", "get_status", "get_log", "raise_event", "reload", "dump_surface", "dump_balloon", "approve"
    ])
}

@Test func `MCP event arguments round trip through encoded payload without header injection`() async throws {
    let client = UtataneBridgeClient(send: { request in
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("Command: RaiseEvent\r\n"))
        let encoded = try #require(body.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Payload: ") }))
        let data = try #require(Data(base64Encoded: String(encoded.dropFirst(9))))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["references"] as? [String] == ["a\r\nCommand: Reload", "日本語"])
        #expect(!body.contains("\r\nCommand: Reload"))
        return (Data("SSTP/1.4 200 OK\r\nScript: {\"event\":\"OnTest\"}\r\n\r\n".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let server = MCPServer(client: client)
    let response = try #require(await server.handle(["id": 1, "method": "tools/call", "params": ["name": "raise_event", "arguments": ["event": "OnTest", "references": ["a\r\nCommand: Reload", "日本語"]]]]))
    #expect(response["error"] == nil)
    let invalid = try #require(await server.handle(["id": 2, "method": "tools/call", "params": ["name": "dump_surface", "arguments": [:]]]))
    #expect(invalid["error"] != nil)
}

private func approveServer(status: Int = 200, body: String, inspect: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> MCPServer {
    MCPServer(client: UtataneBridgeClient(send: { request in
        inspect(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }))
}

private func callApprove(_ server: MCPServer, arguments: [String: Any]) async throws -> (response: [String: Any], decision: [String: Any]?) {
    let response = try #require(await server.handle(["id": 1, "method": "tools/call", "params": ["name": "approve", "arguments": arguments]]))
    let result = response["result"] as? [String: Any]
    let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
    let decision = text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    return (response, decision)
}

private var approveArguments: [String: Any] { ["tool_name": "Bash", "input": ["command": "ls -la"], "tool_use_id": "toolu_1"] }

@Test func `approve tool maps bridge allow and deny responses to permission JSON`() async throws {
    let allow = try await callApprove(approveServer(body: "SSTP/1.4 200 OK\r\nScript: {\"allow\":true}\r\n\r\n"), arguments: approveArguments)
    #expect(allow.response["error"] == nil)
    #expect(allow.decision?["behavior"] as? String == "allow")
    #expect(allow.decision?["updatedInput"] as? [String: String] == ["command": "ls -la"])

    let deny = try await callApprove(approveServer(body: "SSTP/1.4 200 OK\r\nScript: {\"allow\":false,\"reason\":\"拒否\"}\r\n\r\n"), arguments: approveArguments)
    #expect(deny.decision?["behavior"] as? String == "deny")
    #expect(deny.decision?["message"] as? String == "拒否")

    let noReason = try await callApprove(approveServer(body: "SSTP/1.4 200 OK\r\nScript: {\"allow\":false}\r\n\r\n"), arguments: approveArguments)
    #expect(noReason.decision?["behavior"] as? String == "deny")
    #expect(noReason.decision?["message"] as? String == "ユーザーが拒否した")
}

@Test func `approve tool fails closed when no explicit allow is obtained`() async throws {
    let bodies: [(Int, String)] = [
        (500, "SSTP/1.4 200 OK\r\nScript: {\"allow\":true}\r\n\r\n"),
        (200, "SSTP/1.4 500 Error\r\n\r\n"),
        (200, "SSTP/1.4 204 No Content\r\n\r\n"),
        (200, "SSTP/1.4 200 OK\r\nScript: garbage\r\n\r\n"),
        (200, "SSTP/1.4 200 OK\r\nScript: {\"allow\":\"true\"}\r\n\r\n"),
        (200, "SSTP/1.4 200 OK\r\nScript: {\"allow\":1}\r\n\r\n"),
        (200, "SSTP/1.4 200 OK\r\nScript: {}\r\n\r\n")
    ]
    for (status, body) in bodies {
        let result = try await callApprove(approveServer(status: status, body: body), arguments: approveArguments)
        #expect(result.response["error"] == nil, "body: \(body)")
        #expect(result.decision?["behavior"] as? String == "deny", "body: \(body)")
        #expect(result.decision?["updatedInput"] == nil)
        #expect((result.decision?["message"] as? String)?.isEmpty == false)
    }
    let unreachable = MCPServer(client: UtataneBridgeClient(send: { _ in throw MCPError.utataneUnavailable }))
    let result = try await callApprove(unreachable, arguments: approveArguments)
    #expect(result.response["error"] == nil)
    #expect(result.decision?["behavior"] as? String == "deny")
    #expect((result.decision?["message"] as? String)?.contains("接続できない") == true)
    let urlError = MCPServer(client: UtataneBridgeClient(send: { _ in throw URLError(.cannotConnectToHost) }))
    let urlResult = try await callApprove(urlError, arguments: approveArguments)
    #expect(urlResult.decision?["behavior"] as? String == "deny")
    #expect((urlResult.decision?["message"] as? String)?.contains("接続できない") == true)
    let other = MCPServer(client: UtataneBridgeClient(send: { _ in throw CocoaError(.fileReadUnknown) }))
    let otherResult = try await callApprove(other, arguments: approveArguments)
    #expect(otherResult.decision?["behavior"] as? String == "deny")
    #expect((otherResult.decision?["message"] as? String)?.contains("失敗") == true)
}

@Test func `approve tool requires tool_name`() async throws {
    for arguments in [[:], ["tool_name": ""], ["tool_name": 3]] as [[String: Any]] {
        let result = try await callApprove(approveServer(body: "SSTP/1.4 200 OK\r\nScript: {\"allow\":true}\r\n\r\n"), arguments: arguments)
        #expect(result.response["error"] != nil)
    }
}

@Test func `approve request uses ApproveTool command, 60 second timeout and encoded payload`() async throws {
    let server = approveServer(body: "SSTP/1.4 200 OK\r\nScript: {\"allow\":true}\r\n\r\n", inspect: { request in
        #expect(request.timeoutInterval == UtataneBridgeClient.approvalTimeout)
        #expect(UtataneBridgeClient.approvalTimeout == 60)
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("Command: ApproveTool\r\n"))
        #expect(!body.contains("\r\nCommand: Reload"))
        let lines = body.components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("Command:") }.count == 1)
        let encoded = lines.first(where: { $0.hasPrefix("Payload: ") }).map { String($0.dropFirst(9)) }
        let payload = encoded.flatMap { Data(base64Encoded: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(payload?["tool_name"] as? String == "Bash\r\nCommand: Reload")
        #expect(payload?["tool_use_id"] as? String == "toolu_1")
        #expect(payload?["input"] as? [String: String] == ["command": "ls -la"])
    })
    let result = try await callApprove(server, arguments: ["tool_name": "Bash\r\nCommand: Reload", "input": ["command": "ls -la"], "tool_use_id": "toolu_1"])
    #expect(result.decision?["behavior"] as? String == "allow")
}

@Test func `other commands keep the default request timeout`() async throws {
    let client = UtataneBridgeClient(send: { request in
        #expect(request.timeoutInterval == URLRequest(url: request.url!).timeoutInterval)
        return (Data("SSTP/1.4 200 OK\r\nScript: []\r\n\r\n".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    _ = try await client.command("GetActiveGhostList")
}

@Test func `command applies the requested timeout to the request`() async throws {
    let client = UtataneBridgeClient(send: { request in
        #expect(request.timeoutInterval == 7)
        return (Data("SSTP/1.4 200 OK\r\nScript: []\r\n\r\n".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    _ = try await client.command("GetActiveGhostList", timeout: 7)
}

@Test func `approve denies malformed input but accepts missing input`() async throws {
    let allowBody = "SSTP/1.4 200 OK\r\nScript: {\"allow\":true}\r\n\r\n"
    for badInput in [["a"], "ls", 3] as [Any] {
        let result = try await callApprove(approveServer(body: allowBody), arguments: ["tool_name": "Bash", "input": badInput])
        #expect(result.response["error"] == nil)
        #expect(result.decision?["behavior"] as? String == "deny")
        #expect((result.decision?["message"] as? String)?.contains("不正") == true)
    }
    let missing = try await callApprove(approveServer(body: allowBody), arguments: ["tool_name": "Bash"])
    #expect(missing.decision?["behavior"] as? String == "allow")
    #expect((missing.decision?["updatedInput"] as? [String: Any])?.isEmpty == true)
}
