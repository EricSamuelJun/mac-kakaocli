import ArgumentParser
import Darwin
import Foundation
import KakaoCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Self-check the operator environment against known regression points",
        discussion: """
            Reports each prerequisite as [ok], [warn], or [fail]. Warnings are
            informational; only failures change the exit code to 1.

            Use --json for machine-readable output (snake_case keys), suitable
            for shell pipelines and orchestrator health checks.

            doctor never mutates state. It does not launch KakaoTalk, does not
            trigger permission prompts, does not write any files.
            """
    )

    @Flag(name: .long, help: "Emit a JSON report on stdout instead of the table.")
    var json = false

    func run() throws {
        let checks = runAllChecks()
        let summary = Summary(
            ok:   checks.filter { $0.status == .ok }.count,
            warn: checks.filter { $0.status == .warn }.count,
            fail: checks.filter { $0.status == .fail }.count
        )

        if json {
            try printJSON(checks: checks, summary: summary)
        } else {
            printTable(checks: checks, summary: summary)
        }

        if summary.fail > 0 {
            throw ExitCode.failure
        }
    }

    // MARK: - Check runner

    private func runAllChecks() -> [Check] {
        var checks: [Check] = []

        // Identity / config layer
        checks.append(checkUserIdSource())
        checks.append(checkConfigFile())
        checks.append(checkPolicyFile())

        // KakaoTalk app layer
        checks.append(checkKakaoTalkInstalled())
        checks.append(checkKakaoTalkRunning())
        checks.append(checkAppState())

        // macOS permissions layer
        checks.append(checkAccessibility())
        checks.append(checkFullDiskAccess())

        // Database layer
        checks.append(checkDatabaseFound())
        checks.append(checkDatabaseDecryption())

        // Operations layer
        checks.append(checkLaunchAgentPlist())
        checks.append(checkLaunchAgentLoaded())
        checks.append(checkLoginCredentials())

        return checks
    }

    // MARK: - Identity / config checks

    private func checkUserIdSource() -> Check {
        if let env = ProcessInfo.processInfo.environment["KAKAOCLI_USER_ID"],
           let id = Int(env), id > 0 {
            return Check(name: "userId source",
                         status: .ok,
                         detail: "env (KAKAOCLI_USER_ID = \(id))",
                         hint: nil)
        }
        if let cfg = (try? Config.load()) ?? nil, let id = cfg.userId, id > 0 {
            return Check(name: "userId source",
                         status: .ok,
                         detail: "config (~/.kakaocli/config.json userId = \(id))",
                         hint: nil)
        }
        if DeviceInfo.activeAccountHash() != nil {
            return Check(name: "userId source",
                         status: .warn,
                         detail: "plist (will brute-force every command, ~18-30s)",
                         hint: "run `kakaocli init` to persist userId to config.json")
        }
        return Check(name: "userId source",
                     status: .fail,
                     detail: "no userId source available",
                     hint: "run `kakaocli init` after launching KakaoTalk at least once")
    }

    private func checkConfigFile() -> Check {
        let path = Config.path
        guard FileManager.default.fileExists(atPath: path) else {
            return Check(name: "config.json",
                         status: .warn,
                         detail: "\(path) missing",
                         hint: "run `kakaocli init`")
        }
        do {
            _ = try Config.load()
            return Check(name: "config.json", status: .ok, detail: path, hint: nil)
        } catch {
            return Check(name: "config.json",
                         status: .fail,
                         detail: "\(path) present but unreadable: \(error)",
                         hint: "fix or delete the file; `kakaocli init --force` rescaffolds it")
        }
    }

    private func checkPolicyFile() -> Check {
        let path = Policy.path
        guard FileManager.default.fileExists(atPath: path) else {
            return Check(name: "policy.json",
                         status: .warn,
                         detail: "\(path) missing — send-policy verifier is inactive",
                         hint: "run `kakaocli init` (writes scaffold)")
        }
        do {
            guard let p = try Policy.load() else {
                return Check(name: "policy.json",
                             status: .warn,
                             detail: "\(path) decoded as nil",
                             hint: "`kakaocli init --force`")
            }
            let primary = p.primaryChatId.map(String.init) ?? "none"
            return Check(name: "policy.json",
                         status: .ok,
                         detail: "\(p.allowlist.count) entries, primary=\(primary), strictMode=\(p.strictMode), denyByDefault=\(p.denyByDefault)",
                         hint: nil)
        } catch {
            return Check(name: "policy.json",
                         status: .fail,
                         detail: "present but malformed: \(error). Treated as 'no policy' at runtime.",
                         hint: "fix manually or `kakaocli init --force` (re-scaffolds)")
        }
    }

    // MARK: - KakaoTalk app checks

    private func checkKakaoTalkInstalled() -> Check {
        let path = AppLifecycle.appPath
        guard FileManager.default.fileExists(atPath: path) else {
            return Check(name: "KakaoTalk installed",
                         status: .fail,
                         detail: "\(path) not found",
                         hint: "install from the App Store; on a Korean install, symlink `/Applications/카카오톡.app` to `KakaoTalk.app`")
        }
        return Check(name: "KakaoTalk installed", status: .ok, detail: path, hint: nil)
    }

    private func checkKakaoTalkRunning() -> Check {
        guard let proc = AppLifecycle.findProcess() else {
            return Check(name: "KakaoTalk running",
                         status: .warn,
                         detail: "not running (NSRunningApp and pgrep both negative)",
                         hint: "send/sync/harvest will auto-launch; otherwise: `open /Applications/KakaoTalk.app`")
        }
        switch proc.source {
        case .nsRunningApp:
            return Check(name: "KakaoTalk running",
                         status: .ok,
                         detail: "pid \(proc.pid) (NSRunningApplication)",
                         hint: nil)
        case .pgrep:
            // NSRunningApp empty but pgrep saw the process — almost certainly
            // a session-isolation symptom (LaunchAgent missing Aqua pin, SSH
            // shell, etc.). The cascade prevents a mis-classification as
            // notRunning, but AX automation will likely still fail because
            // WindowServer access is per-session.
            return Check(name: "KakaoTalk running",
                         status: .warn,
                         detail: "pid \(proc.pid) via pgrep (NSRunningApp empty — session isolation suspected)",
                         hint: "AX may still fail. Verify LaunchAgent `LimitLoadToSessionType=Aqua` and re-bootstrap. See §5.10 in the operator handoff.")
        }
    }

    private func checkAppState() -> Check {
        // Non-aggressive — we observe only, never mutate AX state from doctor.
        let state = AppLifecycle.detectState(aggressive: false)
        switch state {
        case .loggedIn:
            return Check(name: "App state", status: .ok, detail: "loggedIn", hint: nil)
        case .loginScreen:
            return Check(name: "App state",
                         status: .warn,
                         detail: "loginScreen",
                         hint: "auto-login will fire if credentials are stored; otherwise `kakaocli login --email ... --password ...`")
        case .notRunning:
            return Check(name: "App state",
                         status: .warn,
                         detail: "notRunning",
                         hint: "will auto-launch on send/sync/harvest")
        case .launching:
            return Check(name: "App state",
                         status: .warn,
                         detail: "launching (transient)",
                         hint: "rerun doctor in a few seconds")
        case .updateRequired:
            return Check(name: "App state",
                         status: .fail,
                         detail: "updateRequired",
                         hint: "update KakaoTalk via the App Store")
        case .unknown:
            return Check(name: "App state",
                         status: .warn,
                         detail: "unknown",
                         hint: "could not classify; try `kakaocli inspect --depth 4`")
        }
    }

    // MARK: - Permission checks

    private func checkAccessibility() -> Check {
        // prompt: false — doctor must never trigger system dialogs.
        if Permissions.checkAccessibility(prompt: false) {
            return Check(name: "Accessibility", status: .ok, detail: "granted", hint: nil)
        }
        return Check(name: "Accessibility",
                     status: .fail,
                     detail: "not trusted — send/harvest/inspect will fail",
                     hint: "System Settings > Privacy & Security > Accessibility — add your terminal app")
    }

    private func checkFullDiskAccess() -> Check {
        if Permissions.checkFullDiskAccess() {
            return Check(name: "Full Disk Access", status: .ok, detail: "granted", hint: nil)
        }
        return Check(name: "Full Disk Access",
                     status: .fail,
                     detail: "denied or container missing — DB reads will fail",
                     hint: "System Settings > Privacy & Security > Full Disk Access — add your terminal app")
    }

    // MARK: - Database checks

    private func checkDatabaseFound() -> Check {
        guard let path = DeviceInfo.discoverDatabaseFile() else {
            return Check(name: "Database found",
                         status: .fail,
                         detail: "no encrypted DB file in \(DeviceInfo.containerPath)",
                         hint: "has KakaoTalk ever been launched and logged in on this Mac?")
        }
        let basename = (path as NSString).lastPathComponent
        return Check(name: "Database found", status: .ok, detail: "\(basename.prefix(40))…", hint: nil)
    }

    private func checkDatabaseDecryption() -> Check {
        // Resolve userId / uuid the same way `auth` does, but never call DeviceInfo
        // brute-force here — that would be slow and indistinguishable from a hang
        // from the operator's perspective.
        let envUserId = ProcessInfo.processInfo.environment["KAKAOCLI_USER_ID"].flatMap { Int($0) }
        let cfgUserId = ((try? Config.load()) ?? nil)?.userId
        guard let userId = envUserId ?? cfgUserId else {
            return Check(name: "Database decryption",
                         status: .warn,
                         detail: "skipped — no userId in env or config (avoiding brute-force)",
                         hint: "run `kakaocli init`")
        }
        let uuid: String
        do {
            uuid = try DeviceInfo.platformUUID()
        } catch {
            return Check(name: "Database decryption",
                         status: .fail,
                         detail: "could not read IOPlatformUUID: \(error)",
                         hint: nil)
        }
        guard let dbPath = DeviceInfo.discoverDatabaseFile() else {
            return Check(name: "Database decryption",
                         status: .warn,
                         detail: "skipped — no DB file discovered",
                         hint: nil)
        }
        let key = KeyDerivation.secureKey(userId: userId, uuid: uuid)
        let reader = DatabaseReader(databasePath: dbPath)
        do {
            try reader.open(key: key)
            defer { reader.close() }
            let tables = try reader.schema()
            return Check(name: "Database decryption",
                         status: .ok,
                         detail: "ok (\(tables.count) tables)",
                         hint: nil)
        } catch {
            return Check(name: "Database decryption",
                         status: .fail,
                         detail: "open failed: \(error)",
                         hint: "key mismatch — verify userId/UUID via `kakaocli auth --verbose`")
        }
    }

    // MARK: - LaunchAgent checks

    private static let launchAgentLabel = "com.kakaocli.serve"

    private var launchAgentPlistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(Self.launchAgentLabel).plist"
    }

    private func checkLaunchAgentPlist() -> Check {
        let path = launchAgentPlistPath
        guard FileManager.default.fileExists(atPath: path) else {
            return Check(name: "LaunchAgent plist",
                         status: .warn,
                         detail: "\(path) not installed",
                         hint: "copy `deploy/launchd/com.kakaocli.serve.plist.template` if you want unattended `kakaocli serve`")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return Check(name: "LaunchAgent plist",
                         status: .fail,
                         detail: "\(path) present but unparseable",
                         hint: "run `plutil \(path)` to see the error")
        }
        guard (plist["LimitLoadToSessionType"] as? String) == "Aqua" else {
            return Check(name: "LaunchAgent plist",
                         status: .fail,
                         detail: "missing `LimitLoadToSessionType=Aqua` — /reply will time out with 'did not become ready'",
                         hint: "add `<key>LimitLoadToSessionType</key><string>Aqua</string>` and re-bootstrap")
        }
        return Check(name: "LaunchAgent plist",
                     status: .ok,
                     detail: "installed with Aqua pin",
                     hint: nil)
    }

    private func checkLaunchAgentLoaded() -> Check {
        // `launchctl list <label>` exit code 0 = loaded, non-zero = absent.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["list", Self.launchAgentLabel]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return Check(name: "LaunchAgent loaded",
                         status: .warn,
                         detail: "could not run launchctl: \(error)",
                         hint: nil)
        }
        if proc.terminationStatus == 0 {
            return Check(name: "LaunchAgent loaded", status: .ok, detail: "bootstrapped", hint: nil)
        }
        // Distinguish "plist not installed" from "installed but not bootstrapped"
        let plistExists = FileManager.default.fileExists(atPath: launchAgentPlistPath)
        if !plistExists {
            return Check(name: "LaunchAgent loaded",
                         status: .warn,
                         detail: "skipped — plist not installed",
                         hint: nil)
        }
        return Check(name: "LaunchAgent loaded",
                     status: .warn,
                     detail: "plist installed but not bootstrapped",
                     hint: "launchctl bootstrap gui/$(id -u) \(launchAgentPlistPath)")
    }

    // MARK: - Login credential check

    private func checkLoginCredentials() -> Check {
        let stored = keychainHasItem(service: "com.kakaocli.credentials", account: "kakaotalk-email") &&
                     keychainHasItem(service: "com.kakaocli.credentials", account: "kakaotalk-password")
        if stored {
            return Check(name: "Login credentials", status: .ok, detail: "stored in Keychain", hint: nil)
        }
        return Check(name: "Login credentials",
                     status: .warn,
                     detail: "missing — auto-login disabled",
                     hint: "`kakaocli login --email <addr> --password <pw>` (non-interactive)")
    }

    private func keychainHasItem(service: String, account: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-a", account]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Output

    private struct Check: Codable {
        let name: String
        let status: Status
        let detail: String
        let hint: String?

        enum Status: String, Codable {
            case ok
            case warn
            case fail
        }
    }

    private struct Summary: Codable {
        let ok: Int
        let warn: Int
        let fail: Int
    }

    private struct Report: Codable {
        let checks: [Check]
        let summary: Summary
    }

    private func printJSON(checks: [Check], summary: Summary) throws {
        let report = Report(checks: checks, summary: summary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(report)
        if let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }

    private func printTable(checks: [Check], summary: Summary) {
        let useColor = isatty(fileno(stdout)) != 0
        let nameWidth = max(20, (checks.map { $0.name.count }.max() ?? 0))

        for check in checks {
            let badge = badgeText(for: check.status, color: useColor)
            let name = check.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            print("\(badge) \(name)  \(check.detail)")
            if let hint = check.hint {
                let pad = String(repeating: " ", count: nameWidth + 8)  // align with detail column
                print("\(pad)→ \(hint)")
            }
        }

        let total = summary.ok + summary.warn + summary.fail
        print("")
        if summary.fail > 0 {
            print("\(summary.fail) failure(s), \(summary.warn) warning(s), \(summary.ok)/\(total) ok.")
        } else if summary.warn > 0 {
            print("\(summary.warn) warning(s), \(summary.ok)/\(total) ok.")
        } else {
            print("All \(total) checks passed.")
        }
    }

    /// Fixed-width status badge `[ok]  ` / `[warn]` / `[fail]`, ANSI-coloured on TTY.
    private func badgeText(for status: Check.Status, color: Bool) -> String {
        let raw: String
        let ansi: String
        switch status {
        case .ok:   raw = "[ok]  "; ansi = "32"   // green
        case .warn: raw = "[warn]"; ansi = "33"   // yellow
        case .fail: raw = "[fail]"; ansi = "31"   // red
        }
        return color ? "\u{001B}[\(ansi)m\(raw)\u{001B}[0m" : raw
    }
}
