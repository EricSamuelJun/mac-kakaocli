import Foundation

/// Iris-compatible message payload.
/// Wire format matches the `POST /reply` body of the Iris bot
/// (https://github.com/dolidolih/Iris) so a Spring Boot orchestrator
/// can talk to either `kakaocli serve` or `irisbot` interchangeably.
public struct IrisMessage: Codable, Sendable {
    public let type: String
    public let room: String
    public let data: String
    public let threadId: String?

    public init(type: String = "text", room: String, data: String, threadId: String? = nil) {
        self.type = type
        self.room = room
        self.data = data
        self.threadId = threadId
    }
}

/// Iris-compatible response shape.
/// `success: false` is returned with HTTP 200 for client-side errors
/// (unknown room, unsupported type, etc.) to match Iris semantics.
/// Genuine server faults (DB unreadable) surface as HTTP 5xx.
public struct IrisResponse: Codable, Sendable {
    public let success: Bool
    public let message: String

    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }
}
