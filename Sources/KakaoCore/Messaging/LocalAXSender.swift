import Foundation

/// MessageSender that delivers an IrisMessage by driving the local
/// KakaoTalk Mac client via AX automation.
///
/// Resolves `message.room` (chatId string) to a `Chat` row and hands the
/// pair off to `ChatIdSender`, which runs the policy verifier and drives
/// the automator. `bypass` is hard-wired to false here — HTTP callers have
/// no per-request opt-out.
public final class LocalAXSender: MessageSender {
    private let automator: KakaoAutomator
    private let db: DatabaseReader

    public init(automator: KakaoAutomator, db: DatabaseReader) {
        self.automator = automator
        self.db = db
    }

    public func send(_ message: IrisMessage) throws -> IrisResponse {
        guard message.type == "text" else {
            throw SendError.unsupportedType(message.type)
        }
        guard let chatId = Int64(message.room) else {
            throw SendError.invalidRoom(message.room)
        }

        let chat = try ChatIdSender.send(
            chatId: chatId,
            message: message.data,
            db: db,
            automator: automator,
            bypass: false
        )

        let label = chat.type == .selfChat ? "self-chat" : chat.displayName
        return IrisResponse(success: true, message: "sent to \(label) (chatId=\(chatId))")
    }
}
