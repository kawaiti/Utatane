import Foundation

public enum ClaudeCodeEvent: Equatable, Sendable {
    case sessionStarted(id: String)
    case assistantText(String)
    case toolUse(id: String, name: String, command: String?)
    case toolResult(id: String, isError: Bool)
    case finished(result: String, isError: Bool, sessionID: String?)
}

public enum ClaudeCodeEventParser {
    /// Parses one stream-json line into zero or more events. Malformed or unknown lines yield `[]`.
    public static func parse(line: String) -> [ClaudeCodeEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return [] }
            return [.sessionStarted(id: id)]
        case "assistant":
            return contentBlocks(of: object).compactMap { block in
                switch block["type"] as? String {
                case "text":
                    return (block["text"] as? String).map { .assistantText($0) }
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    let input = block["input"] as? [String: Any]
                    return .toolUse(id: id, name: name, command: input?["command"] as? String)
                default:
                    return nil
                }
            }
        case "user":
            return contentBlocks(of: object).compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolResult(id: id, isError: block["is_error"] as? Bool ?? false)
            }
        case "result":
            return [.finished(
                result: object["result"] as? String ?? "",
                isError: object["is_error"] as? Bool ?? false,
                sessionID: object["session_id"] as? String
            )]
        default:
            return []
        }
    }

    private static func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        let message = object["message"] as? [String: Any]
        return message?["content"] as? [[String: Any]] ?? []
    }
}
