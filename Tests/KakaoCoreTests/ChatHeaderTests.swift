import XCTest
@testable import KakaoCore

final class ChatHeaderTests: XCTestCase {

    func testHeaderExactMatch() {
        XCTAssertTrue(AXHelpers.chatTitleMatches(title: "전성욱", expected: "전성욱"))
    }

    func testHeaderCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(AXHelpers.chatTitleMatches(title: "  KakaoTalk Test  ", expected: "kakaotalk test"))
    }

    func testHeaderAllowsGroupCountSuffix() {
        // KakaoTalk often appends a member count like "테스트 5" to group titles.
        XCTAssertTrue(AXHelpers.chatTitleMatches(title: "테스트 5", expected: "테스트"))
    }

    func testHeaderRejectsDifferentChat() {
        XCTAssertFalse(AXHelpers.chatTitleMatches(title: "최세일", expected: "전성욱"))
    }

    func testHeaderEmptyExpectedIsTrustedAsPass() {
        // No expected value → caller chose not to verify; pass-through.
        XCTAssertTrue(AXHelpers.chatTitleMatches(title: "anything", expected: ""))
        XCTAssertTrue(AXHelpers.chatTitleMatches(title: "anything", expected: "   "))
    }

    func testHeaderHandlesNFCDecomposedKorean() {
        // Decomposed jamo (NFD) of "전성욱" vs precomposed.
        let nfdTitle = "전성욱".decomposedStringWithCanonicalMapping
        XCTAssertTrue(AXHelpers.chatTitleMatches(title: nfdTitle, expected: "전성욱"))
    }
}
