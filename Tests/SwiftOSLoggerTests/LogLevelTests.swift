import os
import XCTest
@testable import SwiftOSLogger

final class LogLevelTests: XCTestCase {
    func testPresetsAreOrderedBySeverity() {
        let ordered: [LogLevel] = [.trace, .debug, .info, .notice, .warning, .error, .critical, .off]
        XCTAssertEqual(ordered, ordered.sorted())
        XCTAssertTrue(LogLevel.debug < .info)
        XCTAssertTrue(LogLevel.critical > .error)
    }

    func testPresetsMapToOSLogTypes() {
        XCTAssertEqual(LogLevel.trace.osLogType, .debug)
        XCTAssertEqual(LogLevel.debug.osLogType, .debug)
        XCTAssertEqual(LogLevel.info.osLogType, .info)
        XCTAssertEqual(LogLevel.notice.osLogType, .default)
        XCTAssertEqual(LogLevel.warning.osLogType, .default)
        XCTAssertEqual(LogLevel.error.osLogType, .error)
        XCTAssertEqual(LogLevel.critical.osLogType, .fault)
    }

    func testCustomLevelSortsBetweenPresets() {
        let audit = LogLevel(rawValue: 450, name: "AUDIT", emoji: "🧾", osLogType: .default)
        XCTAssertTrue(audit > .notice)
        XCTAssertTrue(audit < .warning)
        XCTAssertEqual(audit.name, "AUDIT")
        XCTAssertEqual(audit.emoji, "🧾")
        XCTAssertEqual(audit.description, "AUDIT")
    }

    func testEqualityUsesRawValueOnly() {
        let renamedInfo = LogLevel(rawValue: 300, name: "INFORMATION", osLogType: .info)
        XCTAssertEqual(renamedInfo, .info)
        XCTAssertEqual(Set([renamedInfo, LogLevel.info]).count, 1)
    }

    func testOffIsAboveEverything() {
        XCTAssertTrue(LogLevel.off > .critical)
        XCTAssertEqual(LogLevel.off.rawValue, Int.max)
    }
}
