import AppKit
import XCTest
@testable import SwiftOSLogger

final class FileDestinationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory(self)
    }

    private func makeConfiguration(
        maxFileSize: Int? = nil,
        maxLinesPerFile: Int? = nil,
        maxFileCount: Int? = nil,
        flushLevel: LogLevel = .error,
        flushOnAppLifecycle: Bool = false
    ) -> FileDestinationConfiguration {
        FileDestinationConfiguration(
            directory: directory,
            maxFileSize: maxFileSize,
            maxLinesPerFile: maxLinesPerFile,
            maxFileCount: maxFileCount,
            flushLevel: flushLevel,
            flushOnAppLifecycle: flushOnAppLifecycle
        )
    }

    func testDefaults() throws {
        let destination = try FileDestination(configuration: makeConfiguration())
        XCTAssertEqual(destination.minLevel, .trace)
        XCTAssertTrue(destination.formatter is TextLogFormatter)

        let defaults = FileDestinationConfiguration()
        XCTAssertEqual(defaults.directory.lastPathComponent, "Logs")
        XCTAssertEqual(defaults.fileNamePrefix, "log")
        XCTAssertEqual(defaults.fileExtension, "log")
        XCTAssertEqual(defaults.maxFileSize, 5 * 1024 * 1024)
        XCTAssertNil(defaults.maxLinesPerFile)
        XCTAssertEqual(defaults.maxFileCount, 10)
        XCTAssertFalse(defaults.newFilePerLaunch)
        XCTAssertTrue(defaults.includeHeader)
        XCTAssertEqual(defaults.bufferSize, 32 * 1024)
        XCTAssertEqual(defaults.flushLevel, .error)
        XCTAssertTrue(defaults.flushOnAppLifecycle)
    }

    func testLoggerWritesFormattedEntriesToFile() throws {
        let destination = try FileDestination(configuration: makeConfiguration())
        let logger = OSLogger(subsystem: "com.acme.app", category: "Files",
                              configuration: LoggerConfiguration(minLevel: .trace, destinations: [destination]))

        logger.info("hello file"); let line = #line
        logger.flush()

        let url = try XCTUnwrap(destination.currentLogFileURL)
        let body = try bodyLines(url)
        XCTAssertEqual(body.count, 1)
        XCTAssertTrue(body[0].hasSuffix(
            "[INFO] [main:0x\(String(ThreadInfo.currentThreadID, radix: 16))] [Files] FileDestinationTests.swift:\(line) "
                + "FileDestinationTests.testLoggerWritesFormattedEntriesToFile() - hello file"), body[0])
    }

    func testEntriesAreBufferedUntilFlush() throws {
        let destination = try FileDestination(configuration: makeConfiguration())
        destination.write(makeEntry(level: .info), formatted: "buffered")
        let url = try XCTUnwrap(destination.currentLogFileURL)   // sync on queue: append has run
        XCTAssertEqual(try bodyLines(url), [])

        destination.flush()
        XCTAssertEqual(try bodyLines(url), ["buffered"])
    }

    func testFlushLevelWritesImmediately() throws {
        let destination = try FileDestination(configuration: makeConfiguration(flushLevel: .warning))
        destination.write(makeEntry(level: .info), formatted: "info")
        destination.write(makeEntry(level: .warning), formatted: "warning")
        let url = try XCTUnwrap(destination.currentLogFileURL)
        XCTAssertEqual(try bodyLines(url), ["info", "warning"])
    }

    func testLogFileURLsFlushesAndDeleteAllRemovesFiles() throws {
        let destination = try FileDestination(configuration: makeConfiguration(maxLinesPerFile: 1))
        destination.write(makeEntry(), formatted: "a")
        destination.write(makeEntry(), formatted: "b")

        let files = destination.logFileURLs()
        XCTAssertEqual(try files.map { try bodyLines($0) }, [["a"], ["b"]])

        destination.deleteAllLogFiles()
        XCTAssertEqual(destination.logFileURLs(), [])
        XCTAssertNil(destination.currentLogFileURL)
    }

    func testFlushesOnAppTermination() throws {
        let destination = try FileDestination(configuration: makeConfiguration(flushOnAppLifecycle: true))
        destination.write(makeEntry(level: .info), formatted: "before exit")
        let url = try XCTUnwrap(destination.currentLogFileURL)
        XCTAssertEqual(try bodyLines(url), [])

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(try bodyLines(url), ["before exit"])
    }

    func testReportsErrorThenDisablesAfterRepeatedFailure() throws {
        let reported = expectation(description: "error reported")
        reported.assertForOverFulfill = false
        let destination = try FileDestination(configuration: makeConfiguration(), onInternalError: { error in
            if case FileDestinationError.cannotCreateFile = error { reported.fulfill() }
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        destination.write(makeEntry(), formatted: "fails once")
        destination.write(makeEntry(), formatted: "fails twice -> disabled")
        wait(for: [reported], timeout: 5)
        _ = destination.currentLogFileURL   // wait for both writes to run before restoring permissions

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        destination.write(makeEntry(level: .critical), formatted: "ignored")
        XCTAssertNil(destination.currentLogFileURL)
        XCTAssertEqual(destination.logFileURLs(), [])
    }

    func testConcurrentLoggingWithRotationKeepsEveryLineIntact() throws {
        let destination = try FileDestination(configuration: makeConfiguration(maxFileSize: 16 * 1024))
        let logger = OSLogger(subsystem: "com.acme.app", category: "Stress",
                              configuration: LoggerConfiguration(minLevel: .trace, destinations: [destination]))

        DispatchQueue.concurrentPerform(iterations: 10) { thread in
            for i in 0..<1_000 {
                logger.info("message-\(thread)-\(i)-end")
            }
        }
        logger.flush()

        let files = destination.logFileURLs()
        XCTAssertGreaterThan(files.count, 1, "expected rotation")
        let lines = try files.flatMap { try bodyLines($0) }
        XCTAssertEqual(lines.count, 10_000)
        XCTAssertTrue(lines.allSatisfy { $0.range(of: #" - message-\d-\d+-end$"#, options: .regularExpression) != nil })
        XCTAssertEqual(Set(lines.map { $0.components(separatedBy: " - ").last! }).count, 10_000)
    }
}
