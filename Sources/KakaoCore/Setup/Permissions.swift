import ApplicationServices
import Foundation

/// macOS permission helpers used by `kakaocli init` to bootstrap a new
/// install. Lives in KakaoCore so non-CLI consumers can reuse the checks.
public enum Permissions {

    /// Whether the calling process is trusted for Accessibility. When
    /// `prompt: true` and trust is currently missing, the call also pops the
    /// system "Allow Terminal to control your computer" dialog — that
    /// behaviour is the only way to programmatically request the permission
    /// on macOS.
    public static func checkAccessibility(prompt: Bool = false) -> Bool {
        // kAXTrustedCheckOptionPrompt is imported as `Unmanaged<CFString>!`
        // because its C header lacks nullability annotations, and reading the
        // global to call `.takeUnretainedValue()` trips Swift 6 strict
        // concurrency ("reference to var ... is not concurrency-safe").
        // The CFString's value has been "AXTrustedCheckOptionPrompt" since
        // 10.9 — the literal sidesteps the import quirk without changing
        // behaviour.
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Whether the running process can list the KakaoTalk container — the
    /// best proxy for Full Disk Access without writing anywhere. Returns
    /// false either when FDA is missing or when KakaoTalk isn't installed;
    /// `kakaocli init` distinguishes the two cases by checking for the
    /// `.app` bundle separately before calling this.
    public static func checkFullDiskAccess() -> Bool {
        let path = DeviceInfo.containerPath
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Open System Settings on the Full Disk Access pane. There is no
    /// programmatic way to grant FDA — the operator has to drag their
    /// terminal app into the list themselves — but we can at least skip the
    /// "Settings > Privacy > scroll down" choreography for them.
    @discardableResult
    public static func openFullDiskAccessSettings() -> Bool {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
