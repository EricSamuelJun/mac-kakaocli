import XCTest
@testable import KakaoCore

final class KeyDerivationTests: XCTestCase {

    func testHashedDeviceUUID() {
        let result1 = KeyDerivation.hashedDeviceUUID("TEST-UUID-1234")
        let result2 = KeyDerivation.hashedDeviceUUID("TEST-UUID-1234")
        XCTAssertEqual(result1, result2, "Same input should produce same output")
        XCTAssertFalse(result1.isEmpty, "Output should not be empty")
    }

    func testDatabaseNameDeterministic() {
        let name1 = KeyDerivation.databaseName(userId: 12345, uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let name2 = KeyDerivation.databaseName(userId: 12345, uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(name1, name2, "Same inputs should produce same database name")
        XCTAssertEqual(name1.count, 78, "Database name should be 78 characters")
    }

    func testSecureKeyDeterministic() {
        let key1 = KeyDerivation.secureKey(userId: 12345, uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let key2 = KeyDerivation.secureKey(userId: 12345, uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(key1, key2, "Same inputs should produce same key")
        XCTAssertFalse(key1.isEmpty, "Key should not be empty")
    }

    func testDifferentUsersGetDifferentKeys() {
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let key1 = KeyDerivation.secureKey(userId: 11111, uuid: uuid)
        let key2 = KeyDerivation.secureKey(userId: 22222, uuid: uuid)
        XCTAssertNotEqual(key1, key2, "Different user IDs should produce different keys")
    }
}
