import Foundation

/// MessageSender that delivers an IrisMessage by driving the local
/// KakaoTalk Mac client via AX automation.
///
/// Flow: resolve `message.room` (chatId string) -> DB row -> displayName,
/// then hand off to KakaoAutomator. self-chat (type 5) is routed through
/// the AX badge-based finder automatically.
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
        guard let chat = try db.chat(byChatId: chatId) else {
            throw SendError.chatNotFound(chatId: chatId)
        }

        let isSelfChat = chat.type == .selfChat
        do {
            try automator.sendMessage(to: chat.displayName, message: message.data, selfChat: isSelfChat)
        } catch {
            throw SendError.automationFailed(error)
        }

        let label = isSelfChat ? "self-chat" : chat.displayName
        return IrisResponse(success: true, message: "sent to \(label) (chatId=\(chatId))")
    }
}
