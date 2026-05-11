import Foundation

/// Port for delivering an `IrisMessage` to KakaoTalk.
/// The HTTP server and (eventually) the CLI funnel through this so that
/// future policy / cross-check logic has a single insertion point.
public protocol MessageSender {
    func send(_ message: IrisMessage) throws -> IrisResponse
}

/// Errors a `MessageSender` may throw before reaching the UI automation step.
public enum SendError: Error, CustomStringConvertible {
    case invalidRoom(String)
    case chatNotFound(chatId: Int64)
    case unsupportedType(String)
    case automationFailed(Error)
    case policyDenied(String)

    public var description: String {
        switch self {
        case .invalidRoom(let s): return "Invalid room value (must be numeric chatId): \(s)"
        case .chatNotFound(let id): return "Chat not found in database: \(id)"
        case .unsupportedType(let t): return "Unsupported message type: \(t)"
        case .automationFailed(let e): return "UI automation failed: \(e)"
        case .policyDenied(let reason): return "Send denied by policy: \(reason)"
        }
    }
}
