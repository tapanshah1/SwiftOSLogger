import XCTest
@testable import SwiftOSLogger

final class LogFileManagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory(self)
    }

    private func makeConfiguration(
        maxFileSize: Int? = nil,
        maxLinesPerFile: Int? = nil,
        maxFileCount: Int? = nil,
        newFilePerLaunch: Bool = false,
        includeHeader: Bool = true,
        bufferSize: Int = 0
    ) -> FileDestinationConfiguration {
        FileDestinationConfiguration(
            directory: directory,
            maxFileSize: maxFileSize,
            maxLinesPerFile: maxLinesPerFile,
            maxFileCount: maxFileCount,
            newFilePerLaunch: newFilePerLaunch,
            includeHeader: includeHeader,
            bufferSize: bufferSize,
            flushOnAppLifecycle: false
        )
    }

    func testCreatesDirectoryAndFileWithHeaderOnFirstAppend() throws {
        let nested = directory.appendingPathComponent("a/b", isDirectory: true)
        var configuration = makeConfiguration()
        configuration.directory = nested
        let manager = try LogFileManager(configuration: configuration)
        XCTAssertNil(manager.currentFileURL)

        try manager.append("first", flushImmediately: true)

        let url = try XCTUnwrap(manager.currentFileURL)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "b")
        XCTAssertTrue(url.lastPathComponent.range(of: #"^log_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}\.log$"#,
                                                  options: .regularExpression) != nil, url.lastPathComponent)
        let lines = try readLines(url)
        XCTAssertEqual(lines.first, "# ==================== SwiftOSLogger Log File ====================")
        XCTAssertTrue(lines.contains { $0.hasPrefix("# PID:") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("# File Index:") && $0.hasSuffix(" 1") })
        XCTAssertEqual(try bodyLines(url), ["first"])
    }

    func testNoHeaderWhenDisabled() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(includeHeader: false))
        try manager.append("only", flushImmediately: true)
        XCTAssertEqual(try readLines(XCTUnwrap(manager.currentFileURL)), ["only"])
    }

    func testBuffersUntilFlush() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(bufferSize: 1024))
        try manager.append("buffered", flushImmediately: false)
        let url = try XCTUnwrap(manager.currentFileURL)
        XCTAssertEqual(try bodyLines(url), [])

        try manager.flush()
        XCTAssertEqual(try bodyLines(url), ["buffered"])
    }

    func testBufferIsWrittenWhenFull() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(bufferSize: 10))
        try manager.append("12345", flushImmediately: false)   // 6 bytes buffered
        let url = try XCTUnwrap(manager.currentFileURL)
        XCTAssertEqual(try bodyLines(url), [])
        try manager.append("67890", flushImmediately: false)   // 12 bytes >= 10
        XCTAssertEqual(try bodyLines(url), ["12345", "67890"])
    }

    func testRotatesByLineCountExcludingHeader() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(maxLinesPerFile: 3))
        for i in 1...7 {
            try manager.append("line \(i)", flushImmediately: false)
        }
        try manager.flush()

        let files = manager.logFileURLs()
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(try files.map { try bodyLines($0) }, [
            ["line 1", "line 2", "line 3"],
            ["line 4", "line 5", "line 6"],
            ["line 7"],
        ])
        XCTAssertEqual(files.last, manager.currentFileURL)
        XCTAssertTrue(try readLines(files[1]).contains { $0.hasPrefix("# File Index:") && $0.hasSuffix(" 2") })
    }

    func testRotatesBySize() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(maxFileSize: 100, includeHeader: false))
        let line = String(repeating: "x", count: 29)   // 30 bytes with newline
        for _ in 0..<7 {
            try manager.append(line, flushImmediately: false)
        }
        try manager.flush()

        let files = manager.logFileURLs()
        XCTAssertEqual(try files.map { try bodyLines($0).count }, [3, 3, 1])
        for file in files {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
            XCTAssertLessThanOrEqual(size, 100)
        }
    }

    func testOversizedLineGetsItsOwnFile() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(maxFileSize: 20, includeHeader: false))
        try manager.append("short", flushImmediately: false)
        try manager.append(String(repeating: "y", count: 50), flushImmediately: false)
        try manager.append("after", flushImmediately: false)
        try manager.flush()

        XCTAssertEqual(try manager.logFileURLs().map { try bodyLines($0) }, [
            ["short"],
            [String(repeating: "y", count: 50)],
            ["after"],
        ])
    }

    func testMaxFileCountDeletesOldestFiles() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(maxLinesPerFile: 1, maxFileCount: 3))
        for i in 1...6 {
            try manager.append("line \(i)", flushImmediately: true)
        }

        let files = manager.logFileURLs()
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(try files.map { try bodyLines($0) }, [["line 4"], ["line 5"], ["line 6"]])
        XCTAssertEqual(files.last, manager.currentFileURL)
    }

    func testMaxFileCountOfOneKeepsCurrentFile() throws {
        let manager = try LogFileManager(configuration: makeConfiguration(maxLinesPerFile: 1, maxFileCount: 1))
        try manager.append("a", flushImmediately: true)
        try manager.append("b", flushImmediately: true)
        XCTAssertEqual(manager.logFileURLs(), [manager.currentFileURL])
        XCTAssertEqual(try bodyLines(XCTUnwrap(manager.currentFileURL)), ["b"])
    }

    func testAppendsToLatestFileOnRelaunchWhenUnderLimits() throws {
        let configuration = makeConfiguration(maxLinesPerFile: 3)
        do {
            let first = try LogFileManager(configuration: configuration)
            try first.append("one", flushImmediately: false)
            try first.append("two", flushImmediately: false)
            try first.close()
        }

        let second = try LogFileManager(configuration: configuration)
        try second.append("three", flushImmediately: false)   // fills the reopened file
        try second.append("four", flushImmediately: false)    // rotates: restored count was 2
        try second.flush()

        let files = second.logFileURLs()
        XCTAssertEqual(try files.map { try bodyLines($0) }, [["one", "two", "three"], ["four"]])
        XCTAssertEqual(try readLines(files[0]).filter { $0.hasPrefix("# ====") }.count, 2, "no second header")
    }

    func testDoesNotReopenFullFile() throws {
        let configuration = makeConfiguration(maxLinesPerFile: 2)
        do {
            let first = try LogFileManager(configuration: configuration)
            try first.append("one", flushImmediately: false)
            try first.append("two", flushImmediately: false)
            try first.close()
        }
        let second = try LogFileManager(configuration: configuration)
        try second.append("three", flushImmediately: true)
        XCTAssertEqual(try second.logFileURLs().map { try bodyLines($0) }, [["one", "two"], ["three"]])
    }

    func testNewFilePerLaunch() throws {
        var configuration = makeConfiguration()
        do {
            let first = try LogFileManager(configuration: configuration)
            try first.append("one", flushImmediately: true)
            try first.close()
        }
        configuration.newFilePerLaunch = true
        let second = try LogFileManager(configuration: configuration)
        try second.append("two", flushImmediately: true)
        XCTAssertEqual(try second.logFileURLs().map { try bodyLines($0) }, [["one"], ["two"]])
    }

    func testDeleteAllLogFilesStartsFreshFile() throws {
        let manager = try LogFileManager(configuration: makeConfiguration())
        try manager.append("old", flushImmediately: true)
        manager.deleteAllLogFiles()
        XCTAssertEqual(manager.logFileURLs(), [])
        XCTAssertNil(manager.currentFileURL)

        try manager.append("new", flushImmediately: true)
        XCTAssertEqual(try manager.logFileURLs().map { try bodyLines($0) }, [["new"]])
    }

    func testListingIgnoresOtherFilesAndSortsSequenceNumbers() throws {
        let names = [
            "log_2026-09-15_08-00-00-000_10.log",
            "log_2026-09-15_08-00-00-000.log",
            "log_2026-09-15_08-00-00-000_2.log",
            "log_2026-09-14_23-59-59-999.log",
            "log_app_2026-09-15_08-00-00-000.log",
            "log_2026-09-15_08-00-00-000.txt",
            "notes.log",
        ]
        for name in names {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }
        XCTAssertEqual(
            LogFileManager.logFileURLs(in: directory, prefix: "log", fileExtension: "log").map(\.lastPathComponent),
            [
                "log_2026-09-14_23-59-59-999.log",
                "log_2026-09-15_08-00-00-000.log",
                "log_2026-09-15_08-00-00-000_2.log",
                "log_2026-09-15_08-00-00-000_10.log",
            ]
        )
    }

    func testThrowsWhenDirectoryCannotBeCreated() throws {
        let blocker = directory.appendingPathComponent("file")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        var configuration = makeConfiguration()
        configuration.directory = blocker.appendingPathComponent("logs")

        XCTAssertThrowsError(try LogFileManager(configuration: configuration)) { error in
            guard case FileDestinationError.cannotCreateDirectory(let url, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(url, configuration.directory)
        }
    }
}
