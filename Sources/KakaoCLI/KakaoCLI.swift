import ArgumentParser

@main
struct KakaoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kakaocli",
        abstract: "KakaoTalk CLI for AI agents",
        version: "0.8.0",
        subcommands: [
            AuthCommand.self,
            ChatsCommand.self,
            HarvestCommand.self,
            InitCommand.self,
            InspectCommand.self,
            LoginCommand.self,
            MessagesCommand.self,
            PolicyCommand.self,
            QueryCommand.self,
            SchemaCommand.self,
            SearchCommand.self,
            SendCommand.self,
            ServeCommand.self,
            StatusCommand.self,
            SyncCommand.self,
        ]
    )
}
