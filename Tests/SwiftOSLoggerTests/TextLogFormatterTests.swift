import XCTest
@testable import SwiftOSLogger

final class TextLogFormatterTests: XCTestCase {
    private let ist = TimeZone(secondsFromGMT: 19_800)! // +0530

    func testDefaultLayout() {
        let formatter = TextLogFormatter(timeZone: ist)
        XCTAssertEqual(
            formatter.format(makeEntry()),
            "2026-09-15 13:45:12.347 +0530 [INFO] [main:0x1a2b] [Network] NetworkManager.swift:42 NetworkManager.fetch(_:) - Request started"
        )
    }

    func testThreadWithoutNameShowsOnlyID() {
        let formatter = TextLogFormatter(includeDate: false, includeLevel: false, includeCategory: false,
                                         includeFileAndLine: false, includeClassName: false, includeFunction: false)
        XCTAssertEqual(formatter.format(makeEntry(threadID: 255, threadName: "")), "[0xff] - Request started")
    }

    func testEmojiAndSubsystem() {
        let formatter = TextLogFormatter(timeZone: ist, includeDate: false, includeEmoji: true, includeThread: false,
                                         includeSubsystem: true, includeFileAndLine: false)
        XCTAssertEqual(
            formatter.format(makeEntry(level: .error)),
            "❌ [ERROR] [com.acme.app] [Network] NetworkManager.fetch(_:) - Request started"
        )
    }

    func testClassNameAndFunctionToggles() {
        var formatter = TextLogFormatter(includeDate: false, includeLevel: false, includeThread: false,
                                         includeCategory: false, includeFileAndLine: false)
        formatter.includeClassName = false
        XCTAssertEqual(formatter.format(makeEntry()), "fetch(_:) - Request started")
        formatter.includeClassName = true
        formatter.includeFunction = false
        XCTAssertEqual(formatter.format(makeEntry()), "NetworkManager - Request started")
    }

    func testAllSegmentsOffPrintsOnlyMessage() {
        let formatter = TextLogFormatter(includeDate: false, includeLevel: false, includeThread: false,
                                         includeCategory: false, includeFileAndLine: false,
                                         includeClassName: false, includeFunction: false)
        XCTAssertEqual(formatter.format(makeEntry()), "Request started")
    }

    func testCustomDateFormat() {
        let formatter = TextLogFormatter(dateFormat: "HH:mm:ss", timeZone: ist, includeLevel: false, includeThread: false,
                                         includeCategory: false, includeFileAndLine: false,
                                         includeClassName: false, includeFunction: false)
        XCTAssertEqual(formatter.format(makeEntry()), "13:45:12 - Request started")
    }

    func testOSLogDefaultOmitsFieldsUnifiedLoggingRecords() {
        XCTAssertEqual(
            TextLogFormatter.osLogDefault.format(makeEntry()),
            "[main:0x1a2b] NetworkManager.swift:42 NetworkManager.fetch(_:) - Request started"
        )
    }
}
