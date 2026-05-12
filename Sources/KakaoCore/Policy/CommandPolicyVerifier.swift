import Foundation

/// Outcome of an inbound-command policy check.
///
/// `.notACommand` is distinct from `.deny`: it's the "the operator wrote
/// ordinary conversation, ignore silently" signal. `.deny` is "someone
/// tried to run a command they aren't allowed to — log it and surface to
/// the operator." The dispatcher (Hermes / a shell wrapper) branches on
/// the three states; the CLI maps them to exit codes 0 / 1 / 2.
public enum CommandPolicyDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
    case notACommand
}

/// Stateless verifier for the inbound command gate (Option C).
///
/// The pipeline is:
///   sync → message arrives →
///   verify(message, senderUserId, requestedPermission, policy) →
///     allow      → dispatcher executes
///     deny       → dispatcher logs / surfaces to operator
///     notACommand → dispatcher ignores (regular conversation)
///
/// The verifier itself never inspects message *content* beyond the prefix —
/// the LLM dispatcher is responsible for parsing intent into a permission
/// string and feeding it back. Permission strings are opaque (operator-
/// defined); `"*"` in `Policy.rolePermissions` means "any permission".
public enum CommandPolicyVerifier {

    /// Decide whether a sender's message should be processed as a command
    /// authorising `requestedPermission`.
    ///
    /// - Parameters:
    ///   - message: the raw message body as it arrived over sync.
    ///   - senderUserId: KakaoTalk userId of the sender (`NTUser.userId`).
    ///   - requestedPermission: dispatcher-supplied permission string the
    ///       command would exercise (e.g. `"search"`, `"cron.add"`,
    ///       `"send.any"`).
    ///   - policy: loaded `Policy`, or nil if no `policy.json`. nil policy
    ///       denies — Option C is opt-in, the absence of any ACL must not
    ///       silently grant access.
    public static func verify(
        message: String,
        senderUserId: Int64,
        requestedPermission: String,
        policy: Policy?
    ) -> CommandPolicyDecision {
        guard let policy else {
            return .deny(reason: "no policy loaded — inbound command processing is opt-in")
        }
        guard let prefix = policy.commandPrefix, !prefix.isEmpty else {
            // Option C not configured. Treat the message as conversation
            // rather than a denied command, so the dispatcher doesn't log
            // a flood of "denied" entries for normal chatter.
            return .notACommand
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            return .notACommand
        }

        guard let acl = policy.commandAcl,
              let entry = acl.first(where: { $0.userId == senderUserId }) else {
            return .deny(reason: "sender userId \(senderUserId) is not on commandAcl")
        }

        guard let allPerms = policy.rolePermissions else {
            return .deny(reason: "rolePermissions is not configured")
        }
        guard let permissions = allPerms[entry.role] else {
            return .deny(reason: "role '\(entry.role)' has no entry in rolePermissions")
        }

        // Wildcard short-circuit. `"*"` anywhere in the role's list grants
        // every permission for that role.
        if permissions.contains("*") {
            return .allow
        }
        guard permissions.contains(requestedPermission) else {
            return .deny(reason: "role '\(entry.role)' does not include permission '\(requestedPermission)'")
        }
        return .allow
    }
}
