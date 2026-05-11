import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message via UI automation"
    )

    @Argument(help: "Chat name to send to (substring match). Ignored when --me or --main is set; pass '_' as placeholder.")
    var chat: String

    @Argument(help: "Message text to send")
    var message: String

    @Flag(name: [.customLong("me")], help: "Send to self-chat (나와의 채팅) regardless of chat argument")
    var selfChat = false

    @Flag(name: [.customLong("main")], help: "Send to primary account chat. Reads the chat name from KAKAOCLI_MAIN_CHAT_NAME env var.")
    var mainAccount = false

    @Flag(name: .long, help: "Show what would happen without actually sending")
    var dryRun = false

    func validate() throws {
        if selfChat && mainAccount {
            throw ValidationError("--me and --main are mutually exclusive")
        }
    }

    func run() throws {
        let resolvedChat: String
        let targetLabel: String

        if selfChat {
            resolvedChat = chat  // unused — KakaoAutomator finds the self-chat row via badge
            targetLabel = "self-chat"
        } else if mainAccount {
            guard let mainName = ProcessInfo.processInfo.environment["KAKAOCLI_MAIN_CHAT_NAME"],
                  !mainName.isEmpty else {
                throw ValidationError("--main requires the KAKAOCLI_MAIN_CHAT_NAME environment variable (e.g. export KAKAOCLI_MAIN_CHAT_NAME=\"전성욱\")")
            }
            resolvedChat = mainName
            targetLabel = "primary account (\(mainName))"
        } else {
            resolvedChat = chat
            targetLabel = chat
        }

        if dryRun {
            print("DRY RUN: Would send to '\(targetLabel)': \(message)")
            print("Steps: activate KakaoTalk → find chat '\(resolvedChat)' → type message → press Enter")
            return
        }

        let automator = KakaoAutomator()
        try automator.sendMessage(to: resolvedChat, message: message, selfChat: selfChat)
        print("Message sent to '\(targetLabel)'.")
    }
}
