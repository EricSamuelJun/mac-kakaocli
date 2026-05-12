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
