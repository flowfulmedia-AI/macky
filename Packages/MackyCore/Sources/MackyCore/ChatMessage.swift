import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    /// The result of a tool call, sent back to the model in the next request.
    case tool
}

public enum ChatContentPart: Equatable, Sendable {
    case text(String)
    case jpegImage(base64EncodedData: String)
}

/// A tool call made by the model. The identifier links it to the tool result we send back.
public struct ChatToolCall: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var argumentsJSON: String

    public init(identifier: String, name: String, argumentsJSON: String) {
        self.identifier = identifier
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ChatMessage: Equatable, Sendable {
    public var role: ChatRole
    public var parts: [ChatContentPart]
    /// Only for assistant messages that called tools.
    public var toolCalls: [ChatToolCall]
    /// Only for `.tool` messages: which call this is the result of.
    public var toolCallIdentifier: String?

    public init(role: ChatRole, parts: [ChatContentPart], toolCalls: [ChatToolCall] = [], toolCallIdentifier: String? = nil) {
        self.role = role
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallIdentifier = toolCallIdentifier
    }

    public init(role: ChatRole, text: String) {
        self.init(role: role, parts: [.text(text)])
    }

    public static func toolResult(for toolCall: ChatToolCall, result: String) -> ChatMessage {
        ChatMessage(role: .tool, parts: [.text(result)], toolCallIdentifier: toolCall.identifier)
    }

    public var containsImage: Bool {
        parts.contains { part in
            if case .jpegImage = part { return true }
            return false
        }
    }

    public var plainText: String {
        parts.compactMap { part in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
    }
}
