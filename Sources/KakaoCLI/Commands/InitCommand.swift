import ArgumentParser
import Foundation
import KakaoCore

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "First-time setup: request permissions, recover userId, scaffold config and policy files"
    )

    @Flag(name: .long, help: "Run without interactive prompts; skips primary-chat selection")
    var nonInteractive = false

    @Flag(name: .long, help: "Overwrite existing config.json / policy.json if present")
    var force = false

    @Flag(name: .long, help: "Skip Accessibility and Full Disk Access checks")
    var skipPermissions = false

    @Option(name: .long, help: "Pre-fill primary chatId without prompting")
    var primaryChatId: Int64?

    @Option(name: .long, help: "userId recovery wall-clock budget in seconds (default 60)")
    var maxSeconds: Double = 60.0

    func run() throws {
        try guardAgainstExistingConfig()

        try step1_createDirectory()

        if skipPermissions {
            print("[2/5] Accessibility check — skipped (--skip-permissions)")
            print("[3/5] Full Disk Access check — skipped (--skip-permissions)")
        } else {
            step2_accessibility()
            step3_fullDiskAccess()
        }

        let userId = try step4_recoverUserId()

        let primary = try step5_primaryChat(userId: userId)

        try writeConfig(userId: userId)
        try writePolicy(primary: primary)

        print()
        print("Setup complete. Verify with:")
        print("  kakaocli auth")
        if primary != nil {
            print("  kakaocli send --main _ \"init test\"")
        }
    }

    // MARK: - Steps

    private func guardAgainstExistingConfig() throws {
        let configExists = FileManager.default.fileExists(atPath: Config.path)
        let policyExists = FileManager.default.fileExists(atPath: Policy.path)
        guard (configExists || policyExists) && !force else { return }
        var lines = ["Existing setup detected at \(Config.directory):"]
        if configExists { lines.append("  - config.json") }
        if policyExists { lines.append("  - policy.json") }
        lines.append("")
        lines.append("Re-run with --force to overwrite, or edit the files directly.")
        throw InitError.refusingToOverwrite(lines.joined(separator: "\n"))
    }

    private func step1_createDirectory() throws {
        print("[1/5] Creating \(Config.directory)")
        try FileManager.default.createDirectory(
            atPath: Config.directory,
            withIntermediateDirectories: true
        )
        print("      → ok")
    }

    private func step2_accessibility() {
        print("[2/5] Accessibility permission")
        if Permissions.checkAccessibility(prompt: false) {
            print("      → already granted")
            return
        }
        // Triggering with prompt=true pops the system dialog.
        _ = Permissions.checkAccessibility(prompt: true)
        print("      → system dialog shown. Approve in Privacy & Security > Accessibility.")
        print("      Press Enter when done.", terminator: " ")
        _ = readLine()
        if Permissions.checkAccessibility(prompt: false) {
            print("      → granted")
        } else {
            print("      ⚠ still not granted. send / harvest will fail until this is fixed.")
        }
    }

    private func step3_fullDiskAccess() {
        print("[3/5] Full Disk Access")
        if Permissions.checkFullDiskAccess() {
            print("      → already granted")
            return
        }
        print("      → denied. Opening System Settings > Privacy > Full Disk Access...")
        _ = Permissions.openFullDiskAccessSettings()
        print("      Drag your terminal app into the list, then press Enter.", terminator: " ")
        _ = readLine()
        if Permissions.checkFullDiskAccess() {
            print("      → granted")
        } else {
            print("      ⚠ still missing. Database reads will fail until this is fixed.")
        }
    }

    private func step4_recoverUserId() throws -> Int {
        print("[4/5] Recovering userId (budget: \(Int(maxSeconds))s, all cores)")

        // Env var wins — operator has explicitly pinned it.
        if let envStr = ProcessInfo.processInfo.environment["KAKAOCLI_USER_ID"],
           let envId = Int(envStr), envId > 0 {
            print("      → \(envId) (from KAKAOCLI_USER_ID env var)")
            return envId
        }

        guard let hash = DeviceInfo.activeAccountHash() else {
            throw InitError.noAccountHash
        }
        let start = Date()
        let opts = UserIdRecovery.Options(maxSeconds: maxSeconds)
        guard let id = UserIdRecovery.recover(targetHash: hash, options: opts) else {
            throw InitError.recoveryTimedOut(maxSeconds)
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "      → %d (recovered in %.1fs)", id, elapsed))
        return id
    }

    private func step5_primaryChat(userId: Int) throws -> PolicyEntry? {
        if let id = primaryChatId {
            print("[5/5] Resolving primary chatId \(id)")
            let reader = try openReader(userId: userId)
            defer { reader.close() }
            guard let chat = try reader.chat(byChatId: id) else {
                throw InitError.chatNotFound(id)
            }
            let directUserId = try lookupDirectUserId(reader: reader, chatId: id)
            print("      → \(chat.displayName)")
            return PolicyEntry(
                chatId: id,
                expectedName: chat.displayName,
                expectedUserId: directUserId,
                purpose: chat.type == .direct ? "primary_account_1on1" : "primary_chat"
            )
        }
        if nonInteractive {
            print("[5/5] Primary chat selection — skipped (--non-interactive)")
            return nil
        }
        print("[5/5] Select primary 1:1 chat")
        return try interactivePrimarySelection(userId: userId)
    }

    // MARK: - Helpers

    private func interactivePrimarySelection(userId: Int) throws -> PolicyEntry? {
        let reader = try openReader(userId: userId)
        defer { reader.close() }
        let directChats = try reader.chats(limit: 50)
            .filter { $0.type == .direct }
            .prefix(8)
        if directChats.isEmpty {
            print("      no recent 1:1 chats found — skipping. You can edit policy.json later.")
            return nil
        }
        for (i, c) in directChats.enumerated() {
            let ago = c.lastMessageAt.map(Self.humanRelative) ?? "never"
            print("      [\(i+1)] \(c.displayName) (chatId=\(c.id), last \(ago))")
        }
        let skipIndex = directChats.count + 1
        print("      [\(skipIndex)] skip")
        print("      Select [1-\(skipIndex)]:", terminator: " ")
        guard let line = readLine(),
              let n = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...skipIndex).contains(n) else {
            print("      invalid selection — skipping")
            return nil
        }
        if n == skipIndex { return nil }
        let chosen = directChats[directChats.index(directChats.startIndex, offsetBy: n - 1)]
        let directUserId = try lookupDirectUserId(reader: reader, chatId: chosen.id)
        print("      → \(chosen.displayName)")
        return PolicyEntry(
            chatId: chosen.id,
            expectedName: chosen.displayName,
            expectedUserId: directUserId,
            purpose: "primary_account_1on1"
        )
    }

    private func lookupDirectUserId(reader: DatabaseReader, chatId: Int64) throws -> Int64? {
        let rows = try reader.rawQuery(
            "SELECT directChatMemberUserId FROM NTChatRoom WHERE chatId = \(chatId) LIMIT 1"
        )
        return rows.first?.first as? Int64
    }

    private func openReader(userId: Int) throws -> DatabaseReader {
        let uuid = try DeviceInfo.platformUUID()
        let dbName = KeyDerivation.databaseName(userId: userId, uuid: uuid)
        let candidates = [
            "\(DeviceInfo.containerPath)/\(dbName)",
            "\(DeviceInfo.containerPath)/\(dbName).db",
        ]
        let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
            ?? DeviceInfo.discoverDatabaseFile()
        guard let path else {
            throw InitError.databaseNotFound(DeviceInfo.containerPath)
        }
        let key = KeyDerivation.secureKey(userId: userId, uuid: uuid)
        let reader = DatabaseReader(databasePath: path)
        try reader.open(key: key)
        return reader
    }

    private func writeConfig(userId: Int) throws {
        let cfg = Config(userId: userId)
        try cfg.save()
        print()
        print("Wrote \(Config.path)")
    }

    private func writePolicy(primary: PolicyEntry?) throws {
        let policy = Policy(
            allowlist: primary.map { [$0] } ?? [],
            strictMode: false,
            denyByDefault: true,
            primaryChatId: primary?.chatId
        )
        try policy.save()
        let summary = "(strictMode: false, \(policy.allowlist.count) entries)"
        print("Wrote \(Policy.path) \(summary)")
    }

    private static func humanRelative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

enum InitError: Error, CustomStringConvertible {
    case refusingToOverwrite(String)
    case noAccountHash
    case recoveryTimedOut(Double)
    case chatNotFound(Int64)
    case databaseNotFound(String)

    var description: String {
        switch self {
        case .refusingToOverwrite(let detail):
            return detail
        case .noAccountHash:
            return "No DESIGNATEDFRIENDSREVISION hash found in plist. Has KakaoTalk been launched and logged in on this Mac?"
        case .recoveryTimedOut(let s):
            return "userId brute-force exhausted its \(Int(s))s budget. Try --max-seconds <larger>, or set KAKAOCLI_USER_ID manually if you know it."
        case .chatNotFound(let id):
            return "chatId \(id) not found in the database."
        case .databaseNotFound(let path):
            return "Could not find a KakaoTalk database under \(path). Has KakaoTalk been launched and logged in on this Mac?"
        }
    }
}
