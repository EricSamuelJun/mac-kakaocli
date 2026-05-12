import ArgumentParser
import Foundation
import KakaoCore

/// Inspect and edit `~/.kakaocli/policy.json`. The root command is a thin
/// dispatcher to `list` / `add` / `manage`; running `kakaocli policy` with
/// no arguments falls through to `list` because that's the most useful
/// default for a curious operator.
struct PolicyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Inspect and edit the send-policy allowlist (~/.kakaocli/policy.json)",
        subcommands: [
            PolicyListCommand.self,
            PolicyAddCommand.self,
        ],
        defaultSubcommand: PolicyListCommand.self
    )
}

// MARK: - policy list

struct PolicyListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List allowlist entries (human-readable or --json for agents)."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON for orchestrators (Hermes, Spring Boot, etc.).")
    var json = false

    func run() throws {
        // `Policy.load` returns nil when the file doesn't exist yet (operator
        // hasn't run `kakaocli init`). We surface that as an empty allowlist
        // rather than an error so the JSON shape is always parseable.
        let policy = try Policy.load() ?? Policy()

        if json {
            try emitJSON(policy)
        } else {
            emitHuman(policy)
        }
    }

    // MARK: - Output shapes

    /// Snake_case keys match the wire format orchestrators already see from
    /// `GET /chats` and the existing CLI `--json` outputs.
    private struct EntryJSON: Encodable {
        let chatId: Int64
        let alias: String?
        let expectedName: String
        let expectedUserId: Int64?
        let purpose: String
        let isPrimary: Bool

        enum CodingKeys: String, CodingKey {
            case chatId = "chat_id"
            case alias
            case expectedName = "expected_name"
            case expectedUserId = "expected_user_id"
            case purpose
            case isPrimary = "is_primary"
        }
    }

    private struct PolicyJSON: Encodable {
        let policyPath: String
        let strictMode: Bool
        let denyByDefault: Bool
        let primaryChatId: Int64?
        let entries: [EntryJSON]

        enum CodingKeys: String, CodingKey {
            case policyPath = "policy_path"
            case strictMode = "strict_mode"
            case denyByDefault = "deny_by_default"
            case primaryChatId = "primary_chat_id"
            case entries
        }
    }

    private func emitJSON(_ policy: Policy) throws {
        let entries = policy.allowlist.map { entry in
            EntryJSON(
                chatId: entry.chatId,
                alias: entry.alias,
                expectedName: entry.expectedName,
                expectedUserId: entry.expectedUserId,
                purpose: entry.purpose,
                isPrimary: policy.primaryChatId == entry.chatId
            )
        }
        let out = PolicyJSON(
            policyPath: Policy.path,
            strictMode: policy.strictMode,
            denyByDefault: policy.denyByDefault,
            primaryChatId: policy.primaryChatId,
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(out)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    fileprivate static func humanRelative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    private func emitHuman(_ policy: Policy) {
        print("policy: \(Policy.path)")
        print("  strictMode:    \(policy.strictMode)")
        print("  denyByDefault: \(policy.denyByDefault)")
        if let pid = policy.primaryChatId {
            print("  primaryChatId: \(pid)")
        } else {
            print("  primaryChatId: (none)")
        }
        print("")

        if policy.allowlist.isEmpty {
            print("(empty allowlist — use `kakaocli policy add` to register a chat)")
            return
        }

        let noun = policy.allowlist.count == 1 ? "entry" : "entries"
        print("Entries (\(policy.allowlist.count) \(noun)):")
        for entry in policy.allowlist {
            let primaryMark = policy.primaryChatId == entry.chatId ? " ★ PRIMARY" : ""
            print("  [\(entry.chatId)] \(entry.expectedName)\(primaryMark)")
            var meta: [String] = ["purpose=\(entry.purpose)"]
            if let alias = entry.alias, !alias.isEmpty {
                meta.append("alias=\"\(alias)\"")
            }
            if let uid = entry.expectedUserId {
                meta.append("expectedUserId=\(uid)")
            }
            print("        \(meta.joined(separator: "  "))")
        }
    }
}

// MARK: - policy add

/// Add a chat to the allowlist. Interactive by default (operator at a
/// terminal). Pass `--chat-id` to switch into the unattended path that
/// Hermes / LLM agents use through the skill manifest.
struct PolicyAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Register a chat with the allowlist so it passes the send-policy verifier."
    )

    // Non-interactive path. Any of these being set switches off the TUI.
    @Option(name: .long, help: "chatId to add. Required for non-interactive use.")
    var chatId: Int64?

    @Option(name: .long, help: "Optional human-friendly alias (e.g. \"49기방\"). Must be unique across the allowlist.")
    var alias: String?

    @Option(name: .long, help: "Free-form purpose description.")
    var purpose: String?

    @Flag(name: .long, help: "Don't pin expectedUserId on 1:1 chats (default: pin to the friend's userId).")
    var noPinUserId = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        var policy = try Policy.load() ?? Policy()

        if let id = chatId {
            try addNonInteractive(policy: &policy, reader: reader, chatId: id)
        } else {
            try addInteractive(policy: &policy, reader: reader)
        }

        try policy.save()
    }

    // MARK: - Non-interactive (agent / script)

    private func addNonInteractive(policy: inout Policy, reader: DatabaseReader, chatId: Int64) throws {
        if policy.allowlist.contains(where: { $0.chatId == chatId }) {
            throw ValidationError("chatId \(chatId) is already in the allowlist. Use `kakaocli policy manage \(chatId)` to modify it.")
        }
        guard let chat = try reader.chat(byChatId: chatId) else {
            throw ValidationError("chatId \(chatId) was not found in the KakaoTalk database.")
        }
        if let alias, !alias.isEmpty,
           policy.allowlist.contains(where: { $0.alias == alias }) {
            throw ValidationError("alias \"\(alias)\" is already used by another entry. Aliases must be unique.")
        }

        let pinnedUserId: Int64?
        if noPinUserId || chat.type != .direct {
            pinnedUserId = nil
        } else {
            pinnedUserId = (try? reader.directMemberUserId(forChatId: chatId)) ?? nil
        }

        let entry = PolicyEntry(
            chatId: chatId,
            expectedName: chat.displayName,
            expectedUserId: pinnedUserId,
            purpose: purpose ?? "",
            alias: (alias?.isEmpty == false) ? alias : nil
        )
        policy.allowlist.append(entry)

        let aliasNote = entry.alias.map { " alias=\"\($0)\"" } ?? ""
        let pinNote = entry.expectedUserId.map { " userId=\($0)" } ?? ""
        print("Added [\(chatId)] \(chat.displayName)\(aliasNote)\(pinNote)")
    }

    // MARK: - Interactive (operator at a terminal)

    private func addInteractive(policy: inout Policy, reader: DatabaseReader) throws {
        let existingIds = Set(policy.allowlist.map { $0.chatId })
        let allChats = try reader.chats(limit: 1000)
        let candidates = allChats.filter { !existingIds.contains($0.id) }

        if candidates.isEmpty {
            print("No chats available to add — every chat known to the database is already in the allowlist.")
            return
        }

        // Show up to 20 candidates ordered by recency (DatabaseReader already
        // sorts by lastUpdatedAt DESC). Operators wanting something deeper in
        // the list pass --chat-id directly.
        let shown = Array(candidates.prefix(20))
        print("Candidates not yet on the allowlist (most recent first):")
        for (i, c) in shown.enumerated() {
            let ago = c.lastMessageAt.map(PolicyListCommand.humanRelative) ?? "never"
            print("  [\(i + 1)] [\(c.id)] \(c.displayName)  type=\(c.type.rawValue)  last=\(ago)")
        }
        if candidates.count > shown.count {
            print("  (\(candidates.count - shown.count) more not shown — re-run with `--chat-id <id>` for those)")
        }
        let cancelIndex = shown.count + 1
        print("  [\(cancelIndex)] cancel")
        print("Select [1-\(cancelIndex)]:", terminator: " ")

        guard let line = readLine(),
              let n = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...cancelIndex).contains(n) else {
            throw ValidationError("Invalid selection.")
        }
        if n == cancelIndex {
            print("Cancelled. policy.json unchanged.")
            throw ExitCode(0)
        }
        let chosen = shown[n - 1]

        // Alias
        print("Alias (orchestrator label like \"49기방\"; blank to skip):", terminator: " ")
        let rawAlias = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosenAlias: String?
        if rawAlias.isEmpty {
            chosenAlias = nil
        } else {
            if policy.allowlist.contains(where: { $0.alias == rawAlias }) {
                throw ValidationError("alias \"\(rawAlias)\" is already used by another entry. Aliases must be unique.")
            }
            chosenAlias = rawAlias
        }

        // Purpose
        print("Purpose (free-form note, e.g. \"team_cron\"; blank to skip):", terminator: " ")
        let rawPurpose = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Pin expectedUserId on 1:1 chats
        var pinnedUserId: Int64? = nil
        if chosen.type == .direct,
           let direct = (try? reader.directMemberUserId(forChatId: chosen.id)) ?? nil {
            print("Pin expectedUserId=\(direct) so the verifier rejects mismatches? [Y/n]:", terminator: " ")
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            pinnedUserId = (answer.isEmpty || answer == "y" || answer == "yes") ? direct : nil
        }

        let entry = PolicyEntry(
            chatId: chosen.id,
            expectedName: chosen.displayName,
            expectedUserId: pinnedUserId,
            purpose: rawPurpose,
            alias: chosenAlias
        )
        policy.allowlist.append(entry)

        let aliasNote = entry.alias.map { " alias=\"\($0)\"" } ?? ""
        let pinNote = entry.expectedUserId.map { " userId=\($0)" } ?? ""
        print("Added [\(chosen.id)] \(chosen.displayName)\(aliasNote)\(pinNote)")
    }
}
