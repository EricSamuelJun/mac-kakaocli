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

        // Policy gate. HTTP /reply has no per-request bypass — misconfiguration
        // is strictly a policy.json fix, not an override the caller can flip.
        // A malformed policy.json is logged and treated as "no policy" so a bad
        // edit doesn't silently lock the operator out; the operator can also
        // simply delete the file to disable enforcement during recovery.
        let policy: Policy?
        do {
            policy = try Policy.load()
        } catch {
            fputs("policy: failed to load \(Policy.path): \(error). Treating as no policy.\n", stderr)
            policy = nil
        }
        // `try? Optional` returns a double optional — flatten so the verifier
        // sees nil whether the lookup threw or simply found no row.
        let directMember: Int64? = (try? db.directMemberUserId(forChatId: chatId)) ?? nil
        let decision = SendPolicyVerifier.verify(
            chatId: chatId,
            actualName: chat.displayName,
            actualDirectMemberUserId: directMember,
            policy: policy,
            bypass: false
        )
        switch decision {
        case .deny(let reason):
            throw SendError.policyDenied(reason)
        case .allowWithWarning(let warning):
            fputs("policy: \(warning)\n", stderr)
        case .allow:
            break
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
