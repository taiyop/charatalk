import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let role: MessageRole
    public var content: String
    public let timestamp: Date
    
    public init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
