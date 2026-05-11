import AppKit
import ApplicationServices
import Foundation
import Vision

/// Harvests KakaoTalk chat history by opening chats, scrolling to load messages,
/// and clicking "View Previous Chats" to fetch older history.
/// Also captures display names from the UI that may be missing from the database.
public enum ChatHarvester {

    public struct HarvestResult {
        public let chatId: Int64
        public let uiName: String
        public let messagesBefore: Int
        public let messagesAfter: Int
        public let skipped: Bool
        public let skipReason: String?
    }

    public struct Options {
        /// When non-nil, harvest only these chatIds (stable across UI reorders).
        /// When nil, fall back to top-N over `ORDER BY lastUpdatedAt DESC` (legacy).
        public var targetChatIds: [Int64]?
        public var maxChats: Int
        public var maxScrollsPerChat: Int
        public var maxPreviousClicks: Int
        public var namesOnly: Bool
        public var skipUnread: Bool
        public var scrollDelay: TimeInterval

        public init(
            targetChatIds: [Int64]? = nil,
            maxChats: Int = 0,
            maxScrollsPerChat: Int = 15,
            maxPreviousClicks: Int = 10,
            namesOnly: Bool = false,
            skipUnread: Bool = true,
            scrollDelay: TimeInterval = 1.5
        ) {
            self.targetChatIds = targetChatIds
            self.maxChats = maxChats
            self.maxScrollsPerChat = maxScrollsPerChat
            self.maxPreviousClicks = maxPreviousClicks
            self.namesOnly = namesOnly
            self.skipUnread = skipUnread
            self.scrollDelay = scrollDelay
        }
    }

    /// Harvest chat history and names by automating the KakaoTalk UI.
    ///
    /// For each chat: opens it, reads the UI name, scrolls up and clicks
    /// "View Previous Chats" to load older messages, then saves metadata.
    /// Skips chats with unread messages.
    public static func harvest(
        db: DatabaseReader,
        metadata: MetadataStore,
        options: Options,
        progress: @escaping (String) -> Void
    ) throws -> [HarvestResult] {
        // 1. Fetch the chat set we will operate on. With targetChatIds the
        //    selection is exact and stable; without it we fall back to the
        //    legacy "top N by lastUpdatedAt DESC" behaviour.
        let dbChats = try fetchTargets(db: db, options: options)
        progress("Selected \(dbChats.count) chats from database")

        // 2. Ensure KakaoTalk is running and logged in
        let state = AppLifecycle.detectState()
        if state == .notRunning || state == .loginScreen {
            try AppLifecycle.ensureReady(credentials: CredentialStore())
            Thread.sleep(forTimeInterval: 2.0)
        }

        // 3. Activate and get windows
        let bundleId = KakaoAutomator.bundleId
        try AXHelpers.activateApp(bundleId: bundleId)
        Thread.sleep(forTimeInterval: 0.5)
        let app = try AXHelpers.appElement(bundleId: bundleId)
        var windows = AXHelpers.windows(app)

        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }

