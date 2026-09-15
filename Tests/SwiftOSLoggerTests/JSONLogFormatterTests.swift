import XCTest
@testable import SwiftOSLogger

final class JSONLogFormatterTests: XCTestCase {
    func testProducesSingleLineJSONWithAllKeys() throws {
        let line = JSONLogFormatter().format(makeEntry(message: "quote \" and\nnewline"))
        XCTAssertFalse(line.contains("\n"))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["timestamp"] as? String, "2026-09-15T08:15:12.347Z")
        XCTAssertEqual(object["level"] as? String, "INFO")
        XCTAssertEqual(object["levelValue"] as? Int, 300)
        XCTAssertEqual(object["message"] as? String, "quote \" and\nnewline")
        XCTAssertEqual(object["subsystem"] as? String, "com.acme.app")
        XCTAssertEqual(object["category"] as? String, "Network")
        XCTAssertEqual(object["file"] as? String, "NetworkManager.swift")
        XCTAssertEqual(object["line"] as? Int, 42)
        XCTAssertEqual(object["class"] as? String, "NetworkManager")
        XCTAssertEqual(object["function"] as? String, "fetch(_:)")
        XCTAssertEqual(object["threadID"] as? Int, 0x1a2b)
        XCTAssertEqual(object["threadName"] as? String, "main")
        XCTAssertEqual(object["isMainThread"] as? Bool, true)
        XCTAssertEqual(object["pid"] as? Int, 4821)
        XCTAssertEqual(object.count, 14)
    }

    func testKeysAreSorted() {
        let line = JSONLogFormatter().format(makeEntry())
        XCTAssertTrue(line.hasPrefix("{\"category\":"))
    }
}
