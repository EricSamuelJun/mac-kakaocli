import AppKit
import ApplicationServices
import Foundation

/// Represents the observed state of KakaoTalk.
public enum KakaoAppState: String, Sendable {
    case notRunning
    case launching
    case loginScreen
    case loggedIn
    case updateRequired
    case unknown
}

/// Which detection signal located the running KakaoTalk process.
/// Surfaced so callers (and `kakaocli doctor`) can flag the cross-session
/// case where pgrep sees the app but NSRunningApplication doesn't.
public enum DetectionSource: String, Sendable {
    /// `NSRunningApplication.runningApplications(withBundleIdentifier:)`.
    /// In-process Cocoa lookup; only sees apps in the caller's session.
    case nsRunningApp
    /// `pgrep -x KakaoTalk`. Kernel process table; session-independent.
    case pgrep
}

/// Resolved KakaoTalk process — pid plus which signal located it.
public struct RunningProcess: Sendable {
    public let pid: pid_t
    public let source: DetectionSource
}

/// Manages KakaoTalk.app lifecycle: launch, state detection, readiness.
public enum AppLifecycle {

    public static let bundleId = KakaoAutomator.bundleId
    public static let appPath = "/Applications/KakaoTalk.app"

    // MARK: - Process Detection (multi-source cascade)

    /// Locate a running KakaoTalk process, trying each detection source in
    /// priority order. Any positive signal wins; we only conclude
    /// "not running" when every source comes back empty.
    ///
    /// Order:
    /// 1. `NSRunningApplication` — cheap, in-process. Correct for the normal
    ///    "both KakaoTalk and the caller in the same Aqua session" case.
    /// 2. `pgrep -x KakaoTalk` — subprocess, but session-independent. Catches
    ///    the case where the caller is in a different launchd session (no
    ///    Aqua pin on the LaunchAgent, SSH shell, etc.) — NSRunningApp
    ///    silently returns an empty array there, which used to be diagnosed
    ///    as "KakaoTalk not running" and triggered a useless re-launch.
    public static func findProcess() -> RunningProcess? {
        cascadeWithSources(
            nsRunningPid: queryNSRunningApp(),
            pgrepPid: queryPgrep()
        )
    }

    /// Pure cascade decision, factored out for unit testing. Public callers
    /// should use `findProcess()`; this signature exists so tests can feed
    /// synthetic signals without hitting real IO.
    internal static func cascadeWithSources(
        nsRunningPid: pid_t?,
        pgrepPid: pid_t?
    ) -> RunningProcess? {
        if let pid = nsRunningPid {
            return RunningProcess(pid: pid, source: .nsRunningApp)
        }
        if let pid = pgrepPid {
            return RunningProcess(pid: pid, source: .pgrep)
        }
        return nil
    }

