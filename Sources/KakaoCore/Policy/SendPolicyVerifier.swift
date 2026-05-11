import Foundation

/// Outcome of a send-policy verification. The `.allowWithWarning` case lets
/// the caller emit an audit trail (typically to stderr / the server log) on
/// non-fatal advisory paths — operator running without strict mode, or with
/// an explicit `--unsafe-no-verify` bypass — without silencing the warning.
public enum SendPolicyDecision: Equatable, Sendable {
    case allow
    case allowWithWarning(String)
    case deny(reason: String)
}

/// Stateless verifier deciding whether a send to a given chatId should
/// proceed, given the operator's loaded Policy and the chat metadata the
/// database reports.
///
/// Intentionally pure — no I/O, no AX, no DB. Callers resolve chat metadata
/// themselves and hand it in, which keeps the decision matrix trivially
/// testable and concentrates the policy logic in one place regardless of
/// whether the send originates from HTTP `/reply`, the CLI, or a future
/// scheduler.
public enum SendPolicyVerifier {

    /// Verify a send target against the loaded policy.
    /// - Parameters:
    ///   - chatId: numeric KakaoTalk chatId being targeted.
    ///   - actualName: displayName the DB reports for `chatId` (resolved
    ///       through `NTChatRoom.chatName → NTChatMeta → friend → roster`).
    ///   - actualDirectMemberUserId: `NTChatRoom.directChatMemberUserId` for
    ///       the row; nil for groups / self-chat / open channels.
    ///   - policy: loaded `Policy`, or nil when `policy.json` is absent.
    ///       Absent policy means no enforcement.
    ///   - bypass: only true when the caller has explicit operator opt-out
    ///       (CLI `--unsafe-no-verify`). Yields a warning rather than full
    ///       silence so misuse leaves a trace.
    public static func verify(
        chatId: Int64,
        actualName: String,
        actualDirectMemberUserId: Int64?,
        policy: Policy?,
        bypass: Bool = false
    ) -> SendPolicyDecision {
        if bypass {
            return .allowWithWarning("send policy bypassed (--unsafe-no-verify)")
        }
        guard let policy else {
            // No policy.json → no enforcement. Init scaffolds this file, so
            // this branch is "operator hasn't initialised yet".
            return .allow
        }

        if let entry = policy.allowlist.first(where: { $0.chatId == chatId }) {
            return verifyAllowlistedEntry(
                entry: entry,
                actualName: actualName,
                actualDirectMemberUserId: actualDirectMemberUserId
            )
        }

        // chatId is not in the allowlist.
        if policy.strictMode {
            return .deny(reason: "strictMode is on and chatId \(chatId) is not in the allowlist")
        }
        if policy.denyByDefault {
            return .deny(reason: "denyByDefault is on and chatId \(chatId) is not in the allowlist")
        }
        return .allowWithWarning("chatId \(chatId) is not in the allowlist (advisory mode)")
    }

    /// Verify the DB-resolved chat metadata against an allowlisted policy
    /// entry. Name matching reuses `AXHelpers.chatTitleMatches` so the policy
    /// matcher and the chat-window header cross-check agree on normalisation
    /// (NFC + trim + lowercase substring).
    private static func verifyAllowlistedEntry(
        entry: PolicyEntry,
        actualName: String,
        actualDirectMemberUserId: Int64?
    ) -> SendPolicyDecision {
        if !AXHelpers.chatTitleMatches(title: actualName, expected: entry.expectedName) {
            return .deny(reason: "expectedName mismatch for chatId \(entry.chatId): policy says '\(entry.expectedName)', DB resolved '\(actualName)'")
        }
        // expectedUserId pins the other side of a 1:1 chat. nil means the
        // entry is for a group / self-chat / open channel where
        // directChatMemberUserId doesn't apply, so the check is skipped.
        if let expectedUid = entry.expectedUserId {
            guard actualDirectMemberUserId == expectedUid else {
                let actual = actualDirectMemberUserId.map(String.init) ?? "<null>"
                return .deny(reason: "expectedUserId mismatch for chatId \(entry.chatId): policy says \(expectedUid), DB resolved \(actual)")
            }
        }
        return .allow
    }
}
