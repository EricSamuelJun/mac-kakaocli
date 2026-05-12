import ArgumentParser

@main
struct KakaoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kakaocli",
        abstract: "KakaoTalk CLI for AI agents",
        version: "0.12.2",
        subcommands: [
            AuthCommand.self,
            ChatsCommand.self,
            DoctorCommand.self,
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
