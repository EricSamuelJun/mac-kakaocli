import XCTest
@testable import KakaoCore

/// Decision-matrix tests for the inbound command gate (`CommandPolicyVerifier`).
/// The verifier is pure — these tests cover every branch without touching
/// disk, the network, or KakaoTalk.
final class CommandPolicyTests: XCTestCase {

    private let ownerUserId: Int64 = 68_062_272
    private let strangerUserId: Int64 = 99_999_999

    // MARK: - Helpers

    private func policyWithOption_C(
        prefix: String? = "!명령",
        acl: [CommandAclEntry]? = nil,
        rolePerms: [String: [String]]? = nil
    ) -> Policy {
        Policy(
            commandPrefix: prefix,
            commandAcl: acl ?? [
                CommandAclEntry(userId: 68_062_272, role: "system", purpose: "owner"),
                CommandAclEntry(userId: 11_111_111, role: "general", purpose: "family"),
            ],
            rolePermissions: rolePerms ?? [
                "system": ["*"],
                "general": ["search", "messages.read"],
            ]
        )
    }

    // MARK: - Trivial paths

    func testNilPolicyDenies() {
        let d = CommandPolicyVerifier.verify(
            message: "!명령 hi",
            senderUserId: ownerUserId,
            requestedPermission: "search",
            policy: nil
        )
        if case .deny = d { /* pass */ } else { XCTFail("expected deny, got \(d)") }
    }

    func testMissingPrefixTreatsAsConversation() {
        // Option C not configured (commandPrefix nil) — must be silent
        // notACommand, NOT a deny, so the dispatcher doesn't log every
        // regular message as a denied attempt.
        let policy = policyWithOption_C(prefix: nil)
        let d = CommandPolicyVerifier.verify(
            message: "안녕",
            senderUserId: ownerUserId,
            requestedPermission: "search",
            policy: policy
        )
        XCTAssertEqual(d, .notACommand)
    }

    func testEmptyPrefixTreatsAsConversation() {
        let policy = policyWithOption_C(prefix: "")
        let d = CommandPolicyVerifier.verify(
            message: "!명령 hi",
            senderUserId: ownerUserId,
            requestedPermission: "search",
            policy: policy
        )
        XCTAssertEqual(d, .notACommand)
    }

    // MARK: - Prefix gate

    func testMessageWithoutPrefixIsNotACommand() {
        let d = CommandPolicyVerifier.verify(
            message: "안녕하세요 오늘 뉴스 좀요",
            senderUserId: ownerUserId,
            requestedPermission: "search",
            policy: policyWithOption_C()
        )
        XCTAssertEqual(d, .notACommand)
    }

    func testLeadingWhitespaceBeforePrefixIsTolerated() {
        // sync may deliver messages with stray whitespace; we trim before
        // the prefix check so an LLM-typed `"  !명령 ..."` still gates in.
        let d = CommandPolicyVerifier.verify(
            message: "   !명령 뉴스",
            senderUserId: ownerUserId,
            requestedPermission: "search",
            policy: policyWithOption_C()
        )
        XCTAssertEqual(d, .allow)   // system role + "*"
    }

    // MARK: - ACL gate

    func testSenderNotInAclDenies() {
        let d = CommandPolicyVerifier.verify(
            message: "!명령 뉴스",
            senderUserId: strangerUserId,
            requestedPermission: "search",
            policy: policyWithOption_C()
        )
        if case .deny = d { /* pass */ } else { XCTFail("expected deny, got \(d)") }
    }

    func testRoleNotInRolePermissionsDenies() {
        // ACL entry references "unknown_role" that isn't in rolePermissions.
        let policy = Policy(
            commandPrefix: "!명령",
            commandAcl: [
                CommandAclEntry(userId: ownerUserId, role: "phantom", purpose: "broken")
            ],
            rolePermissions: ["system": ["*"]]
        )
        let d = CommandPolicyVerifier.verify(
            message: "!명령 do thing",
            senderUserId: ownerUserId,
            requestedPermission: "search",
            policy: policy
        )
        if case .deny = d { /* pass */ } else { XCTFail("expected deny, got \(d)") }
    }

    // MARK: - Permission gate

    func testWildcardGrantsAnyPermission() {
        let policy = policyWithOption_C(rolePerms: ["system": ["*"]])
        let d = CommandPolicyVerifier.verify(
            message: "!명령 anything",
            senderUserId: ownerUserId,
            requestedPermission: "literally.anything",
            policy: policy
        )
        XCTAssertEqual(d, .allow)
    }

    func testSpecificPermissionGrantsOnlyThatPermission() {
        // general role has "search" + "messages.read" but not "cron.add".
        let general: Int64 = 11_111_111
        let policy = policyWithOption_C()

        XCTAssertEqual(
            CommandPolicyVerifier.verify(
                message: "!명령 뉴스",
                senderUserId: general,
                requestedPermission: "search",
                policy: policy
            ),
            .allow
        )
        let denied = CommandPolicyVerifier.verify(
            message: "!명령 cron",
            senderUserId: general,
            requestedPermission: "cron.add",
            policy: policy
        )
        if case .deny = denied { /* pass */ } else { XCTFail("expected deny, got \(denied)") }
    }

    // MARK: - Backward compatibility

    func testOldPolicyJsonDecodesWithoutOptionCFields() throws {
        // A policy.json written before v0.12 must round-trip without
        // commandPrefix / commandAcl / rolePermissions present.
        let oldJSON = """
        {
          "version": 1,
          "allowlist": [],
          "strictMode": false,
          "denyByDefault": true
        }
        """
        let data = Data(oldJSON.utf8)
        let policy = try JSONDecoder().decode(Policy.self, from: data)
        XCTAssertNil(policy.commandPrefix)
        XCTAssertNil(policy.commandAcl)
        XCTAssertNil(policy.rolePermissions)

        // ...and the verifier denies because no Option C config means
        // notACommand (conversation), not allow.
        XCTAssertEqual(
            CommandPolicyVerifier.verify(
                message: "!명령 hi",
                senderUserId: ownerUserId,
                requestedPermission: "search",
                policy: policy
            ),
            .notACommand
        )
    }
}
