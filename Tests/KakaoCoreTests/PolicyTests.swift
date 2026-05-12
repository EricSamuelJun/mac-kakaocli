import Foundation
import XCTest
@testable import KakaoCore

final class PolicyTests: XCTestCase {

    private var tempDir: String!
    private var policyPath: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "kakaocli-policy-test-\(UUID().uuidString)"
        policyPath = (tempDir as NSString).appendingPathComponent("policy.json")
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
        XCTAssertNil(try Policy.load(from: policyPath))
    }

    func testFullEntryRoundTrip() throws {
        let entry = PolicyEntry(
            chatId: 313_526_436_723_168,
            expectedName: "전성욱",
            expectedUserId: 68_062_272,
            purpose: "primary_account_1on1"
        )
        let policy = Policy(
            allowlist: [entry],
            strictMode: true,
            denyByDefault: true,
            primaryChatId: 313_526_436_723_168
        )
        try policy.save(to: policyPath)

        let loaded = try Policy.load(from: policyPath)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, Policy.currentVersion)
        XCTAssertEqual(loaded?.allowlist.count, 1)
        XCTAssertEqual(loaded?.allowlist.first?.chatId, 313_526_436_723_168)
        XCTAssertEqual(loaded?.allowlist.first?.expectedName, "전성욱")
        XCTAssertEqual(loaded?.allowlist.first?.expectedUserId, 68_062_272)
        XCTAssertEqual(loaded?.allowlist.first?.purpose, "primary_account_1on1")
        XCTAssertEqual(loaded?.strictMode, true)
        XCTAssertEqual(loaded?.denyByDefault, true)
        XCTAssertEqual(loaded?.primaryChatId, 313_526_436_723_168)
    }

    func testEmptyAllowlistRoundTripsAsScaffoldedByInit() throws {
        // The exact shape `kakaocli init` writes when --non-interactive
        // is used or when the operator picks "skip".
        let policy = Policy()
        try policy.save(to: policyPath)

        let loaded = try Policy.load(from: policyPath)
        XCTAssertEqual(loaded?.allowlist.count, 0)
        XCTAssertEqual(loaded?.strictMode, false)
        XCTAssertEqual(loaded?.denyByDefault, true)
        XCTAssertNil(loaded?.primaryChatId)
    }

    func testGroupEntryHasNilExpectedUserId() throws {
        // Groups have no `directChatMemberUserId` to pin against — the schema
        // must round-trip a nil expectedUserId without confusing the decoder.
        let entry = PolicyEntry(
            chatId: 468_542_230_323_777,
            expectedName: "테스트",
            expectedUserId: nil,
            purpose: "test_group"
        )
        let policy = Policy(allowlist: [entry])
        try policy.save(to: policyPath)

        let loaded = try Policy.load(from: policyPath)
        XCTAssertNotNil(loaded?.allowlist.first)
        XCTAssertNil(loaded?.allowlist.first?.expectedUserId)
    }

    func testSavedFileIsOwnerReadableOnly() throws {
        try Policy().save(to: policyPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: policyPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)
    }

    func testAliasRoundTrips() throws {
        let entry = PolicyEntry(
            chatId: 468_542_230_323_777,
            expectedName: "테스트",
            expectedUserId: nil,
            purpose: "test_group",
            alias: "49기방"
        )
        try Policy(allowlist: [entry]).save(to: policyPath)
        let loaded = try Policy.load(from: policyPath)
        XCTAssertEqual(loaded?.allowlist.first?.alias, "49기방")
    }

    func testLoadingLegacyEntryWithoutAliasFieldYieldsNil() throws {
        // policy.json files written before the alias field was added must
        // continue to load; the field decodes as nil.
        let legacy = #"""
        {
          "version": 1,
          "allowlist": [
            {
              "chatId": 313526436723168,
              "expectedName": "전성욱",
              "expectedUserId": 68062272,
              "purpose": "primary_account_1on1"
            }
          ],
          "strictMode": false,
          "denyByDefault": true,
          "primaryChatId": 313526436723168
        }
        """#
        try legacy.data(using: .utf8)!.write(to: URL(fileURLWithPath: policyPath))
        let loaded = try Policy.load(from: policyPath)
        XCTAssertEqual(loaded?.allowlist.count, 1)
        XCTAssertNil(loaded?.allowlist.first?.alias)
    }
}