        // 4. Close any open chat windows
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // 5. Switch to chats tab
        if let tab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
            _ = AXHelpers.performAction(tab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 6. Get chat list table (rows are re-read inside each iteration so a
        //    reorder mid-harvest doesn't desync our pointer).
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound("chat list table")
        }

        // 7. Process each chat — chatId-driven matching, no positional index.
        var results: [HarvestResult] = []

        for (i, dbChat) in dbChats.enumerated() {
            let chatId = dbChat[0] as! Int64
            let chatType = Int(dbChat[1] as! Int64)
            let memberCount = Int(dbChat[2] as! Int64)
            let unreadCount = dbChat[3] as! Int64
            let msgCount = Int(dbChat[5] as! Int64)

            // The canonical name comes from the DB (now includes group-name
            // synthesis from displayMemberIds). Fall back to "(unknown)" only
            // if the lookup itself failed.
            let dbName = (try? db.chat(byChatId: chatId))?.displayName ?? "(unknown)"

            // Skip unread (safety: opening could mark as read)
            if options.skipUnread && unreadCount > 0 {
                progress("[\(i+1)/\(dbChats.count)] Skipping \(dbName) [chatId=\(chatId)] (\(unreadCount) unread)")
                results.append(HarvestResult(
                    chatId: chatId, uiName: dbName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: true, skipReason: "\(unreadCount) unread"
                ))
                metadata.update(chatId: chatId, name: dbName,
                               memberCount: memberCount, chatType: chatType,
                               messageCount: msgCount)
                continue
            }

            // Look the chat up in the UI by name. findChatRow walks the current
            // children of the table each call, so a reorder since the previous
            // iteration is tolerated.
            guard let row = AXHelpers.findChatRow(table, chatName: dbName) else {
                progress("[\(i+1)/\(dbChats.count)] ⚠ UI row not found for chatId=\(chatId) (\(dbName))")
                results.append(HarvestResult(
                    chatId: chatId, uiName: dbName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: true, skipReason: "UI row not found"
                ))
                continue
            }
            let uiName = extractName(from: row)

            progress("[\(i+1)/\(dbChats.count)] \(dbName) [chatId=\(chatId)] (\(msgCount) msgs)...")

            metadata.update(chatId: chatId, name: uiName,
                           memberCount: memberCount, chatType: chatType)

            if options.namesOnly {
                metadata.update(chatId: chatId, name: uiName,
                               memberCount: memberCount, chatType: chatType,
                               messageCount: msgCount)
                results.append(HarvestResult(
                    chatId: chatId, uiName: uiName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: false, skipReason: nil
                ))
                continue
            }

            // Open the chat by double-clicking
            AXHelpers.doubleClickElement(row)
            Thread.sleep(forTimeInterval: 1.2)

            // Find the chat window
            windows = AXHelpers.windows(app)
            guard let chatWindow = windows.first(where: { AXHelpers.identifier($0) != "Main Window" }) else {
                progress("  Warning: chat window didn't open, skipping")
                results.append(HarvestResult(
                    chatId: chatId, uiName: uiName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: true, skipReason: "window didn't open"
                ))
                continue
            }

            // Defense-in-depth: the row we clicked may have been re-ordered
            // out from under us between findChatRow and doubleClickElement.
            // Confirm the opened window's title matches the row label before
            // doing anything inside the chat.
            let headerCheck = AXHelpers.verifyChatHeader(chatWindow, expected: uiName)
            if !headerCheck.matched {
                progress("  ⚠ Header mismatch: expected '\(uiName)', got '\(headerCheck.actual)'. Closing.")
                _ = AXHelpers.closeWindow(chatWindow)
                Thread.sleep(forTimeInterval: 0.3)
                results.append(HarvestResult(
                    chatId: chatId, uiName: uiName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: true,
                    skipReason: "header mismatch: expected '\(uiName)', got '\(headerCheck.actual)'"
                ))
                continue
            }

            // Load older messages: scroll to top, then click "View Previous Chats" repeatedly
            let windowTitle = AXHelpers.title(chatWindow) ?? uiName
            let messagesAfter = loadHistory(
                app: app,
                chatWindow: chatWindow,
                db: db, chatId: chatId,
                windowTitle: windowTitle,
                initialCount: msgCount,
                options: options,
                progress: progress
            )

            metadata.update(chatId: chatId, name: uiName,
                           memberCount: memberCount, chatType: chatType,
                           messageCount: messagesAfter)

            // Close the chat window
            _ = AXHelpers.closeWindow(chatWindow)
            Thread.sleep(forTimeInterval: 0.5)

            let loaded = messagesAfter - msgCount
            if loaded > 0 {
                progress("  +\(loaded) messages (total: \(messagesAfter))")
            } else {
                progress("  No new messages to load")
            }

            results.append(HarvestResult(
                chatId: chatId, uiName: uiName,
                messagesBefore: msgCount, messagesAfter: messagesAfter,
                skipped: false, skipReason: nil
            ))
        }

        return results
    }

    /// Build the DB-side chat set the harvest will iterate over.
    /// - `targetChatIds` non-nil: pick exactly those chatIds.
    /// - otherwise: ORDER BY lastUpdatedAt DESC, optionally capped by `maxChats`.
    private static func fetchTargets(db: DatabaseReader, options: Options) throws -> [[Any]] {
        let baseSelect = """
            SELECT r.chatId, r.type, r.activeMembersCount,
                   r.countOfNewMessage, r.lastUpdatedAt,
                   (SELECT COUNT(*) FROM NTChatMessage m WHERE m.chatId = r.chatId) as msgCount
            FROM NTChatRoom r
        """
        if let ids = options.targetChatIds, !ids.isEmpty {
            // chatIds are Int64 — safe to interpolate into the SQL.
            let csv = ids.map(String.init).joined(separator: ",")
            return try db.rawQuery("\(baseSelect) WHERE r.chatId IN (\(csv))")
        }
        var sql = "\(baseSelect) ORDER BY r.lastUpdatedAt DESC"
        if options.maxChats > 0 {
            sql += " LIMIT \(options.maxChats)"
        }
        return try db.rawQuery(sql)
    }

