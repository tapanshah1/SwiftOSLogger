import XCTest
@testable import SwiftOSLogger

final class FastDateFormatTests: XCTestCase {
    private let formats = [
        "yyyy-MM-dd HH:mm:ss.SSS Z",          // TextLogFormatter default, header
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",     // JSONLogFormatter
        "yyyy-MM-dd_HH-mm-ss-SSS",            // log file names
        "HH:mm:ss.SSS",
        "HH:mm:ss",
    ]

    private let timeZones = [
        "UTC", "Asia/Kolkata", "America/Los_Angeles", "Europe/London", "Australia/Lord_Howe",
        "Asia/Kathmandu", "America/St_Johns", "Pacific/Chatham", "Pacific/Kiritimati", "Pacific/Pago_Pago",
    ].map { TimeZone(identifier: $0)! } + [TimeZone.current, TimeZone(secondsFromGMT: 19_800)!]

    private func referenceFormatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        formatter.timeZone = timeZone
        return formatter
    }

    /// Deterministic dates: random instants in 1970...2100 plus millisecond and DST edges.
    private func sampleDates() -> [Date] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var dates: [Date] = []
        for _ in 0..<2_000 {
            let seconds = Double(next() % 4_102_444_800)             // 1970-01-01 ..< 2100-01-01
            let fraction = Double(next() % 1_000_000) / 1_000_000
            dates.append(Date(timeIntervalSince1970: seconds + fraction))
        }
        let edges: [TimeInterval] = [
            0, 0.0004, 0.0005, 0.9994, 0.9995, 0.9999, 59.9999,
            1_789_460_112.347, 1_789_460_112.3469, 1_789_460_112.9996,
            951_782_400.5,                                            // 2000-02-29
            4_102_444_799.999,                                        // 2099-12-31 23:59:59.999
            1_772_964_000 - 0.001, 1_772_964_000, 1_772_964_000 + 0.001, // US DST start 2026-03-08 10:00 UTC
            1_793_523_600 - 0.001, 1_793_523_600, 1_793_523_600 + 0.001, // US DST end 2026-11-01 09:00 UTC
        ]
        dates += edges.map { Date(timeIntervalSince1970: $0) }
        dates.append(Date())
        return dates
    }

    func testMatchesDateFormatterForSupportedPatterns() {
        var mismatches: [String] = []
        let dates = sampleDates()
        for format in formats {
            for timeZone in timeZones {
                let formatter = referenceFormatter(format, timeZone)
                for date in dates {
                    let expected = formatter.string(from: date)
                    guard let fast = FastDateFormat.string(from: date, format: format, timeZone: timeZone) else {
                        mismatches.append("no fast path: \(format) \(timeZone.identifier) \(date.timeIntervalSince1970)")
                        continue
                    }
                    if fast != expected {
                        mismatches.append("\(format) \(timeZone.identifier) \(date.timeIntervalSince1970): \(fast) != \(expected)")
                    }
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(5))")
    }

    func testUnsupportedPatternsAndDatesFallBack() {
        let date = Date(timeIntervalSince1970: 1_789_460_112.347)
        XCTAssertNil(FastDateFormat.string(from: date, format: "EEE, d MMM yyyy", timeZone: .current))
        XCTAssertNil(FastDateFormat.string(from: date, format: "yy-MM-dd", timeZone: .current))
        XCTAssertNil(FastDateFormat.string(from: date, format: "h:mm a", timeZone: .current))
        XCTAssertNil(FastDateFormat.string(from: Date(timeIntervalSince1970: -5_000_000_000), format: "yyyy", timeZone: .current))
        XCTAssertNil(FastDateFormat.string(from: date, format: "yyyy", timeZone: TimeZone(secondsFromGMT: 19_830)!))
    }

    func testDateFormatterCacheUsesFastPathOutputAndFallsBack() {
        let date = Date(timeIntervalSince1970: 1_789_460_112.347)
        let ist = TimeZone(secondsFromGMT: 19_800)!
        XCTAssertEqual(DateFormatterCache.string(from: date, format: "yyyy-MM-dd HH:mm:ss.SSS Z", timeZone: ist),
                       "2026-09-15 13:45:12.347 +0530")
        XCTAssertEqual(DateFormatterCache.string(from: date, format: "EEE, d MMM yyyy", timeZone: ist),
                       "Tue, 15 Sep 2026")
    }
}
