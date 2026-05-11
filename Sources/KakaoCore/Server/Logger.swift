import Foundation

/// Minimal JSON-line logger for the reply server.
/// Each call emits a single line of UTF-8 JSON terminated by `\n`,
/// matching the shape downstream consumers (Spring Boot, fluentbit) expect.
/// Writes are serialised on an internal queue so concurrent connections
/// cannot interleave output.
public final class ServerLogger: @unchecked Sendable {
    // @unchecked: all writes go through a serial dispatch queue.

    public enum Output: Sendable {
        case file(URL)
        case stdout
    }

    private let output: Output
    private let queue = DispatchQueue(label: "com.kakaocli.serve.logger")
    private let timestampFormatter: ISO8601DateFormatter

    /// `path == "-"` writes to stdout; otherwise creates parent dirs and opens the file in append mode.
    public init(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        if path == "-" {
            output = .stdout
        } else {
            let url = URL(fileURLWithPath: expanded)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            output = .file(url)
        }
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func info(_ msg: String, _ extras: [String: Any] = [:]) {
        emit(level: "info", msg: msg, extras: extras)
    }

    public func error(_ msg: String, _ extras: [String: Any] = [:]) {
        emit(level: "error", msg: msg, extras: extras)
    }

    private func emit(level: String, msg: String, extras: [String: Any]) {
        var dict: [String: Any] = [
            "ts": timestampFormatter.string(from: Date()),
            "level": level,
            "msg": msg,
        ]
        for (key, value) in extras { dict[key] = value }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let line = Data((json + "\n").utf8)

        queue.async { [output] in
            switch output {
            case .stdout:
                FileHandle.standardOutput.write(line)
            case .file(let url):
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            }
        }
    }
}
