import Foundation

/// Parser for `NTChatRoom.displayMemberIds`.
///
/// KakaoTalk stores the visible-member roster of a group chat as a binary
/// property list (`bplist00`) carrying an NSArray of NSNumbers, each
/// holding a userId that joins to `NTUser.userId`. This helper unwraps
/// that blob into a plain `[Int64]` so callers can JOIN against NTUser
/// without dealing with the bplist shape.
public enum DisplayMemberIds {

    /// Returns the userIds in the order KakaoTalk persists them.
    /// Returns an empty array on malformed / empty input (parse never throws —
    /// callers fall back to whatever default name they prefer).
    public static func parse(_ data: Data) -> [Int64] {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return [] }

        // The decoded value is almost always [NSNumber]; cover the alternate
        // numeric forms Foundation might produce on different macOS versions.
        if let arr = plist as? [NSNumber] {
            return arr.map { $0.int64Value }
        }
        if let arr = plist as? [Int64] {
            return arr
        }
        if let arr = plist as? [Int] {
            return arr.map { Int64($0) }
        }
        return []
    }
}
