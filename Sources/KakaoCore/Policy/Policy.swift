import Foundation

/// An entry on the send-policy allowlist. `chatId` is the canonical key; the
/// other fields are used by the verifier to detect impersonation / row drift
/// (`expectedName` cross-checks the resolved DB displayName, `expectedUserId`
/// pins 1:1 chats to a specific operator on the other side).
public struct PolicyEntry: Codable, Sendable {
    public var chatId: Int64
    public var expectedName: String
    /// nil for group chats — only meaningful for 1:1 rooms where the verifier
    /// can cross-check `NTChatRoom.directChatMemberUserId`.
    public var expectedUserId: Int64?
    /// Short human label for what this entry is for ("primary_account_1on1",
    /// "ops_alerts", etc.). Free-form; not consumed by any verifier yet.
    public var purpose: String

    public init(
        chatId: Int64,
        expectedName: String,
        expectedUserId: Int64? = nil,
        purpose: String
    ) {
        self.chatId = chatId
        self.expectedName = expectedName
        self.expectedUserId = expectedUserId
        self.purpose = purpose
    }
}

/// The send-policy document persisted at `~/.kakaocli/policy.json`. Written
/// by `kakaocli init`; consumed (in a later commit) by the send-path verifier
/// that protects against accidental writes to the wrong chat.
public struct Policy: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var allowlist: [PolicyEntry]
    /// When true, every send target must appear in `allowlist`. When false,
    /// the document is informational and the verifier becomes advisory.
    /// `kakaocli init` writes this as `false` so the file's mere presence
    /// doesn't gate sends before the operator has had a chance to review.
    public var strictMode: Bool
    /// When true, an unknown chatId is denied even in non-strict mode. Kept
    /// as a separate knob so operators can run "strictMode=false but still
    /// reject obviously off-list targets" if they want.
    public var denyByDefault: Bool
    /// chatId of the operator's primary account 1:1 chat. Resolved by
    /// `send --main`, replacing the older `KAKAOCLI_MAIN_CHAT_NAME` env var.
    public var primaryChatId: Int64?

    public init(
        version: Int = Policy.currentVersion,
        allowlist: [PolicyEntry] = [],
        strictMode: Bool = false,
        denyByDefault: Bool = true,
        primaryChatId: Int64? = nil
    ) {
        self.version = version
        self.allowlist = allowlist
        self.strictMode = strictMode
        self.denyByDefault = denyByDefault
        self.primaryChatId = primaryChatId
    }

    /// `~/.kakaocli/policy.json`
    public static var path: String {
        (Config.directory as NSString).appendingPathComponent("policy.json")
    }

    /// Load the policy from disk. Returns nil if the file doesn't exist; throws
    /// if the file is present but unreadable or malformed.
    public static func load(from path: String = Policy.path) throws -> Policy? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Policy.self, from: data)
    }

    /// Write the policy atomically with 0600 perms. Mirrors `Config.save` —
    /// see that file for rationale.
    public func save(to path: String = Policy.path) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }
}
