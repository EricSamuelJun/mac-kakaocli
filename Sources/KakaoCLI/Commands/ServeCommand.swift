import ArgumentParser
import Darwin
import Dispatch
import Foundation
import KakaoCore

struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run an HTTP server exposing the Iris-compatible POST /reply interface"
    )

    @Option(name: .long, help: "Bind host (default: KAKAOCLI_SERVE_HOST env, then 127.0.0.1). Use 0.0.0.0 to accept Tailscale traffic.")
    var host: String?

    @Option(name: .long, help: "Bind port (default: KAKAOCLI_SERVE_PORT env, then 8080)")
    var port: Int?

    @Option(name: .long, help: "Log file path. Default: ~/.kakaocli/serve.log. Pass '-' for stdout.")
    var log: String?

    @Option(name: .long, help: "Path to database file (default: auto-discover)")
    var db: String?

    @Option(name: .long, help: "Database encryption key (default: derive from device + userId)")
    var key: String?

    func run() throws {
        let env = ProcessInfo.processInfo.environment
        let resolvedHost = host ?? env["KAKAOCLI_SERVE_HOST"] ?? "127.0.0.1"
        let resolvedPort = port ?? Int(env["KAKAOCLI_SERVE_PORT"] ?? "") ?? 8080
        let resolvedLog = log ?? defaultLogPath()

        guard resolvedPort > 0 && resolvedPort < 65536 else {
            throw ValidationError("Invalid port: \(resolvedPort)")
        }

        let logger = try ServerLogger(path: resolvedLog)
        let reader = try openDatabase(dbPath: db, key: key)
        let sender = LocalAXSender(automator: KakaoAutomator(), db: reader)
        let server = ReplyServer(host: resolvedHost, port: UInt16(resolvedPort), sender: sender, logger: logger)

        do {
            try server.start()
        } catch {
            logger.error("startup failed", ["error": "\(error)"])
            throw error
        }

        let banner = "kakaocli serve listening on \(resolvedHost):\(resolvedPort)  •  logs: \(resolvedLog)"
        print(banner)
        logger.info("startup", ["host": resolvedHost, "port": resolvedPort, "log": resolvedLog])

        installShutdownHandlers(server: server, reader: reader, logger: logger)

        // Block forever; signal handlers call exit().
        dispatchMain()
    }

    private func defaultLogPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.kakaocli/serve.log"
    }

    private func installShutdownHandlers(server: ReplyServer, reader: DatabaseReader, logger: ServerLogger) {
        let shutdown: @Sendable (String) -> Void = { signalName in
            print("\nShutting down (\(signalName))...")
            logger.info("shutdown", ["signal": signalName])
            server.stop()
            reader.close()
            // Give the logger queue a moment to flush.
            Thread.sleep(forTimeInterval: 0.2)
            // Disambiguate from ParsableCommand.exit(withError:), which shadows the global symbol here.
            Darwin.exit(0)
        }

        for sig in [SIGINT, SIGTERM] as [Int32] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            let name = sig == SIGINT ? "SIGINT" : "SIGTERM"
            source.setEventHandler { shutdown(name) }
            source.resume()
            // Keep source alive: store on a static so ARC doesn't drop it.
            ServeCommand.activeSources.append(source)
        }
    }

    /// Hold strong refs to signal sources so they survive past `run()`'s frame.
    /// `nonisolated(unsafe)` is fine here: the array is only mutated once, on the main
    /// thread inside `installShutdownHandlers`, before any concurrent activity starts.
    nonisolated(unsafe) private static var activeSources: [DispatchSourceSignal] = []
}
