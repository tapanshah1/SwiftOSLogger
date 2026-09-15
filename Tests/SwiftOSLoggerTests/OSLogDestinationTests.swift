import OSLog
import XCTest
@testable import SwiftOSLogger

final class OSLogDestinationTests: XCTestCase {
    func testDefaults() {
        let destination = OSLogDestination()
        XCTAssertEqual(destination.minLevel, .trace)
        XCTAssertEqual(destination.privacy, .public)
        XCTAssertTrue(destination.formatter is TextLogFormatter)
    }

    func testCachesOneLoggerPerSubsystemAndCategory() {
        let cache = OSLoggerCache()
        _ = cache.logger(subsystem: "a", category: "x")
        _ = cache.logger(subsystem: "a", category: "x")
        _ = cache.logger(subsystem: "a", category: "y")
        XCTAssertEqual(cache.count, 2)
    }

    func testEntriesReachUnifiedLogging() throws {
        let marker = "SwiftOSLogger-test-\(UUID().uuidString)"
        let destination = OSLogDestination()
        let entry = makeEntry(level: .error, message: marker)

        destination.write(entry, formatted: destination.formatter.format(entry))

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-60))
        let predicate = NSPredicate(format: "subsystem == %@", "com.acme.app")
        let matches = try store.getEntries(at: position, matching: predicate)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.composedMessage.contains(marker) }

        let logged = try XCTUnwrap(matches.first)
        XCTAssertEqual(logged.category, "Network")
        XCTAssertEqual(logged.level, .error)
        XCTAssertEqual(logged.composedMessage, "[main:0x1a2b] NetworkManager.swift:42 NetworkManager.fetch(_:) - \(marker)")
    }
}
