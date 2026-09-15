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

    /// Every combination of toggles, with empty-field edge cases, matches the original
    /// segments-joined-by-space layout.
    func testAllToggleCombinationsMatchReferenceLayout() {
        let plain = makeEntry()
        let edge = LogEntry(level: LogLevel(rawValue: 1, name: "", osLogType: .default), message: "",
                            date: plain.date, subsystem: "", category: "", fileID: "", fileName: "", filePath: "",
                            className: "", function: "", line: -7, threadID: 0, threadName: "", isMainThread: false,
                            processID: 0)
        var mismatches: [String] = []
        for mask in 0..<512 {
            for dateFormat in ["yyyy-MM-dd HH:mm:ss.SSS Z", ""] {
                let bit = { (i: Int) in mask & (1 << i) != 0 }
                let formatter = TextLogFormatter(dateFormat: dateFormat, timeZone: ist, includeDate: bit(0), includeEmoji: bit(1),
                                                 includeLevel: bit(2), includeThread: bit(3), includeSubsystem: bit(4),
                                                 includeCategory: bit(5), includeFileAndLine: bit(6),
                                                 includeClassName: bit(7), includeFunction: bit(8))
                for entry in [plain, edge, makeEntry(level: .error, threadName: "")] {
                    let expected = referenceFormat(formatter, entry)
                    let actual = formatter.format(entry)
                    if actual != expected { mismatches.append("mask \(mask) '\(dateFormat)': \(actual) != \(expected)") }
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(3))")
    }

    /// The original implementation, kept as the layout reference.
    private func referenceFormat(_ f: TextLogFormatter, _ entry: LogEntry) -> String {
        var segments: [String] = []
        if f.includeDate { segments.append(DateFormatterCache.string(from: entry.date, format: f.dateFormat, timeZone: f.timeZone)) }
        if f.includeEmoji, !entry.level.emoji.isEmpty { segments.append(entry.level.emoji) }
        if f.includeLevel { segments.append("[\(entry.level.name)]") }
        if f.includeThread {
            let id = "0x" + String(entry.threadID, radix: 16)
            segments.append(entry.threadName.isEmpty ? "[\(id)]" : "[\(entry.threadName):\(id)]")
        }
        if f.includeSubsystem { segments.append("[\(entry.subsystem)]") }
        if f.includeCategory { segments.append("[\(entry.category)]") }
        if f.includeFileAndLine { segments.append("\(entry.fileName):\(entry.line)") }
        switch (f.includeClassName, f.includeFunction) {
        case (true, true): segments.append("\(entry.className).\(entry.function)")
        case (true, false): segments.append(entry.className)
        case (false, true): segments.append(entry.function)
        case (false, false): break
        }
        guard !segments.isEmpty else { return entry.message }
        return segments.joined(separator: " ") + " - " + entry.message
    }

    func testOSLogDefaultOmitsFieldsUnifiedLoggingRecords() {
        XCTAssertEqual(
            TextLogFormatter.osLogDefault.format(makeEntry()),
            "[main:0x1a2b] NetworkManager.swift:42 NetworkManager.fetch(_:) - Request started"
        )
    }
}
