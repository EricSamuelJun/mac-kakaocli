import Foundation
import XCTest
@testable import KakaoCore

final class ConfigTests: XCTestCase {

    private var tempDir: String!
    private var configPath: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "kakaocli-test-\(UUID().uuidString)"
        configPath = (tempDir as NSString).appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testLoadReturnsNilWhenFileMissing() throws {
        XCTAssertNil(try Config.load(from: configPath))
    }

    func testSaveAndLoadRoundTrip() throws {
        let original = Config(
            userId: 361_746_971,
            deviceUUID: "E7DD132D-3B10-5929-B075-95BDEBE71970",
            databasePath: "/tmp/db"
        )
        try original.save(to: configPath)

        let loaded = try Config.load(from: configPath)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, Config.currentVersion)
        XCTAssertEqual(loaded?.userId, 361_746_971)
        XCTAssertEqual(loaded?.deviceUUID, "E7DD132D-3B10-5929-B075-95BDEBE71970")
        XCTAssertEqual(loaded?.databasePath, "/tmp/db")
    }

    func testSaveCreatesParentDirectoryIfMissing() throws {
        let nestedPath = (tempDir as NSString)
            .appendingPathComponent("nested/dir/config.json")
        let cfg = Config(userId: 42)
        try cfg.save(to: nestedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedPath))
    }

    func testSavedFileIsOwnerReadableOnly() throws {
        let cfg = Config(userId: 42)
        try cfg.save(to: configPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(
            perms & 0o777, 0o600,
            "config.json should be 0600 — no need to be world-readable"
        )
    }

    func testLoadThrowsOnMalformedJSON() throws {
        try "not valid json { ".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertThrowsError(try Config.load(from: configPath))
    }

    func testOptionalFieldsRoundTripAsNull() throws {
        // userId-only config should encode/decode cleanly, with the optionals nil.
        let cfg = Config(userId: 42)
        try cfg.save(to: configPath)
        let loaded = try Config.load(from: configPath)
        XCTAssertEqual(loaded?.userId, 42)
        XCTAssertNil(loaded?.deviceUUID)
        XCTAssertNil(loaded?.databasePath)
    }
}
