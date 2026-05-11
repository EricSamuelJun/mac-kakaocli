import CommonCrypto
import Foundation

/// Recovers a KakaoTalk userId by brute-forcing the SHA-512 pre-image of a
/// hash embedded in plist revision keys (e.g. `DESIGNATEDFRIENDSREVISION:<sha512hex>`).
///
/// KakaoTalk stores SHA-512(userId) as a hex suffix on per-account plist keys.
/// userIds are decimal integers, often well under 10^10, so the pre-image is
/// recoverable on commodity hardware in seconds with parallel search.
public enum UserIdRecovery {

    /// IDs that appear as candidates on every install — preloaded
    /// system / official-sender accounts shipped with KakaoTalk. Never the
    /// operator's real userId, so they are skipped during brute-force and
    /// elsewhere we surface candidate lists.
    public static let knownSystemIds: Set<Int> = [
        25_411_718,
        344_940_307,
        388_584_983,
        366_369_712,
    ]

    public struct Options: Sendable {
        /// Upper bound (exclusive) of the search space.
        public var maxId: Int
        /// Wall-clock budget. Threads bail out at the next checkpoint when this elapses.
        public var maxSeconds: Double
        /// Worker thread count. Defaults to the number of active processors.
        public var threadCount: Int
        /// IDs to skip during brute-force.
        public var skipIds: Set<Int>

        public init(
            maxId: Int = 10_000_000_000,
            maxSeconds: Double = 60.0,
            threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
            skipIds: Set<Int> = UserIdRecovery.knownSystemIds
        ) {
            self.maxId = maxId
            self.maxSeconds = maxSeconds
            self.threadCount = max(1, threadCount)
            self.skipIds = skipIds
        }
    }

    /// Recover the integer pre-image of a SHA-512 hex hash, if it lies in
    /// `0..<options.maxId` and the search completes within `options.maxSeconds`.
    /// Returns nil if not found or the deadline elapses.
    public static func recover(targetHash: String, options: Options = Options()) -> Int? {
        guard let targetBytes = parseHash(targetHash) else { return nil }

        let deadline = CFAbsoluteTimeGetCurrent() + options.maxSeconds
        let threads = max(1, options.threadCount)
        let maxId = options.maxId
        let skipIds = options.skipIds
        let flag = FoundFlag()

        // Interleaved striping: thread t walks t, t+threads, t+2*threads, ...
        // Each thread checkpoints every ~1M of its own iterations to honour
        // the deadline and to early-exit when another thread already won.
        DispatchQueue.concurrentPerform(iterations: threads) { tid in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            var checkCounter = 0
            var i = tid
            while i < maxId {
                checkCounter += 1
                if checkCounter >= 1_000_000 {
                    checkCounter = 0
                    if flag.get() != nil { return }
                    if CFAbsoluteTimeGetCurrent() > deadline { return }
                }
                if !skipIds.contains(i) {
                    let s = String(i)
                    let data = Array(s.utf8)
                    CC_SHA512(data, CC_LONG(data.count), &hash)
                    if hash == targetBytes {
                        flag.setIfNil(i)
                        return
                    }
                }
                i += threads
            }
        }

        return flag.get()
    }

    /// Parse a 128-char hex string into 64 bytes. Returns nil if malformed.
    private static func parseHash(_ hex: String) -> [UInt8]? {
        guard hex.count == 128 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let chars = Array(hex)
        for i in 0..<64 {
            guard let byte = UInt8(String(chars[i*2...i*2+1]), radix: 16) else { return nil }
            bytes[i] = byte
        }
        return bytes
    }

    /// Lock-protected holder for the first-found result. Lets workers
    /// short-circuit once one of them has produced an answer.
    private final class FoundFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int?
        func get() -> Int? {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func setIfNil(_ v: Int) {
            lock.lock(); defer { lock.unlock() }
            if _value == nil { _value = v }
        }
    }
}
