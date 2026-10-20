import Foundation

/// Presentation-only state. The full reply remains in conversation history
/// while its subtitle waits for the audio player's start notification.
public struct SpeechSubtitleState: Sendable {
    public private(set) var pendingMessageID: UUID?

    public init() {}

    public mutating func prepare(for messageID: UUID) {
        pendingMessageID = messageID
    }

    /// Also used on synthesis failure or completion without audible speech.
    /// A late callback/cleanup from an older reply must not reveal a newer one.
    public mutating func reveal(for messageID: UUID) {
        guard pendingMessageID == messageID else { return }
        pendingMessageID = nil
    }

    public mutating func reset() {
        pendingMessageID = nil
    }

    public func visibleMessage(in messages: [ChatMessage]) -> ChatMessage? {
        guard let message = messages.last, message.id != pendingMessageID else { return nil }
        return message
    }
}
