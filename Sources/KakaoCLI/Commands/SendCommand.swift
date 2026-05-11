import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message via UI automation",
        discussion: """
            Primary form is chatId-first and runs through the send-policy verifier:
              kakaocli send <chatId> <message>

            Convenience modes (single positional message argument):
              kakaocli send --main <message>           # policy.primaryChatId (verifier on)
              kakaocli send --me <message>             # self-chat (verifier exempt)
              kakaocli send --name <name> <message>    # legacy substring match (no verifier)

            Pass --unsafe-no-verify on the chatId form to bypass the verifier.
            """
    )

    @Argument(
        help: ArgumentHelp(
            "Target chatId (numeric). Omit when --name, --me, or --main is set.",
            valueName: "chatId"
        )
    )
    var firstPositional: String?

    @Argument(
        help: ArgumentHelp(
            "Message text.",
            valueName: "message"
        )
    )
    var secondPositional: String?

    @Option(name: .long, help: "Send by chat name (substring match) — legacy, not verifier-protected.")
    var name: String?

    @Flag(name: .customLong("me"), help: "Send to self-chat (나와의 채팅).")
    var selfChat = false

    @Flag(name: .customLong("main"), help: "Send to the primary chat from policy.primaryChatId.")
    var mainAccount = false

    @Flag(name: .long, help: "Bypass the send-policy verifier on the chatId path.")
    var unsafeNoVerify = false

    @Flag(name: .long, help: "Preview without sending.")
    var dryRun = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    private enum Target {
        case chatId(Int64)
        case name(String)
        case selfChat
    }

    func validate() throws {
        let flagCount = (selfChat ? 1 : 0) + (mainAccount ? 1 : 0) + (name != nil ? 1 : 0)
        if flagCount > 1 {
            throw ValidationError("--me, --main, and --name are mutually exclusive.")
        }
    }

    func run() throws {
        let (target, messageText) = try resolveInput()

        if dryRun {
            print("DRY RUN: would send to \(describe(target)): \(messageText)")
            return
        }

        switch target {
        case .selfChat:
            // No DB, no verifier — self-chat is found via the badge AX image,
            // unambiguous by construction.
            let automator = KakaoAutomator()
            try automator.sendMessage(to: "_", message: messageText, selfChat: true)
            print("Sent to self-chat.")

        case .name(let chatName):
            // Legacy substring match. No chatId in scope, so the verifier
            // doesn't apply; the chat-window header cross-check still runs
            // inside KakaoAutomator as defense in depth.
            let automator = KakaoAutomator()
            try automator.sendMessage(to: chatName, message: messageText, selfChat: false)
            print("Sent to '\(chatName)' (name-based, verifier not applicable).")

        case .chatId(let id):
            // chatId path: DB lookup → verifier → automator, via ChatIdSender.
            let reader = try openDatabase(dbPath: db, key: key)
            defer { reader.close() }
            let automator = KakaoAutomator()
            let chat = try ChatIdSender.send(
                chatId: id,
                message: messageText,
                db: reader,
                automator: automator,
                bypass: unsafeNoVerify
            )
            let label = chat.type == .selfChat ? "self-chat" : chat.displayName
            print("Sent to \(label) (chatId=\(id)).")
        }
    }

    /// Determine `Target` and the message text from positionals + flags.
    /// With no flag set, the positionals are `<chatId> <message>`. With
    /// --name / --me / --main, only `<message>` is expected (in the first
    /// positional slot).
    private func resolveInput() throws -> (Target, String) {
        let flagCount = (selfChat ? 1 : 0) + (mainAccount ? 1 : 0) + (name != nil ? 1 : 0)

        if flagCount == 0 {
            guard let cidStr = firstPositional, let msg = secondPositional else {
                throw ValidationError(
                    "Usage: kakaocli send <chatId> <message>, or use --name / --me / --main with a single message argument."
                )
            }
            guard let cid = Int64(cidStr) else {
                throw ValidationError(
                    "First positional must be a numeric chatId — got '\(cidStr)'. Use --name for substring matching: `kakaocli send --name \"\(cidStr)\" \"\(msg)\"`."
                )
            }
            return (.chatId(cid), msg)
        }

        // Flag is set: exactly one positional (the message).
        guard let msg = firstPositional, secondPositional == nil else {
            throw ValidationError(
                "Pass exactly one positional message when using --name / --me / --main."
            )
        }

        if selfChat { return (.selfChat, msg) }
        if mainAccount { return (try resolveMainTarget(), msg) }
        if let n = name { return (.name(n), msg) }
        fatalError("unreachable — validate() ensures one of the flags is set")
    }

    /// Resolve `--main` to a Target. Prefer policy.primaryChatId so the
    /// verifier protects the path; fall back to the legacy
    /// `KAKAOCLI_MAIN_CHAT_NAME` env var with a deprecation warning so
    /// existing cron / scripts don't snap.
    private func resolveMainTarget() throws -> Target {
        if let cid = (try? Policy.load())?.primaryChatId {
            return .chatId(cid)
        }
        if let envName = ProcessInfo.processInfo.environment["KAKAOCLI_MAIN_CHAT_NAME"],
           !envName.isEmpty {
            fputs(
                "deprecation: --main is using KAKAOCLI_MAIN_CHAT_NAME='\(envName)' (no verifier). Run `kakaocli init` to migrate to policy.primaryChatId.\n",
                stderr
            )
            return .name(envName)
        }
        throw ValidationError(
            "--main needs policy.primaryChatId (run `kakaocli init`) or KAKAOCLI_MAIN_CHAT_NAME env var."
        )
    }

    private func describe(_ target: Target) -> String {
        switch target {
        case .selfChat: return "self-chat"
        case .name(let n): return "'\(n)' (name)"
        case .chatId(let id): return "chatId=\(id)"
        }
    }
}
