import Darwin
import Foundation

/// Minimal HTTP/1.1 server exposing a single `POST /reply` endpoint
/// compatible with the Iris bot's interface, plus `GET /health` for
/// liveness checks.
///
/// Direct BSD-socket implementation (no external deps): bind+listen on a
/// background queue, accept loop, then dispatch each connection onto a
/// serial work queue so the underlying KakaoTalk AX automation is never
/// driven by two requests at once.
public final class ReplyServer: @unchecked Sendable {
    // @unchecked: mutable state (`listenSocket`, `shuttingDown`) is touched only from
    // serial queues we own (acceptQueue / workQueue), so concurrent access is impossible
    // in practice. Swift's checker can't see that, hence the manual conformance.

    private let bindHost: String
    private let bindPort: UInt16
    private let sender: MessageSender
    private let logger: ServerLogger

    private var listenSocket: Int32 = -1
    private var shuttingDown = false

    private let acceptQueue = DispatchQueue(label: "com.kakaocli.serve.accept")
    private let workQueue = DispatchQueue(label: "com.kakaocli.serve.work")  // serial: serialises automation

    private let maxRequestBytes = 1_048_576  // 1 MiB

    public init(host: String, port: UInt16, sender: MessageSender, logger: ServerLogger) {
        self.bindHost = host
        self.bindPort = port
        self.sender = sender
        self.logger = logger
    }

    // MARK: - Lifecycle

    public func start() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ServerError.socketCreate(errno) }
        listenSocket = sock

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = bindPort.bigEndian

        if bindHost == "0.0.0.0" {
            addr.sin_addr.s_addr = in_addr_t(0).bigEndian
        } else {
            var parsed = in_addr()
            guard inet_pton(AF_INET, bindHost, &parsed) == 1 else {
                throw ServerError.invalidHost(bindHost)
            }
            addr.sin_addr = parsed
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ServerError.bindFailed(errno) }

        guard Darwin.listen(sock, 64) == 0 else {
            throw ServerError.listenFailed(errno)
        }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        shuttingDown = true
        if listenSocket >= 0 {
            Darwin.close(listenSocket)
            listenSocket = -1
        }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while !shuttingDown {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenSocket, sa, &clientLen)
                }
            }
            if clientSock < 0 {
                if !shuttingDown {
                    logger.error("accept failed", ["errno": errno])
                }
                continue
            }
            workQueue.async { [weak self] in
                self?.handleConnection(clientSock)
            }
        }
    }

    // MARK: - Request handling

    private func handleConnection(_ socket: Int32) {
        defer { Darwin.close(socket) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        var raw = Data()
        var bodyStart: Int? = nil
        var contentLength = 0

        // Read until end of headers.
        while bodyStart == nil {
            let n = Darwin.read(socket, &buffer, buffer.count)
            if n <= 0 { return }
            raw.append(buffer, count: n)

            if raw.count > maxRequestBytes {
                writeStatus(socket, status: 413, statusText: "Payload Too Large", body: "Payload too large")
                return
            }

            if let range = raw.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) {  // \r\n\r\n
                bodyStart = range.upperBound
                let headerBytes = raw.prefix(range.lowerBound)
                guard let headerStr = String(data: headerBytes, encoding: .utf8) else {
                    writeStatus(socket, status: 400, statusText: "Bad Request", body: "Invalid header encoding")
                    return
                }
                for line in headerStr.split(separator: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                        contentLength = Int(value) ?? 0
                    }
                }
            }
        }

        guard let start = bodyStart else { return }

        // Read remaining body if any.
        while raw.count - start < contentLength {
            let needed = contentLength - (raw.count - start)
            let chunk = min(buffer.count, needed)
            let n = Darwin.read(socket, &buffer, chunk)
            if n <= 0 { return }
            raw.append(buffer, count: n)
            if raw.count > maxRequestBytes {
                writeStatus(socket, status: 413, statusText: "Payload Too Large", body: "Payload too large")
                return
            }
        }

        // Parse request line.
        let headersText = String(data: raw.prefix(start - 4), encoding: .utf8) ?? ""
        guard let firstLine = headersText.split(separator: "\r\n").first else {
            writeStatus(socket, status: 400, statusText: "Bad Request", body: "Empty request")
            return
        }
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            writeStatus(socket, status: 400, statusText: "Bad Request", body: "Bad request line")
            return
        }
        let method = parts[0]
        let path = parts[1]

        let body = Data(raw.suffix(from: start))

        // Route.
        switch (method, path) {
        case ("POST", "/reply"):
            handleReply(socket: socket, body: body)
        case ("GET", "/health"):
            writeJSON(socket: socket, status: 200, body: ["status": "ok"])
        default:
            logger.info("unhandled", ["method": method, "path": path])
            writeStatus(socket, status: 404, statusText: "Not Found", body: "Not found")
        }
    }

    private func handleReply(socket: Int32, body: Data) {
        let message: IrisMessage
        do {
            message = try JSONDecoder().decode(IrisMessage.self, from: body)
        } catch {
            logger.error("invalid body", ["error": "\(error)"])
            let resp = IrisResponse(success: false, message: "Invalid JSON: \(error.localizedDescription)")
            writeJSON(socket: socket, status: 200, body: resp)
            return
        }

        logger.info("recv", ["room": message.room, "type": message.type, "bytes": message.data.utf8.count])

        do {
            let response = try sender.send(message)
            logger.info("sent", ["room": message.room, "ok": response.success])
            writeJSON(socket: socket, status: 200, body: response)
        } catch let sendError as SendError {
            logger.error("send error", ["room": message.room, "error": "\(sendError)"])
            let resp = IrisResponse(success: false, message: "\(sendError)")
            writeJSON(socket: socket, status: 200, body: resp)
        } catch {
            logger.error("internal error", ["error": "\(error)"])
            let resp = IrisResponse(success: false, message: "Internal error: \(error.localizedDescription)")
            writeJSON(socket: socket, status: 500, body: resp)
        }
    }

    // MARK: - Response helpers

    private func writeJSON<T: Encodable>(socket: Int32, status: Int, body: T) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(body),
              let text = String(data: data, encoding: .utf8) else {
            writeStatus(socket, status: 500, statusText: "Internal Server Error", body: "Encoding error")
            return
        }
        writeStatus(socket, status: status, statusText: statusText(status), contentType: "application/json", body: text)
    }

    private func writeStatus(_ socket: Int32, status: Int, statusText: String, contentType: String = "text/plain; charset=utf-8", body: String) {
        let payload = body
        let header = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(payload.utf8.count)\r
        Connection: close\r
        \r

        """
        var out = Data(header.utf8)
        out.append(Data(payload.utf8))
        out.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            _ = Darwin.write(socket, base, out.count)
        }
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

public enum ServerError: Error, CustomStringConvertible {
    case socketCreate(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case invalidHost(String)

    public var description: String {
        switch self {
        case .socketCreate(let e): return "socket() failed (errno=\(e): \(String(cString: strerror(e))))"
        case .bindFailed(let e): return "bind() failed (errno=\(e): \(String(cString: strerror(e))))"
        case .listenFailed(let e): return "listen() failed (errno=\(e): \(String(cString: strerror(e))))"
        case .invalidHost(let h): return "Invalid host (expected dotted-quad IPv4): \(h)"
        }
    }
}
