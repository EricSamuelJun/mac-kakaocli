import Foundation

/// Persistent operator configuration stored at `~/.kakaocli/config.json`.
///
/// Holds the resolved userId and any path overrides — anything that would
/// otherwise require an env var or auto-detection on every command. Written
/// by `kakaocli init` during first-time setup; consumed by `DeviceInfo`
/// resolvers and verification commands.
public struct Config: Codable, Sendable {
    public static let currentVersion = 1

    /// Schema version. Bumped when fields are removed or renamed; readers
    /// stay compatible with a `version` they don't recognise as long as the
    /// fields they care about still decode.
    public var version: Int

    /// KakaoTalk userId. nil means "not configured yet — fall through to
    /// env var, then to plist auto-detection".
    public var userId: Int?

    /// Override for `DeviceInfo.platformUUID()`. nil means auto-detect.
    public var deviceUUID: String?

    /// Override for the encrypted database path. nil means auto-discover
    /// inside the KakaoTalk container.
    public var databasePath: String?

    public init(
        version: Int = Config.currentVersion,
        userId: Int? = nil,
        deviceUUID: String? = nil,
        databasePath: String? = nil
    ) {
        self.version = version
        self.userId = userId
        self.deviceUUID = deviceUUID
        self.databasePath = databasePath
    }

    /// `~/.kakaocli`
    public static var directory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli")
            .path
    }

    /// `~/.kakaocli/config.json`
    public static var path: String {
        (directory as NSString).appendingPathComponent("config.json")
    }

    /// Load the config from disk. Returns nil if the file doesn't exist;
    /// throws if the file is present but unreadable or malformed so callers
    /// can distinguish "not initialised yet" from "config is corrupt".
    public static func load(from path: String = Config.path) throws -> Config? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Write the config atomically. Creates the parent directory if needed
    /// and tightens permissions to 0600 — single-user machine, but the file
    /// still has no reason to be world-readable.
    public func save(to path: String = Config.path) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }
}
