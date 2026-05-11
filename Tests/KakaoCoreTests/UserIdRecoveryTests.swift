import CommonCrypto
import Foundation
import Testing
@testable import KakaoCore

private func sha512Hex(_ s: String) -> String {
    let data = Array(s.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
    CC_SHA512(data, CC_LONG(data.count), &hash)
    return hash.map { String(format: "%02x", $0) }.joined()
}

@Test func recoversKnownSmallUserId() {
    let id = 99_999
    let hash = sha512Hex(String(id))
    let opts = UserIdRecovery.Options(maxId: 200_000, maxSeconds: 30, threadCount: 4)
    #expect(UserIdRecovery.recover(targetHash: hash, options: opts) == id)
}

@Test func returnsNilWhenTargetIsAboveMaxId() {
    let id = 100_001
    let hash = sha512Hex(String(id))
    let opts = UserIdRecovery.Options(maxId: 100_000, maxSeconds: 5, threadCount: 2)
    #expect(UserIdRecovery.recover(targetHash: hash, options: opts) == nil)
}

@Test func skipIdsAreNeverReturned() {
    // Confirm the mechanism: an ID present in skipIds is never returned
    // even if its hash matches the target.
    let id = 12_345
    let hash = sha512Hex(String(id))
    let opts = UserIdRecovery.Options(maxId: 100_000, maxSeconds: 5, threadCount: 2, skipIds: [id])
    #expect(UserIdRecovery.recover(targetHash: hash, options: opts) == nil)
}

@Test func rejectsMalformedHash() {
    let opts = UserIdRecovery.Options(maxId: 100, maxSeconds: 1, threadCount: 1)
    #expect(UserIdRecovery.recover(targetHash: "tooshort", options: opts) == nil)
    #expect(UserIdRecovery.recover(targetHash: String(repeating: "z", count: 128), options: opts) == nil)
}

@Test func resultIsIndependentOfThreadCount() {
    let id = 50_000
    let hash = sha512Hex(String(id))
    for threads in [1, 2, 4, 8] {
        let opts = UserIdRecovery.Options(maxId: 100_000, maxSeconds: 30, threadCount: threads, skipIds: [])
        #expect(
            UserIdRecovery.recover(targetHash: hash, options: opts) == id,
            "threads=\(threads) should still recover \(id)"
        )
    }
}

@Test func knownSystemIdsContainsTheFourBakedInIds() {
    // These four IDs surface as candidates on every install (the official-sender
    // accounts KakaoTalk preloads). They must always be in the skip set.
    #expect(UserIdRecovery.knownSystemIds.contains(25_411_718))
    #expect(UserIdRecovery.knownSystemIds.contains(344_940_307))
    #expect(UserIdRecovery.knownSystemIds.contains(388_584_983))
    #expect(UserIdRecovery.knownSystemIds.contains(366_369_712))
}
