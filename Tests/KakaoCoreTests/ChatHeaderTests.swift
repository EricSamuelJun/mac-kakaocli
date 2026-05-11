import Testing
@testable import KakaoCore

@Test func headerExactMatch() {
    #expect(AXHelpers.chatTitleMatches(title: "전성욱", expected: "전성욱"))
}

@Test func headerCaseAndWhitespaceInsensitive() {
    #expect(AXHelpers.chatTitleMatches(title: "  KakaoTalk Test  ", expected: "kakaotalk test"))
}

@Test func headerAllowsGroupCountSuffix() {
    // KakaoTalk often appends a member count like "테스트 5" to group titles.
    #expect(AXHelpers.chatTitleMatches(title: "테스트 5", expected: "테스트"))
}

@Test func headerRejectsDifferentChat() {
    #expect(!AXHelpers.chatTitleMatches(title: "최세일", expected: "전성욱"))
}

@Test func headerEmptyExpectedIsTrustedAsPass() {
    // No expected value → caller chose not to verify; pass-through.
    #expect(AXHelpers.chatTitleMatches(title: "anything", expected: ""))
    #expect(AXHelpers.chatTitleMatches(title: "anything", expected: "   "))
}

@Test func headerHandlesNFCDecomposedKorean() {
    // Decomposed jamo (NFD) of "전성욱" vs precomposed.
    let nfdTitle = "전성욱".decomposedStringWithCanonicalMapping
    #expect(AXHelpers.chatTitleMatches(title: nfdTitle, expected: "전성욱"))
}
