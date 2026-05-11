import CSQLCipher
import Foundation

/// Reads KakaoTalk's encrypted SQLite database using SQLCipher.
public final class DatabaseReader: @unchecked Sendable {
    private var db: OpaquePointer?
    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    deinit {
        close()
    }

    /// Open the database. If a key is provided, attempts PRAGMA key (requires SQLCipher).
    /// Tries cipher compatibility modes 3 and 4 (for newer KakaoTalk versions).
    public func open(key: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw KakaoError.databaseNotFound(databasePath)
        }

        if let key {
            // Try compatibility mode 3 first (legacy), then 4 (newer versions)
            let compatModes = [3, 4]
            for compat in compatModes {
                // Close previous attempt if any
                if db != nil { sqlite3_close(db); db = nil }

                let result = sqlite3_open_v2(
                    databasePath, &db,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
                )
                guard result == SQLITE_OK else {
                    let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                    throw KakaoError.databaseOpenFailed(msg)
                }

                do {
                    try exec("PRAGMA cipher_default_compatibility = \(compat)")
                    try exec("PRAGMA KEY='\(key)'")
                    try exec("SELECT count(*) FROM sqlite_master")
                    return // success
                } catch {
                    continue
                }
            }
            throw KakaoError.databaseOpenFailed(
                "PRAGMA key failed with all cipher compatibility modes — " +
                "database is encrypted and key may be wrong, or SQLCipher may not be linked. " +
                "Install via: brew install sqlcipher"
            )
        } else {
            let result = sqlite3_open_v2(
                databasePath, &db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
            )
            guard result == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw KakaoError.databaseOpenFailed(msg)
            }
        }
    }

    /// Try opening the database with a key. Returns true if the key is valid.
    public func tryOpen(key: String) -> Bool {
        do {
            try open(key: key)
            return true
        } catch {
            close()
            return false
        }
    }

    public func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Queries

    /// List all chat rooms.
    public func chats(limit: Int = 50) throws -> [Chat] {
        let sql = """
            SELECT r.chatId, r.type, r.chatName, r.activeMembersCount,
                   r.lastLogId, r.lastUpdatedAt, r.countOfNewMessage,
                   u.displayName, u.friendNickName, u.nickName,
                   r.displayMemberIds
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            ORDER BY r.lastUpdatedAt DESC
            LIMIT ?
            """
        let rows = try query(sql, bind: [.int(limit)]) { row -> ChatRow in
            ChatRow(
                chatId: row.int64(0),
                rawType: row.int(1),
                chatName: row.string(2),
                activeMembersCount: row.int(3),
                lastLogId: row.optionalInt64(4),
                lastUpdatedAt: row.optionalKakaoDate(5),
                unreadCount: row.int(6),
                friendUserName: row.string(7) ?? row.string(8) ?? row.string(9),
                displayMemberIds: row.data(10)
            )
        }
        return rows.compactMap { try? toChat($0) }
    }

    /// Look up a single chat room by its chatId.
    /// Returns nil if no row matches. Resolves displayName the same way as
    /// `chats(limit:)` — NTChatRoom.chatName first, the direct-member user's
    /// names next, and for groups the displayMemberIds roster joined to NTUser.
    public func chat(byChatId chatId: Int64) throws -> Chat? {
        let sql = """
            SELECT r.chatId, r.type, r.chatName, r.activeMembersCount,
                   r.lastLogId, r.lastUpdatedAt, r.countOfNewMessage,
                   u.displayName, u.friendNickName, u.nickName,
                   r.displayMemberIds
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            WHERE r.chatId = ?
            LIMIT 1
            """
        let rows = try query(sql, bind: [.int64(chatId)]) { row -> ChatRow in
            ChatRow(
                chatId: row.int64(0),
                rawType: row.int(1),
                chatName: row.string(2),
                activeMembersCount: row.int(3),
                lastLogId: row.optionalInt64(4),
                lastUpdatedAt: row.optionalKakaoDate(5),
                unreadCount: row.int(6),
                friendUserName: row.string(7) ?? row.string(8) ?? row.string(9),
                displayMemberIds: row.data(10)
            )
        }
        return try rows.first.map { try toChat($0) }
    }

    // MARK: - Chat row helpers

    private struct ChatRow {
        let chatId: Int64
        let rawType: Int
        let chatName: String?
        let activeMembersCount: Int
        let lastLogId: Int64?
        let lastUpdatedAt: Date?
        let unreadCount: Int
        let friendUserName: String?
        let displayMemberIds: Data?
    }

    private func toChat(_ row: ChatRow) throws -> Chat {
        let chatType = Chat.ChatType.from(rawInt: row.rawType)
        let name = try resolveDisplayName(row: row, chatType: chatType)
        return Chat(
            id: row.chatId,
            type: chatType,
            displayName: name,
            memberCount: row.activeMembersCount,
            lastMessageId: row.lastLogId,
            lastMessageAt: row.lastUpdatedAt,
            unreadCount: row.unreadCount
        )
    }

    private func resolveDisplayName(row: ChatRow, chatType: Chat.ChatType) throws -> String {
        // 1. Custom-set chat name wins for any chat type.
        if let chatName = row.chatName, !chatName.isEmpty {
            return chatName
        }
        // 2. Direct-member name (works for 1:1 chats).
        if let userName = row.friendUserName, !userName.isEmpty {
            return userName
        }
        // 3. Group chats: synthesise from member roster.
        if chatType == .group, let blob = row.displayMemberIds, !blob.isEmpty {
            if let synthesised = try? synthesiseGroupName(from: blob), !synthesised.isEmpty {
                return synthesised
            }
        }
        return "(unknown)"
    }

    /// Read userIds out of a displayMemberIds blob, JOIN to NTUser, and
    /// join the resolved names with ", ". The local account's own userId is
    /// dropped from the listing so the resulting label is what a human reader
    /// would expect ("Alice, Bob" rather than "Self, Alice, Bob").
    private func synthesiseGroupName(from blob: Data) throws -> String {
        let memberIds = DisplayMemberIds.parse(blob)
        guard !memberIds.isEmpty else { return "" }

        let selfId = selfUserId
        let placeholders = Array(repeating: "?", count: memberIds.count).joined(separator: ",")
        let sql = """
            SELECT userId, COALESCE(NULLIF(displayName, ''),
                                    NULLIF(friendNickName, ''),
                                    NULLIF(nickName, '')) AS resolvedName
            FROM NTUser
            WHERE userId IN (\(placeholders)) AND linkId = 0
            """
        let bind = memberIds.map { SQLValue.int64($0) }
        let rows = try query(sql, bind: bind) { (row: Row) -> (Int64, String?) in
            (row.int64(0), row.string(1))
        }

        var nameByUserId: [Int64: String] = [:]
        for (uid, n) in rows {
            if let n = n, !n.isEmpty {
                nameByUserId[uid] = n
            }
        }

        // Preserve the bplist order; drop the local account.
        let ordered: [String] = memberIds.compactMap { uid in
            if uid == selfId { return nil }
            return nameByUserId[uid]
        }
        return ordered.joined(separator: ", ")
    }

    /// Best-effort lookup of the local KakaoTalk account's userId.
    /// Cached lazily; resolution failures degrade the group-name synthesiser
    /// to "include self" rather than crash.
    private lazy var selfUserId: Int64? = {
        return (try? DeviceInfo.userId()).map(Int64.init)
    }()

    /// Get messages for a chat, optionally filtered by time.
    public func messages(chatId: Int64? = nil, since: Date? = nil, limit: Int = 50) throws -> [Message] {
        var conditions: [String] = []
        var bindings: [SQLValue] = []

        if let chatId {
            conditions.append("m.chatId = ?")
            bindings.append(.int64(chatId))
        }
        if let since {
            // KakaoTalk stores timestamps as seconds since epoch
            conditions.append("m.sentAt >= ?")
            bindings.append(.int64(Int64(since.timeIntervalSince1970)))
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            \(where_)
            ORDER BY m.sentAt DESC
            LIMIT ?
            """
        bindings.append(.int(limit))

        let myUserId = try self.myUserId()
        return try query(sql, bind: bindings) { row in
            Message(
                id: row.int64(0),
                chatId: row.int64(1),
                senderId: row.int64(2),
                senderName: row.string(3),
                text: row.string(4),
                type: Message.MessageType(rawValue: row.int(5)),
                createdAt: row.kakaoDate(6),
                isFromMe: row.int64(2) == myUserId
            )
        }
    }

    /// Full-text search across messages.
    public func search(query: String, limit: Int = 20) throws -> [Message] {
        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            WHERE m.message LIKE ?
            ORDER BY m.sentAt DESC
            LIMIT ?
            """
        let myUserId = try self.myUserId()
        return try self.query(sql, bind: [.string("%\(query)%"), .int(limit)]) { row in
            Message(
                id: row.int64(0),
                chatId: row.int64(1),
                senderId: row.int64(2),
                senderName: row.string(3),
                text: row.string(4),
                type: Message.MessageType(rawValue: row.int(5)),
                createdAt: row.kakaoDate(6),
                isFromMe: row.int64(2) == myUserId
            )
        }
    }

    /// Get the logged-in user's ID from NTChatContext.
    public func myUserId() throws -> Int64 {
        let results = try query("SELECT userId FROM NTChatContext LIMIT 1", bind: []) { row in
            row.int64(0)
        }
        return results.first ?? 0
    }

    /// Get the maximum logId in the messages table (used by DatabaseWatcher).
    public func maxLogId() throws -> Int64 {
        let results = try query("SELECT MAX(logId) FROM NTChatMessage", bind: []) { row in
            row.optionalInt64(0)
        }
        return results.first.flatMap { $0 } ?? 0
    }

    /// Get messages with logId strictly greater than the given value.
    /// Returns SyncMessage structs suitable for JSON streaming.
    public func messagesSince(logId: Int64, myUserId: Int64) throws -> [SyncMessage] {
        let sql = """
            SELECT m.logId, m.chatId,
                   COALESCE(r.chatName, u.displayName, u.friendNickName, u.nickName) as chatName,
                   m.authorId,
                   COALESCE(u2.displayName, u2.friendNickName, u2.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTChatRoom r ON m.chatId = r.chatId
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            LEFT JOIN NTUser u2 ON m.authorId = u2.userId AND u2.linkId = 0
            WHERE m.logId > ?
            ORDER BY m.logId ASC
            LIMIT 100
            """
        let formatter = ISO8601DateFormatter()
        return try query(sql, bind: [.int64(logId)]) { row in
            SyncMessage(
                type: "message",
                logId: row.int64(0),
                chatId: row.int64(1),
                chatName: row.string(2),
                senderId: row.int64(3),
                senderName: row.string(4),
                text: row.string(5),
                messageType: row.int(6),
                timestamp: formatter.string(from: row.kakaoDate(7)),
                isFromMe: row.int64(3) == myUserId
            )
        }
    }

    /// Run an arbitrary read-only SQL query and return results as arrays of Any.
    public func rawQuery(_ sql: String) throws -> [[Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let colCount = sqlite3_column_count(stmt)
        var results: [[Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any] = []
            for i in 0..<colCount {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    row.append(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_NULL:
                    row.append("")
                default:
                    row.append("")
                }
            }
            results.append(row)
        }
        return results
    }

    /// Discover the actual database schema.
    public func schema() throws -> [(name: String, sql: String)] {
        try query(
            "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name",
            bind: []
        ) { row in
            (name: row.string(0) ?? "", sql: row.string(1) ?? "")
        }
    }

    // MARK: - SQLite Helpers

    enum SQLValue {
        case int(Int)
        case int64(Int64)
        case double(Double)
        case string(String)
        case null
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw KakaoError.sqlError(msg)
        }
    }

    private func query<T>(_ sql: String, bind: [SQLValue], transform: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int(stmt, idx, Int32(v))
            case .int64(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .string(let v): sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(transform(Row(stmt: stmt!)))
        }
        return results
    }

    struct Row {
        let stmt: OpaquePointer

        func int(_ col: Int32) -> Int {
            Int(sqlite3_column_int(stmt, col))
        }

        func int64(_ col: Int32) -> Int64 {
            sqlite3_column_int64(stmt, col)
        }

        func optionalInt64(_ col: Int32) -> Int64? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : int64(col)
        }

        func string(_ col: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: ptr)
        }

        func data(_ col: Int32) -> Data? {
            guard sqlite3_column_type(stmt, col) == SQLITE_BLOB,
                  let bytes = sqlite3_column_blob(stmt, col) else { return nil }
            let len = Int(sqlite3_column_bytes(stmt, col))
            return Data(bytes: bytes, count: len)
        }

        func bool(_ col: Int32) -> Bool {
            sqlite3_column_int(stmt, col) != 0
        }

        /// KakaoTalk stores timestamps as seconds since epoch.
        func kakaoDate(_ col: Int32) -> Date {
            let ts = sqlite3_column_int64(stmt, col)
            return Date(timeIntervalSince1970: Double(ts))
        }

        func optionalKakaoDate(_ col: Int32) -> Date? {
            let val = sqlite3_column_int64(stmt, col)
            return val == 0 ? nil : Date(timeIntervalSince1970: Double(val))
        }
    }
}

extension Chat.ChatType {
    /// Map KakaoTalk's integer chat type to our enum.
    /// Type 5 is the self-chat (나와의 채팅) — single-member room used for personal notes.
    static func from(rawInt: Int) -> Self {
        switch rawInt {
        case 0: return .direct
        case 1: return .group
        case 5: return .selfChat
        default: return .unknown
        }
    }
}
