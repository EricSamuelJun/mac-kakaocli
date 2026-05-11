import Foundation
import XCTest
@testable import KakaoCore

final class SendPolicyTests: XCTestCase {

    private let primaryChatId: Int64 = 313_526_436_723_168
    private let primaryUserId: Int64 = 68_062_272
    private let groupChatId: Int64 = 468_542_230_323_777

    // MARK: - Trivial paths

    func testNoPolicyAllowsEverything() {
        let decision = SendPolicyVerifier.verify(
            chatId: primaryChatId,
            actualName: "전성욱",
            actualDirectMemberUserId: primaryUserId,
            policy: nil
        )
        XCTAssertEqual(decision, .allow)
    }

    func testBypassAllowsWithWarning() {
        let policy = Policy(strictMode: true, denyByDefault: true)
        let decision = SendPolicyVerifier.verify(
            chatId: 999,
            actualName: "Anyone",
            actualDirectMemberUserId: nil,
            policy: policy,
            bypass: true
        )
        guard case .allowWithWarning = decision else {
            XCTFail("expected allowWithWarning, got \(decision)")
            return
        }
    }

    // MARK: - Allowlist match

    func testAllowlistedDirectChatMatches() {
        let policy = Policy(
            allowlist: [PolicyEntry(
                chatId: primaryChatId,
                expectedName: "전성욱",
                expectedUserId: primaryUserId,
                purpose: "primary_account_1on1"
            )],
            strictMode: true
        )
        let decision = SendPolicyVerifier.verify(
            chatId: primaryChatId,
            actualName: "전성욱",
            actualDirectMemberUserId: primaryUserId,
            policy: policy
        )
        XCTAssertEqual(decision, .allow)
    }

    func testAllowlistedGroupWithMemberCountSuffixStillMatches() {
        // KakaoTalk often shows "테스트 5" for the group "테스트". The substring
        // matcher (NFC + lowercase) tolerates the suffix.
        let policy = Policy(
            allowlist: [PolicyEntry(
                chatId: groupChatId,
                expectedName: "테스트",
                expectedUserId: nil,
                purpose: "test_group"
            )]
        )
        let decision = SendPolicyVerifier.verify(
            chatId: groupChatId,
            actualName: "테스트 5",
            actualDirectMemberUserId: nil,
            policy: policy
        )
        XCTAssertEqual(decision, .allow)
    }

    // MARK: - Allowlist mismatch (impersonation defence)

    func testNameMismatchDenied() {
        let policy = Policy(
            allowlist: [PolicyEntry(
                chatId: primaryChatId,
                expectedName: "전성욱",
                expectedUserId: primaryUserId,
                purpose: "primary_account_1on1"
            )]
        )
        let decision = SendPolicyVerifier.verify(
            chatId: primaryChatId,
            actualName: "최세일", // impersonator sliding into the same chatId
            actualDirectMemberUserId: primaryUserId,
            policy: policy
        )
        guard case .deny = decision else {
            XCTFail("expected deny on name mismatch, got \(decision)")
            return
        }
    }

    func testExpectedUserIdMismatchDenied() {
        let policy = Policy(
            allowlist: [PolicyEntry(
                chatId: primaryChatId,
                expectedName: "전성욱",
                expectedUserId: primaryUserId,
                purpose: "primary_account_1on1"
            )]
        )
        let decision = SendPolicyVerifier.verify(
            chatId: primaryChatId,
            actualName: "전성욱",
            actualDirectMemberUserId: 999_999_999, // wrong peer
            policy: policy
        )
        guard case .deny = decision else {
            XCTFail("expected deny on userId mismatch, got \(decision)")
            return
        }
    }

    func testGroupEntryWithNilExpectedUserIdSkipsUserIdCheck() {
        // No expectedUserId means the entry is for a group / self-chat /
        // open channel; the verifier must not deny just because the DB
        // returns nil for directChatMemberUserId.
        let policy = Policy(
            allowlist: [PolicyEntry(
                chatId: groupChatId,
                expectedName: "테스트",
                expectedUserId: nil,
                purpose: "test_group"
            )]
        )
        let decision = SendPolicyVerifier.verify(
            chatId: groupChatId,
            actualName: "테스트",
            actualDirectMemberUserId: nil,
            policy: policy
        )
        XCTAssertEqual(decision, .allow)
    }

    // MARK: - Unknown chatId

    func testStrictModeDeniesUnknownChat() {
        let policy = Policy(strictMode: true, denyByDefault: false)
        let decision = SendPolicyVerifier.verify(
            chatId: 99_999,
            actualName: "Stranger",
            actualDirectMemberUserId: nil,
            policy: policy
        )
        guard case .deny = decision else {
            XCTFail("expected deny in strict mode, got \(decision)")
            return
        }
    }

    func testDenyByDefaultDeniesUnknownChatEvenWithoutStrict() {
        let policy = Policy(strictMode: false, denyByDefault: true)
        let decision = SendPolicyVerifier.verify(
            chatId: 99_999,
            actualName: "Stranger",
            actualDirectMemberUserId: nil,
            policy: policy
        )
        guard case .deny = decision else {
            XCTFail("expected deny via denyByDefault, got \(decision)")
            return
        }
    }

    func testAdvisoryModeAllowsUnknownChatWithWarning() {
        let policy = Policy(strictMode: false, denyByDefault: false)
        let decision = SendPolicyVerifier.verify(
            chatId: 99_999,
            actualName: "Stranger",
            actualDirectMemberUserId: nil,
            policy: policy
        )
        guard case .allowWithWarning = decision else {
            XCTFail("expected allowWithWarning in advisory mode, got \(decision)")
            return
        }
    }
}
