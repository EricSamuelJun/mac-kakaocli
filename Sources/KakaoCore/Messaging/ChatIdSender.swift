import Foundation

/// Shared "send by chatId" pipeline used by both the HTTP `/reply` server
/// (`LocalAXSender`) and the CLI chatId path (`SendCommand`).
///
/// Centralises the chain: DB lookup → `SendPolicyVerifier` → `KakaoAutomator`.
/// Putting the verifier wiring in one place keeps the HTTP and CLI paths in
/// lockstep — if the policy semantics change, neither side drifts.
public enum ChatIdSender {

    /// Resolve `chatId` against the live DB, run it through the policy
    /// verifier, and hand off to the AX automator. Returns the resolved
    /// `Chat` so callers can format result labels without re-querying.
    ///
    /// - Parameters:
    ///   - bypass: only true when the operator has explicitly opted out
    ///       (CLI `--unsafe-no-verify`). The HTTP path hard-wires this to
    ///       false — a misconfigured policy is a `policy.json` edit, not a
    ///       per-request override the network caller can flip.
    @discardableResult
    public static func send(
        chatId: Int64,
        message: String,
        db: DatabaseReader,
        automator: KakaoAutomator,
        bypass: Bool = false
    ) throws -> Chat {
        guard let chat = try db.chat(byChatId: chatId) else {
            throw SendError.chatNotFound(chatId: chatId)
        }

        // A malformed policy.json is logged and treated as "no policy" so a
        // bad edit doesn't silently lock the operator out; deleting the file
        // is the recovery path.
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
            bypass: bypass
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
            try automator.sendMessage(to: chat.displayName, message: message, selfChat: isSelfChat)
        } catch {
            throw SendError.automationFailed(error)
        }

        return chat
    }
}