    // MARK: - Private Helpers

    /// Extract the display name from a chat list row.
    private static func extractName(from row: AXUIElement) -> String {
        AXHelpers.chatRowName(row) ?? "(unknown)"
    }

    /// Main history loading loop for a single chat.
    /// Scrolls to top, then uses OCR to find "View Previous Chats" and click it.
    private static func loadHistory(
        app: AXUIElement,
        chatWindow: AXUIElement,
        db: DatabaseReader,
        chatId: Int64,
        windowTitle: String,
        initialCount: Int,
        options: Options,
        progress: @escaping (String) -> Void
    ) -> Int {
        guard let winPos = AXHelpers.position(chatWindow),
              let winSize = AXHelpers.size(chatWindow) else {
            return initialCount
        }

        var currentCount = initialCount
        let scrollX = Int(winPos.x + winSize.width / 2)
        let scrollY = Int(winPos.y + winSize.height / 2)

        // Phase 1: Activate KakaoTalk and raise the chat window BEFORE scrolling.
        // This avoids scroll-position reset that can happen when peekaboo click --app
        // activates the app (focus change can cause the chat to jump to the bottom).
        activateAndRaise(chatWindow)

        // Phase 2: Scroll to top with KakaoTalk in the foreground.
        scrollToTop(scrollX: scrollX, scrollY: scrollY, progress: progress)

        // Phase 3: Repeatedly find + click "View Previous Chats" via OCR
        for attempt in 0..<options.maxPreviousClicks {
            // Take screenshot and OCR to find "View Previous Chats"
            let screenshotPath = "/tmp/kakaocli_harvest_\(chatId).png"
            guard let buttonCenter = findViewPreviousChatsViaOCR(
                windowTitle: windowTitle,
                windowPos: winPos,
                windowSize: winSize,
                screenshotPath: screenshotPath
            ) else {
                progress("  No 'View Previous Chats' found in screenshot")
                break
            }

            let clickX = Int(buttonCenter.x)
            let clickY = Int(buttonCenter.y)

            // Click using direct CGEvent (KakaoTalk is already frontmost from activate above)
            progress("  Clicking 'View Previous Chats' at (\(clickX),\(clickY)) (attempt \(attempt + 1))...")
            clickAtScreenPoint(CGPoint(x: Double(clickX), y: Double(clickY)))
            Thread.sleep(forTimeInterval: 2.5)

            // Check if paywall dialog appeared (new popup window)
            if dismissPaywallIfPresent(app: app, chatWindowTitle: windowTitle) {
                progress("  Hit Talk Drive Plus paywall, dismissed")
                break
            }

            // Wait for messages to load into DB
            Thread.sleep(forTimeInterval: options.scrollDelay)

            // Check message count
            let newCount = queryMessageCount(db: db, chatId: chatId)
            if newCount > currentCount {
                let delta = newCount - initialCount
                progress("  +\(delta) messages loaded so far")
                currentCount = newCount
                // Re-activate and scroll to top for next "View Previous Chats"
                activateAndRaise(chatWindow)
                scrollToTop(scrollX: scrollX, scrollY: scrollY, progress: progress)
            } else {
                // No new messages — might have hit the limit silently
                break
            }
        }

        return currentCount
    }

