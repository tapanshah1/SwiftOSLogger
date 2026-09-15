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

    /// The formatter must produce exactly what `JSONSerialization` (sorted keys, unescaped
    /// slashes) produces for the same fields, including every escaping edge case.
    func testOutputIsByteIdenticalToJSONSerialization() throws {
        var strings = ["", "plain", "quote \" backslash \\ slash / end", "tab\tnewline\ncr\rbackspace\u{08}formfeed\u{0C}",
                       "del \u{7F} nbsp \u{A0}", "é ü 漢字 🚀👩‍💻", "line sep \u{2028} para sep \u{2029}", "\u{FEFF}bom",
                       String(repeating: "long ", count: 200)]
        strings += (0..<0x20).map { "ctrl-\(String(UnicodeScalar(UInt8($0))))-\($0)" }
        let levels = [LogLevel.trace, .critical, .off,
                      LogLevel(rawValue: -42, name: "NEG \"quoted\"", osLogType: .default),
                      LogLevel(rawValue: Int.min, name: "MIN", osLogType: .default)]

        var mismatches: [String] = []
        for (index, text) in strings.enumerated() {
            let entry = LogEntry(
                level: levels[index % levels.count],
                message: text,
                date: Date(timeIntervalSince1970: 1_789_460_112.347 + Double(index) * 86_400.123),
                subsystem: "sub/\(text)",
                category: text,
                fileID: "Mod/\(text).swift",
                fileName: "\(text).swift",
                filePath: "/p/\(text).swift",
                className: "C\(text)",
                function: "f(\(text))",
                line: index.isMultiple(of: 2) ? index : -index,
                threadID: index.isMultiple(of: 3) ? UInt64.max : UInt64(index),
                threadName: text,
                isMainThread: index.isMultiple(of: 2),
                processID: index.isMultiple(of: 5) ? Int32.max : Int32(index)
            )
            let expected = try referenceJSON(entry)
            let actual = JSONLogFormatter().format(entry)
            if actual != expected {
                mismatches.append("#\(index): \(actual) != \(expected)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(3))")
    }

    private func referenceJSON(_ entry: LogEntry) throws -> String {
        let object: [String: Any] = [
            "timestamp": DateFormatterCache.string(from: entry.date, format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                                                   timeZone: TimeZone(identifier: "UTC")!),
            "level": entry.level.name,
            "levelValue": entry.level.rawValue,
            "message": entry.message,
            "subsystem": entry.subsystem,
            "category": entry.category,
            "file": entry.fileName,
            "line": entry.line,
            "class": entry.className,
            "function": entry.function,
            "threadID": entry.threadID,
            "threadName": entry.threadName,
            "isMainThread": entry.isMainThread,
            "pid": entry.processID,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func testKeysAreSorted() {
        let line = JSONLogFormatter().format(makeEntry())
        XCTAssertTrue(line.hasPrefix("{\"category\":"))
    }
}
