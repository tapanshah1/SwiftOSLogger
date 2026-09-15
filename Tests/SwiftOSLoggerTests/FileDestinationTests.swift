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
        XCTAssertEqual(defaults.maxPendingBytes, 4 * 1024 * 1024)
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

    func testPersistentWriteFailuresDisableDestinationDespiteBufferedAppends() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
            func increment() { lock.lock(); defer { lock.unlock() }; _value += 1 }
        }
        let writeAttempts = Counter()
        let reported = expectation(description: "write error reported")
        reported.assertForOverFulfill = false

        // Each "entry-NN\n" is 9 bytes, so every 8th append fills the 64-byte buffer and writes.
        let configuration = FileDestinationConfiguration(directory: directory, maxFileSize: nil, maxFileCount: nil,
                                                         bufferSize: 64, flushLevel: .critical, flushOnAppLifecycle: false)
        let manager = try LogFileManager(configuration: configuration)
        manager.writeData = { _, _ in
            writeAttempts.increment()
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let destination = FileDestination(manager: manager, onInternalError: { error in
            if (error as? CocoaError)?.code == .fileWriteOutOfSpace { reported.fulfill() }
        })

        for i in 0..<8 {
            destination.write(makeEntry(), formatted: String(format: "entry-%02d", i))
        }
        destination.flush()   // empty buffer after the first failure: must not reset the failure count
        for i in 8..<100 {
            destination.write(makeEntry(), formatted: String(format: "entry-%02d", i))
        }
        wait(for: [reported], timeout: 5)

        XCTAssertNil(destination.currentLogFileURL, "destination should be disabled")
        XCTAssertEqual(writeAttempts.value, 2)
        destination.write(makeEntry(level: .critical), formatted: "ignored")
        XCTAssertNil(destination.currentLogFileURL)
        XCTAssertEqual(writeAttempts.value, 2)
    }

    func testErrorHandlerCanCallBackIntoDestination() throws {
        final class Holder: @unchecked Sendable { weak var destination: FileDestination? }
        let holder = Holder()
        let calledBack = expectation(description: "handler called back into the destination")
        calledBack.assertForOverFulfill = false
        let destination = try FileDestination(configuration: makeConfiguration(), onInternalError: { _ in
            holder.destination?.flush()
            _ = holder.destination?.logFileURLs()
            _ = holder.destination?.currentLogFileURL
            calledBack.fulfill()
        })
        holder.destination = destination
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        destination.write(makeEntry(), formatted: "fails")
        wait(for: [calledBack], timeout: 5)
    }

    func testEntriesBeyondPendingLimitAreDroppedAndReported() throws {
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; defer { done = true }; return !done }
        }
        let firstWrite = Once()

        // Each "entry-NN\n" is 9 bytes, so 45 pending bytes hold exactly 5 entries.
        let configuration = FileDestinationConfiguration(directory: directory, maxFileSize: nil, maxFileCount: nil,
                                                         bufferSize: 0, maxPendingBytes: 45, flushLevel: .critical,
                                                         flushOnAppLifecycle: false)
        let manager = try LogFileManager(configuration: configuration)
        manager.writeData = { handle, data in
            if firstWrite.take() {
                writeStarted.signal()
                releaseWrite.wait()   // stall the disk writer so entries pile up
            }
            try handle.write(contentsOf: data)
        }
        let destination = FileDestination(manager: manager)

        destination.write(makeEntry(), formatted: "entry-00")
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 5), .success)
        for i in 1...20 {
            destination.write(makeEntry(), formatted: String(format: "entry-%02d", i))
        }
        releaseWrite.signal()
        destination.flush()

        let url = try XCTUnwrap(destination.currentLogFileURL)
        XCTAssertEqual(try bodyLines(url), ["entry-00", "entry-01", "entry-02", "entry-03", "entry-04", "entry-05"])
        let lines = try readLines(url)
        XCTAssertEqual(lines.last, "# SwiftOSLogger dropped 15 entries: more than 45 bytes were waiting to be written")
    }

    func testSingleEntryLargerThanPendingLimitIsStillWritten() throws {
        let configuration = FileDestinationConfiguration(directory: directory, maxPendingBytes: 10, flushOnAppLifecycle: false)
        let destination = try FileDestination(configuration: configuration)
        let large = String(repeating: "x", count: 50)

        destination.write(makeEntry(), formatted: large)
        destination.flush()

        XCTAssertEqual(try bodyLines(XCTUnwrap(destination.currentLogFileURL)), [large])
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
