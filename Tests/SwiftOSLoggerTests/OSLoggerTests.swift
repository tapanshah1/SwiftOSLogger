import XCTest
@testable import SwiftOSLogger

private let loggableTestLogger = OSLogger(subsystem: "tests", category: "Base",
                                          configuration: LoggerConfiguration(destinations: []))

private final class PaymentService: Loggable {
    static var baseLogger: OSLogger { loggableTestLogger }
    func charge() { log.info("charging") }
}

private struct Uploader: Loggable {
    static var baseLogger: OSLogger { loggableTestLogger }
    static var logCategory: String { "Uploads" }
    func start() { log.debug("start") }
}

final class OSLoggerTests: XCTestCase {
    private func makeLogger(minLevel: LogLevel = .trace, destinations: [any LogDestination]) -> OSLogger {
        OSLogger(subsystem: "com.acme.app", category: "Network",
                 configuration: LoggerConfiguration(minLevel: minLevel, destinations: destinations))
    }

    func testCapturesCallSiteMetadata() throws {
        let memory = MemoryDestination()
        let logger = makeLogger(destinations: [memory])

        logger.info("hello"); let expectedLine = #line

        let entry = try XCTUnwrap(memory.entries.first)
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "hello")
        XCTAssertEqual(entry.subsystem, "com.acme.app")
        XCTAssertEqual(entry.category, "Network")
        XCTAssertEqual(entry.fileID, "SwiftOSLoggerTests/OSLoggerTests.swift")
        XCTAssertEqual(entry.fileName, "OSLoggerTests.swift")
        XCTAssertTrue(entry.filePath.hasSuffix("Tests/SwiftOSLoggerTests/OSLoggerTests.swift"))
        XCTAssertEqual(entry.function, "testCapturesCallSiteMetadata()")
        XCTAssertEqual(entry.line, expectedLine)
        XCTAssertEqual(entry.className, "OSLoggerTests")
        XCTAssertNotEqual(entry.threadID, 0)
        XCTAssertEqual(entry.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertLessThan(abs(entry.date.timeIntervalSinceNow), 5)
    }

    func testMainThreadMetadata() throws {
        let memory = MemoryDestination()
        makeLogger(destinations: [memory]).info("main")
        let entry = try XCTUnwrap(memory.entries.first)
        XCTAssertTrue(entry.isMainThread)
        XCTAssertEqual(entry.threadName, "main")
    }

