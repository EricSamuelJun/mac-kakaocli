import ArgumentParser
import Foundation
import KakaoCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Verify database decryption with the current operator config"
    )

    @Flag(name: .long, help: "Show derived values (database name, key prefix) for debugging")
    var verbose = false

    @Option(name: .long, help: "Verification override — try this userId instead of the resolved one")
    var userId: Int?

    @Option(name: .long, help: "Verification override — use this device UUID instead of ioreg")
    var uuid: String?

    func run() throws {
        // 1. Device UUID
        let deviceUUID = try uuid ?? DeviceInfo.platformUUID()
        print("UUID: \(deviceUUID)")

        // 2. userId — DeviceInfo handles the resolution chain
        //    (env var → config.json → plist heuristics). Auth just verifies
        //    that *something* downstream produced a value; if nothing did,
        //    init is the prescribed remedy.
        let uid: Int
        do {
            uid = try userId ?? DeviceInfo.userId()
        } catch {
            print("User ID: not resolved")
            print()
            print("Run `kakaocli init` to recover and persist your userId,")
            print("or set KAKAOCLI_USER_ID for a one-off override.")
            throw ExitCode.failure
        }
        print("User ID: \(uid) (\(userIdSource()))")

        // 3. Verbose diagnostics
        if verbose {
            let dbName = KeyDerivation.databaseName(userId: uid, uuid: deviceUUID)
            let secureKey = KeyDerivation.secureKey(userId: uid, uuid: deviceUUID)
            print("Database name: \(dbName)")
            print("Secure key: \(secureKey.prefix(16))...")
        }

        // 4. Resolve database path
        let dbPath = try resolveDatabasePath(userId: uid, deviceUUID: deviceUUID)
        print("Database: \((dbPath as NSString).lastPathComponent)")

        // 5. Decrypt + list tables
        let key = KeyDerivation.secureKey(userId: uid, uuid: deviceUUID)
        let reader = DatabaseReader(databasePath: dbPath)
        do {
            try reader.open(key: key)
        } catch {
            reader.close()
            print()
            print("Failed to open database: \(error)")
            print("The key may not match this userId / UUID / database combination.")
            print("If KakaoTalk was re-installed or the account changed, run")
            print("`kakaocli init --force` to refresh your config.")
            throw ExitCode.failure
        }
        defer { reader.close() }

        let tables = try reader.schema()
        print()
        print("Database opened successfully.")
        print("Tables: \(tables.count)")
        for t in tables {
            print("  - \(t.name)")
        }
    }

    /// Identify where the resolved userId came from, for the diagnostic line.
    /// Probed lazily so we don't repeat DeviceInfo's resolution work.
    private func userIdSource() -> String {
        if userId != nil { return "override" }
        if ProcessInfo.processInfo.environment["KAKAOCLI_USER_ID"] != nil { return "env" }
        let cfgHasUserId: Bool = {
            do { return try Config.load()?.userId != nil } catch { return false }
        }()
        if cfgHasUserId { return "config" }
        return "plist"
    }

    private func resolveDatabasePath(userId: Int, deviceUUID: String) throws -> String {
        // Explicit override from config.json.
        let cfg = (try? Config.load()) ?? nil
        if let path = cfg?.databasePath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        // Derived path under the KakaoTalk container.
        let dbName = KeyDerivation.databaseName(userId: userId, uuid: deviceUUID)
        let candidates = [
            "\(DeviceInfo.containerPath)/\(dbName)",
            "\(DeviceInfo.containerPath)/\(dbName).db",
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        // Last resort: scan the container for any encrypted DB file. Useful
        // when the operator's userId is correct but the file naming drifted.
        if let scanned = DeviceInfo.discoverDatabaseFile() {
            return scanned
        }
        throw KakaoError.databaseNotFound("\(DeviceInfo.containerPath)/\(dbName)")
    }
}
