import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

public enum ChatContentPart: Equatable, Sendable {
    case text(String)
    case jpegImage(base64EncodedData: String)
}

public struct ChatMessage: Equatable, Sendable {
    public var role: ChatRole
    public var parts: [ChatContentPart]

    public init(role: ChatRole, parts: [ChatContentPart]) {
        self.role = role
        self.parts = parts
    }

    public init(role: ChatRole, text: String) {
        self.init(role: role, parts: [.text(text)])
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