    private static func queryNSRunningApp() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?.processIdentifier
    }

    private static func queryPgrep() -> pid_t? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // `-x` enforces an exact process-name match. KakaoTalk's executable
        // is always `KakaoTalk` even when the app bundle is `카카오톡.app`.
        proc.arguments = ["-x", "KakaoTalk"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        // pgrep emits one PID per line; take the first.
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(trimmed)
    }

    // MARK: - State Detection

    public static func isRunning() -> Bool {
        findProcess() != nil
    }

    /// Detect the current state of KakaoTalk.
    /// Set `aggressive: true` to try showing the window if hidden (slower, has side effects).
    /// Use `aggressive: false` when polling during login to avoid interfering.
    public static func detectState(aggressive: Bool = true) -> KakaoAppState {
        guard let proc = findProcess() else {
            return .notRunning
        }

        let axApp = AXUIElementCreateApplication(proc.pid)
        var windows = AXHelpers.windows(axApp)

        // `NSRunningApplication.activate()` is only usable when we located
        // the process via NSRunningApp. If we found it via pgrep (i.e. it
        // lives in a different session) we lack the API surface anyway —
        // attempting to activate from the wrong session is a no-op and AX
        // calls will still fail. We let the AX path run and report
        // whatever it can; cross-session diagnosis is the caller's job.
        let nsApp: NSRunningApplication? = (proc.source == .nsRunningApp)
            ? NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
            : nil

        if windows.isEmpty && aggressive {
            // KakaoTalk hides its window when "closed" (still running in menu bar).
            // Activate it to make windows visible, then re-check.
            nsApp?.activate()
            Thread.sleep(forTimeInterval: 0.5)
            windows = AXHelpers.windows(axApp)
        }

        if windows.isEmpty && aggressive {
            // Still no windows — try to show the main window via status bar menu.
            showMainWindow(axApp)
            Thread.sleep(forTimeInterval: 1.0)
            windows = AXHelpers.windows(axApp)
        }

        // Check for real AXWindow elements first
        let realWindows = windows.filter { AXHelpers.role($0) == "AXWindow" }
        if !realWindows.isEmpty {
            // Prioritize Main Window for classification
            if let mainWindow = realWindows.first(where: { AXHelpers.identifier($0) == "Main Window" }) {
                return classifyWindow(mainWindow)
            }
            // Non-Main-Window windows are chat windows → we're logged in
            return .loggedIn
        }

        // No real windows — check status bar menu (works even when window is hidden)
        if windows.isEmpty || !realWindows.isEmpty == false {
            let menuState = checkStatusBarMenu()
            if menuState != .unknown {
                return menuState
            }
        }

        // App is running but we can't determine state
        if windows.isEmpty {
            return .launching
        }

        return .unknown
    }

    /// Classify a real AXWindow element as login screen or logged in.
    private static func classifyWindow(_ window: AXUIElement) -> KakaoAppState {
        let id = AXHelpers.identifier(window)
        if id == "Main Window" {
            let title = AXHelpers.title(window) ?? ""
            if title.lowercased().contains("log in") || title == "로그인" {
                return .loginScreen
            }
            if AXHelpers.findFirst(window, role: "AXImage", identifier: "Logo") != nil {
                return .loginScreen
            }
            if AXHelpers.chatListTable(window) != nil {
                return .loggedIn
            }
            return .loggedIn
        }
        // Check for update dialog
        if AXHelpers.findFirst(window, role: "AXButton", text: "update") != nil ||
           AXHelpers.findFirst(window, role: "AXButton", text: "업데이트") != nil {
            return .updateRequired
        }
        return .loginScreen
    }

    /// Check KakaoTalk's status bar menu to determine login state.
    /// "Log out" = logged in, "Log in" = not logged in.
    private static func checkStatusBarMenu() -> KakaoAppState {
        let script = """
        tell application "System Events"
            tell process "KakaoTalk"
                try
                    click menu bar item 1 of menu bar 2
                    delay 0.3
                    set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
                    key code 53
                    return menuItems as text
                on error
                    return "error"
                end try
            end tell
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.contains("Log out") || output.contains("로그아웃") {
                return .loggedIn
            }
            if output.contains("Log in") || output.contains("로그인") {
                return .loginScreen
            }
        } catch {}
        return .unknown
    }

    // MARK: - Launch

    public static func launch() throws {
        guard !isRunning() else { return }

        let appURL = URL(fileURLWithPath: appPath)
        guard FileManager.default.fileExists(atPath: appPath) else {
            throw KakaoError.kakaoTalkNotInstalled
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var launchError: (any Error)?

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            launchError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let error = launchError {
            throw LifecycleError.launchFailed(error.localizedDescription)
        }
    }

    // MARK: - Wait Utilities

    public static func waitForAnyState(
        _ targets: Set<KakaoAppState>,
        timeout: TimeInterval = 30.0,
        pollInterval: TimeInterval = 0.5
    ) -> KakaoAppState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Use non-aggressive detection to avoid interfering with transitions
            let current = detectState(aggressive: false)
            if targets.contains(current) { return current }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return detectState(aggressive: false)
    }

    // MARK: - Ensure Ready

    /// Ensure KakaoTalk is running, logged in, and has a visible window with the chat list.
    /// If not running, launches it. If on login screen and credentials are available,
    /// attempts auto-login.
    public static func ensureReady(credentials: CredentialStore? = nil) throws {
        let state = detectState()

        switch state {
        case .loggedIn:
            // Even though we're logged in, the window may not be visible.
            // Ensure the window is showing and has a chat list.
            try ensureWindowVisible()
            return

        case .notRunning:
            fputs("Launching KakaoTalk...\n", stderr)
            try launch()
            let afterLaunch = waitForAnyState([.loggedIn, .loginScreen, .updateRequired], timeout: 15.0)
            if afterLaunch == .loggedIn { return }
            if afterLaunch == .updateRequired { throw LifecycleError.updateRequired }
            if afterLaunch == .loginScreen {
                try attemptLogin(credentials: credentials)
                return
            }
            throw LifecycleError.launchTimeout

        case .launching:
            let afterWait = waitForAnyState([.loggedIn, .loginScreen, .updateRequired], timeout: 15.0)
            if afterWait == .loggedIn { return }
            if afterWait == .loginScreen {
                try attemptLogin(credentials: credentials)
                return
            }
            throw LifecycleError.launchTimeout

        case .loginScreen:
            try attemptLogin(credentials: credentials)

        case .updateRequired:
            throw LifecycleError.updateRequired

        case .unknown:
            throw LifecycleError.unknownState
        }
    }

    // MARK: - Private

    /// Ensure KakaoTalk's main window is visible with the chat list accessible.
    /// KakaoTalk sometimes hides its window even when logged in.
    private static func ensureWindowVisible() throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Check if we already have a real AXWindow with a chat list
        let windows = AXHelpers.windows(axApp)
        let hasRealMainWindow = windows.contains {
            AXHelpers.role($0) == "AXWindow" && AXHelpers.identifier($0) == "Main Window"
        }
        if hasRealMainWindow { return }

        // Window not visible — try to show it
        fputs("Opening KakaoTalk window...\n", stderr)
        showMainWindow(axApp)
        Thread.sleep(forTimeInterval: 1.5)

        // Poll for the real window to appear (up to 10s)
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            let currentWindows = AXHelpers.windows(axApp)
            if currentWindows.contains(where: {
                AXHelpers.role($0) == "AXWindow" && AXHelpers.identifier($0) == "Main Window"
            }) {
                return
            }
            // Also try activate
            app.activate()
            Thread.sleep(forTimeInterval: 1.0)
        }

        // If we still can't get a real AXWindow, the AX hierarchy may just be non-standard.
        // Proceed anyway — the send command will use whatever elements are available.
        fputs("Warning: Could not get a standard AXWindow. Proceeding with non-standard AX hierarchy.\n", stderr)
    }

    private static func attemptLogin(credentials: CredentialStore?) throws {
        guard let creds = credentials, let email = creds.email, let password = creds.password else {
            throw LifecycleError.loginRequired
        }
        try LoginAutomator.login(email: email, password: password)
    }

    /// Try to show KakaoTalk's main window when running with no visible windows.
    /// Uses AppleScript to click "Open KakaoTalk" in the status bar menu,
    /// which is the only reliable way since the AX hierarchy is non-standard.
    private static func showMainWindow(_ axApp: AXUIElement) {
        let script = """
        tell application "System Events"
            tell process "KakaoTalk"
                set frontmost to true
                delay 0.3
                try
                    click menu bar item 1 of menu bar 2
                    delay 0.3
                    click menu item "Open KakaoTalk" of menu 1 of menu bar item 1 of menu bar 2
                on error
                    try
                        click menu item "카카오톡 열기" of menu 1 of menu bar item 1 of menu bar 2
                    end try
                end try
            end tell
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// Errors specific to app lifecycle management.
public enum LifecycleError: Error, CustomStringConvertible {
    case launchFailed(String)
    case launchTimeout
    case loginRequired
    case loginFailed(String)
    case otpRequired
    case updateRequired
    case wrongPassword
    case networkError
    case unknownState

    public var description: String {
        switch self {
        case .launchFailed(let msg): return "Failed to launch KakaoTalk: \(msg)"
        case .launchTimeout: return "KakaoTalk launched but did not become ready within timeout"
        case .loginRequired: return "KakaoTalk is showing the login screen but no credentials are stored. Run: kakaocli login"
        case .loginFailed(let msg): return "Login failed: \(msg)"
        case .otpRequired: return "KakaoTalk is requesting a 2FA verification code. Complete login manually."
        case .updateRequired: return "KakaoTalk requires an update. Please update the app manually."
        case .wrongPassword: return "Login failed: incorrect email or password"
        case .networkError: return "Login failed: network error (check your internet connection)"
        case .unknownState: return "KakaoTalk is in an unrecognized state"
        }
    }
}