    /// Activate KakaoTalk and raise a specific window to the front.
    /// This ensures CGEvent clicks reach the correct window.
    private static func activateAndRaise(_ window: AXUIElement) {
        try? AXHelpers.activateApp(bundleId: KakaoAutomator.bundleId)
        _ = AXHelpers.performAction(window, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Click at a screen point using CGEvent (goes to frontmost window at those coordinates).
    private static func clickAtScreenPoint(_ point: CGPoint) {
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                    mouseCursorPosition: point, mouseButton: .left),
           let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                  mouseCursorPosition: point, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
            usleep(50_000)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    /// Scroll to the top of the chat's message area.
    /// Positions cursor over the chat window and scrolls without focus change,
    /// relying on macOS sending scroll events to the window under the cursor.
    private static func scrollToTop(scrollX: Int, scrollY: Int, progress: @escaping (String) -> Void) {
        progress("  Scrolling to top...")
        shellExec("cliclick", "m:\(scrollX),\(scrollY)")
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<15 {
            shellExec("peekaboo", "scroll", "--direction", "up",
                      "--amount", "100", "--no-auto-focus")
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Vision OCR

    /// Get the CGWindow ID for a KakaoTalk window by title.
    private static func getWindowId(title: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["peekaboo", "window", "list", "--app", "KakaoTalk", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let windows = dataObj["windows"] as? [[String: Any]] else {
            return nil
        }
        for w in windows {
            if let wTitle = w["window_title"] as? String, wTitle == title,
               let wId = w["window_id"] as? Int {
                return wId
            }
        }
        // Fallback: partial match
        for w in windows {
            if let wTitle = w["window_title"] as? String, wTitle.contains(title),
               let wId = w["window_id"] as? Int {
                return wId
            }
        }
        return nil
    }

    /// Take a screenshot of the chat window and use Vision OCR to find "View Previous Chats".
    /// Returns the screen coordinates of the text center, or nil if not found.
    private static func findViewPreviousChatsViaOCR(
        windowTitle: String,
        windowPos: CGPoint,
        windowSize: CGSize,
        screenshotPath: String
    ) -> CGPoint? {
        // Get window ID for reliable capture (--app alone can capture hidden sub-windows)
        guard let windowId = getWindowId(title: windowTitle) else {
            return nil
        }

        // Take screenshot using window ID
        let exitCode = shellExec(
            "peekaboo", "image",
            "--window-id", "\(windowId)",
            "--path", screenshotPath
        )
        guard exitCode == 0, FileManager.default.fileExists(atPath: screenshotPath) else {
            return nil
        }

        guard let image = NSImage(contentsOfFile: screenshotPath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en", "ko"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let text = topCandidate.string.lowercased()
            if text.contains("view previous") || text.contains("이전 대화") {
                // Bounding box is normalized (0-1), origin at bottom-left
                let box = observation.boundingBox
                let centerX = box.origin.x + box.width / 2
                let centerY = 1.0 - (box.origin.y + box.height / 2)  // Flip Y (Vision uses bottom-left origin)

                // Convert to screen coordinates relative to window
                let screenX = windowPos.x + CGFloat(centerX) * windowSize.width
                let screenY = windowPos.y + CGFloat(centerY) * windowSize.height

                return CGPoint(x: screenX, y: screenY)
            }
        }

        return nil
    }

    // MARK: - Paywall Detection

    /// Check if any popup appeared after clicking "View Previous Chats".
    /// Uses CGWindow API (peekaboo window list) since the paywall popup may not
    /// appear in the AX window list (it's a sheet/panel, not a standard window).
    private static func dismissPaywallIfPresent(app: AXUIElement, chatWindowTitle: String) -> Bool {
        // Use peekaboo window list to get CGWindow-level windows
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["peekaboo", "window", "list", "--app", "KakaoTalk", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return false }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let windows = dataObj["windows"] as? [[String: Any]] else {
            return false
        }

        // Expected: Main Window + chat window = 2. Any extra = popup.
        var popupFound = false
        for w in windows {
            let title = w["window_title"] as? String ?? ""
            if title == "KakaoTalk" { continue }       // Main window
            if title == chatWindowTitle { continue }    // Chat window
            popupFound = true
            break
        }

        guard popupFound else { return false }

        // Dismiss popup: Escape key
        shellExec("peekaboo", "type", "--escape", "--app", "KakaoTalk")
        Thread.sleep(forTimeInterval: 0.5)

        return true
    }

    /// Query the current message count for a chat.
    private static func queryMessageCount(db: DatabaseReader, chatId: Int64) -> Int {
        if let result = try? db.rawQuery(
            "SELECT COUNT(*) FROM NTChatMessage WHERE chatId = \(chatId)"
        ), let first = result.first, let count = first[0] as? Int64 {
            return Int(count)
        }
        return 0
    }

    /// Run a shell command, returning its exit code.
    @discardableResult
    private static func shellExec(_ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Array(args)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