    func testBackgroundQueueMetadata() throws {
        let memory = MemoryDestination()
        let logger = makeLogger(destinations: [memory])
        let done = expectation(description: "logged")
        DispatchQueue(label: "com.acme.worker").async {
            logger.info("bg")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let entry = try XCTUnwrap(memory.entries.first)
        XCTAssertFalse(entry.isMainThread)
        XCTAssertEqual(entry.threadName, "com.acme.worker")
    }

    func testConvenienceMethodsUseMatchingLevels() {
        let memory = MemoryDestination()
        let logger = makeLogger(destinations: [memory])
        logger.trace("t"); logger.debug("d"); logger.info("i"); logger.notice("n")
        logger.warning("w"); logger.error("e"); logger.critical("c")
        XCTAssertEqual(memory.entries.map(\.level), [.trace, .debug, .info, .notice, .warning, .error, .critical])
    }

    func testMinLevelFiltersAndSkipsMessageEvaluation() {
        let memory = MemoryDestination()
        let logger = makeLogger(minLevel: .warning, destinations: [memory])
        var evaluated = false
        func expensive() -> String { evaluated = true; return "x" }

        logger.info(expensive())
        XCTAssertFalse(evaluated)
        XCTAssertTrue(memory.entries.isEmpty)

        logger.error(expensive())
        XCTAssertTrue(evaluated)
        XCTAssertEqual(memory.entries.count, 1)
    }

    func testPerDestinationMinLevel() {
        let all = MemoryDestination(minLevel: .trace)
        let errorsOnly = MemoryDestination(minLevel: .error)
        let logger = makeLogger(destinations: [all, errorsOnly])
        var evaluations = 0
        func counted() -> String { evaluations += 1; return "x" }

        logger.debug("debug")
        logger.error("error")
        XCTAssertEqual(all.entries.count, 2)
        XCTAssertEqual(errorsOnly.entries.map(\.message), ["error"])

        let onlyErrors = makeLogger(destinations: [errorsOnly])
        onlyErrors.info(counted())
        XCTAssertEqual(evaluations, 0, "message must not be built when no destination accepts the level")
    }

    func testOffDisablesLogging() {
        let memory = MemoryDestination()
        let logger = makeLogger(minLevel: .off, destinations: [memory])
        logger.critical("nope")
        XCTAssertTrue(memory.entries.isEmpty)
    }

    func testUsesDestinationFormatter() {
        let memory = MemoryDestination(formatter: TextLogFormatter(includeDate: false, includeThread: false,
                                                                   includeFileAndLine: false))
        makeLogger(destinations: [memory]).warning("careful")
        XCTAssertEqual(memory.lines, ["[WARNING] [Network] OSLoggerTests.testUsesDestinationFormatter() - careful"])
    }

    func testClassNameResolutionOrder() {
        let memory = MemoryDestination()
        let logger = makeLogger(destinations: [memory])

        logger.info("file")                                           // 3. file name
        logger.bound(to: PaymentService.self).info("bound")           // 2. bound type
        logger.bound(to: PaymentService.self).info("explicit", type: Uploader.self) // 1. explicit

        XCTAssertEqual(memory.entries.map(\.className), ["OSLoggerTests", "PaymentService", "Uploader"])
    }

    func testDerivedLoggersShareConfiguration() {
        let first = MemoryDestination()
        let second = MemoryDestination()
        let parent = makeLogger(destinations: [first])
        let child = parent.withCategory("DB")

        XCTAssertEqual(child.category, "DB")
        XCTAssertEqual(child.subsystem, "com.acme.app")

        child.configure { $0.destinations = [second] }
        parent.info("from parent")
        child.info("from child")

        XCTAssertTrue(first.entries.isEmpty)
        XCTAssertEqual(second.entries.map(\.category), ["Network", "DB"])
    }

    func testConfigurationSetterReplacesConfiguration() {
        let memory = MemoryDestination()
        let logger = makeLogger(destinations: [])
        logger.configuration = LoggerConfiguration(minLevel: .error, destinations: [memory])
        logger.warning("dropped")
        logger.error("kept")
        XCTAssertEqual(memory.entries.map(\.message), ["kept"])
        XCTAssertEqual(logger.configuration.minLevel, .error)
    }

    func testConfigureClosureCanLogAndReadConfiguration() {
        let memory = MemoryDestination()
        let logger = makeLogger(destinations: [memory])
        let child = logger.withCategory("Child")

        logger.configure { configuration in
            logger.info("inside configure")
            child.debug("child inside configure")
            XCTAssertEqual(logger.configuration.minLevel, .trace)   // the value before this update
            configuration.minLevel = .warning
        }

        XCTAssertEqual(logger.configuration.minLevel, .warning)
        logger.info("filtered after configure")
        XCTAssertEqual(memory.lines.map { $0.components(separatedBy: " - ").last! },
                       ["inside configure", "child inside configure"])
    }

    func testFlushFlushesEveryDestination() {
        let a = MemoryDestination()
        let b = MemoryDestination()
        makeLogger(destinations: [a, b]).flush()
        XCTAssertEqual(a.flushCount, 1)
        XCTAssertEqual(b.flushCount, 1)
    }

    func testLoggableUsesTypeNameForClassAndCategory() {
        let memory = MemoryDestination()
        loggableTestLogger.configure { $0.minLevel = .trace; $0.destinations = [memory] }
        defer { loggableTestLogger.configure { $0.destinations = [] } }

        PaymentService().charge()
        Uploader().start()
        Uploader.log.error("static")

        XCTAssertEqual(memory.entries.map(\.className), ["PaymentService", "Uploader", "Uploader"])
        XCTAssertEqual(memory.entries.map(\.category), ["PaymentService", "Uploads", "Uploads"])
        XCTAssertEqual(memory.entries.map(\.function), ["charge()", "start()", "testLoggableUsesTypeNameForClassAndCategory()"])
    }

    func testConcurrentLoggingDeliversEveryEntry() {
        let memory = MemoryDestination()
        let logger = makeLogger(destinations: [memory])
        DispatchQueue.concurrentPerform(iterations: 1_000) { i in
            logger.info("entry \(i)")
            if i % 100 == 0 { logger.configure { $0.minLevel = .trace } }
        }
        XCTAssertEqual(memory.entries.count, 1_000)
    }
}
