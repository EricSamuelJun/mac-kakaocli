import CommonCrypto
import Foundation
import XCTest
@testable import KakaoCore

final class UserIdRecoveryTests: XCTestCase {

    private func sha512Hex(_ s: String) -> String {
        let data = Array(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512(data, CC_LONG(data.count), &hash)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func testRecoversKnownSmallUserId() {
        let id = 99_999
        let hash = sha512Hex(String(id))
        let opts = UserIdRecovery.Options(maxId: 200_000, maxSeconds: 30, threadCount: 4)
        XCTAssertEqual(UserIdRecovery.recover(targetHash: hash, options: opts), id)
    }

    func testReturnsNilWhenTargetIsAboveMaxId() {
        let id = 100_001
        let hash = sha512Hex(String(id))
        let opts = UserIdRecovery.Options(maxId: 100_000, maxSeconds: 5, threadCount: 2)
        XCTAssertNil(UserIdRecovery.recover(targetHash: hash, options: opts))
    }

    func testSkipIdsAreNeverReturned() {
        // Confirm the mechanism: an ID present in skipIds is never returned
        // even if its hash matches the target.
        let id = 12_345
        let hash = sha512Hex(String(id))
        let opts = UserIdRecovery.Options(maxId: 100_000, maxSeconds: 5, threadCount: 2, skipIds: [id])
        XCTAssertNil(UserIdRecovery.recover(targetHash: hash, options: opts))
    }

    func testRejectsMalformedHash() {
        let opts = UserIdRecovery.Options(maxId: 100, maxSeconds: 1, threadCount: 1)
        XCTAssertNil(UserIdRecovery.recover(targetHash: "tooshort", options: opts))
        XCTAssertNil(UserIdRecovery.recover(targetHash: String(repeating: "z", count: 128), options: opts))
    }

    func testResultIsIndependentOfThreadCount() {
        let id = 50_000
        let hash = sha512Hex(String(id))
        for threads in [1, 2, 4, 8] {
            let opts = UserIdRecovery.Options(maxId: 100_000, maxSeconds: 30, threadCount: threads, skipIds: [])
            XCTAssertEqual(
                UserIdRecovery.recover(targetHash: hash, options: opts),
                id,
                "threads=\(threads) should still recover \(id)"
            )
        }
    }

    func testKnownSystemIdsContainsTheFourBakedInIds() {
        // These four IDs surface as candidates on every install (the official-sender
        // accounts KakaoTalk preloads). They must always be in the skip set.
        XCTAssertTrue(UserIdRecovery.knownSystemIds.contains(25_411_718))
        XCTAssertTrue(UserIdRecovery.knownSystemIds.contains(344_940_307))
        XCTAssertTrue(UserIdRecovery.knownSystemIds.contains(388_584_983))
        XCTAssertTrue(UserIdRecovery.knownSystemIds.contains(366_369_712))
    }
}
