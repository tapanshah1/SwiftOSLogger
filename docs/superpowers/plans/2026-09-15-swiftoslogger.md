# SwiftOSLogger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `SwiftOSLogger`, a public Swift package that logs through `os.Logger`, the console and rotating files, with rich call-site metadata and per-file headers, distributable via SPM and as an XCFramework.

**Architecture:** One `OSLogger` front end captures call-site metadata into a `LogEntry`, filters by level, and hands the entry to a list of `LogDestination`s. Each destination has its own minimum level and `LogFormatter`. `FileDestination` confines a `LogFileManager` (naming, header, buffering, rotation, cleanup) to a private serial queue.

**Tech Stack:** Swift 5.9+ (tested with Swift 6.2 / Xcode 26), Foundation, `os` (`Logger`, `OSLogStore` in tests), XCTest, `xcodebuild`, bash.

**Spec:** `docs/superpowers/specs/2026-09-15-swiftoslogger-design.md`

## Global Constraints

- Module/product name: `SwiftOSLogger`; the only library product is `.library(name: "SwiftOSLogger", targets: ["SwiftOSLogger"])`.
- `swift-tools-version: 5.9`; platforms `.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)`.
- No third-party dependencies. The library target enables `StrictConcurrency`.
- APIs must be available on iOS 15. Do not use `OSAllocatedUnfairLock` (iOS 16), `nonisolated(unsafe)` (Swift 5.10), or `Thread.current` (unavailable in async contexts).
- The code must build with zero warnings, including under `-swift-version 6`.
- `log(...)` never throws, never crashes, and never blocks on disk I/O.
- `FileDestination` writes run on a private serial queue. `flush()`, `currentLogFileURL`, `logFileURLs()` and `deleteAllLogFiles()` use `queue.sync`.
- Tests use XCTest and run on macOS with `swift test` from the repository root.
- Commit messages end with the line `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` (omitted from the commit commands below for brevity; add it).

## Decisions made while prototyping (update the spec in Task 10)

Every code block in this plan was compiled and its tests run (60 tests passing on macOS; typechecked for iOS, watchOS, tvOS and visionOS in Swift 6 mode) before the plan was written. Differences from the spec:

1. **XCFramework is static, with no `SwiftOSLoggerDynamic` product.** An SPM dynamic product archives as `SwiftOSLoggerDynamic.framework`, which doesn't match the module name. The script instead archives the normal scheme and assembles a static `SwiftOSLogger.framework` from the archived `SwiftOSLogger.o` plus its `.swiftinterface` files. It adds a `maccatalyst` slice.
2. **Log file names use UTC timestamps**, so name order stays chronological across time zone and DST changes. The header's `File Created` line stays in local time.
3. **`Loggable` has a `static var baseLogger: OSLogger`** (default `.shared`), so types can derive from a non-shared logger. Tests rely on it.
4. **`DateFormatterCache`** is a new internal file (`Support/DateFormatterCache.swift`) shared by the text formatter, the JSON formatter, the header and file naming.
5. **`FileDestinationError`** lives in `File/LogFileManager.swift`.
6. **A successful `flush` doesn't reset the failure counter.** Only a successful append does, so a flush with nothing to write can't hide a failing file.

## File Structure

```
Package.swift                                   Task 1
.gitignore                                      Task 1
Sources/SwiftOSLogger/
  Support/Lock.swift                            Task 1  os_unfair_lock wrapper
  Support/Version.swift                         Task 1  SwiftOSLoggerVersion.current
  Core/LogLevel.swift                           Task 1  levels + OSLogType mapping
  Core/LogEntry.swift                           Task 2  captured metadata
  Formatting/LogFormatter.swift                 Task 2  protocol
  Support/DateFormatterCache.swift              Task 2  thread-safe formatter cache
  Formatting/TextLogFormatter.swift             Task 2  default line format
  Formatting/JSONLogFormatter.swift             Task 3  JSON Lines
  Destinations/LogDestination.swift             Task 4  protocol
  Destinations/OSLogDestination.swift           Task 4  os.Logger output
  Destinations/ConsoleDestination.swift         Task 4  stdout/stderr output
  Support/ThreadInfo.swift                      Task 5  thread id/name
  Core/LoggerConfiguration.swift                Task 5  minLevel + destinations
  Core/OSLogger.swift                           Task 5  public logging API
  Core/Loggable.swift                           Task 5  type-bound `log`
  Support/AppInfo.swift                         Task 6  app/process/device info
  File/FileDestinationConfiguration.swift       Task 6  file options
  File/LogFileHeader.swift                      Task 6  header text
  File/LogFileManager.swift                     Task 7  naming, buffering, rotation
  Destinations/FileDestination.swift            Task 8  queue, errors, lifecycle
scripts/build-xcframework.sh                    Task 9
README.md                                       Task 10
Tests/SwiftOSLoggerTests/
  LogLevelTests.swift                           Task 1
  TestSupport.swift                             Task 2  makeEntry()
  TextLogFormatterTests.swift                   Task 2
  JSONLogFormatterTests.swift                   Task 3
  OSLogDestinationTests.swift                   Task 4
  ConsoleDestinationTests.swift                 Task 4
  MemoryDestination.swift                       Task 5  recording test double
  OSLoggerTests.swift                           Task 5
  FileTestSupport.swift                         Task 6  temp dirs, reading files
  LogFileHeaderTests.swift                      Task 6
  LogFileManagerTests.swift                     Task 7
  FileDestinationTests.swift                    Task 8
```

---

### Task 1: Package scaffold, lock and log levels

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/SwiftOSLogger/Support/Lock.swift`
- Create: `Sources/SwiftOSLogger/Support/Version.swift`
- Create: `Sources/SwiftOSLogger/Core/LogLevel.swift`
- Test: `Tests/SwiftOSLoggerTests/LogLevelTests.swift`

**Interfaces:**
- Produces:
  - `final class Lock: @unchecked Sendable { init(); func withLock<T>(_ body: () throws -> T) rethrows -> T }` (internal)
  - `public enum SwiftOSLoggerVersion { public static let current: String }` (= `"1.0.0"`)
  - `public struct LogLevel: Comparable, Hashable, Sendable, CustomStringConvertible` with `rawValue: Int`, `name: String`, `emoji: String`, `osLogType: OSLogType`, `init(rawValue:name:emoji:osLogType:)`, and presets `.trace .debug .info .notice .warning .error .critical .off`

- [ ] **Step 1: Create the package manifest and ignore file**

`Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftOSLogger",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftOSLogger", targets: ["SwiftOSLogger"]),
    ],
    targets: [
        .target(
            name: "SwiftOSLogger",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "SwiftOSLoggerTests",
            dependencies: ["SwiftOSLogger"]
        ),
    ]
)
```

`.gitignore`:

```
.DS_Store
/.build
/build
/.swiftpm
/Packages
xcuserdata/
DerivedData/
```

- [ ] **Step 2: Write the failing tests**

`Tests/SwiftOSLoggerTests/LogLevelTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter LogLevelTests`
Expected: build fails with `cannot find 'LogLevel' in scope` (and/or SwiftPM reports the target has no sources)

- [ ] **Step 4: Implement**

`Sources/SwiftOSLogger/Support/Lock.swift`:

```swift
import os

/// A heap-allocated `os_unfair_lock` wrapper. `OSAllocatedUnfairLock` requires iOS 16,
/// so this type is used to support iOS 15.
final class Lock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}
```

`Sources/SwiftOSLogger/Support/Version.swift`:

```swift
/// The version of the SwiftOSLogger framework, written into every log file header.
public enum SwiftOSLoggerVersion {
    public static let current = "1.0.0"
}
```

`Sources/SwiftOSLogger/Core/LogLevel.swift`:

````swift
import os

/// The severity of a log entry.
///
/// Levels are ordered by `rawValue`. Use the presets, or define your own:
///
/// ```swift
/// extension LogLevel {
///     static let audit = LogLevel(rawValue: 450, name: "AUDIT", emoji: "🧾", osLogType: .default)
/// }
/// ```
public struct LogLevel: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Ordering value. Higher is more severe.
    public let rawValue: Int
    /// Label written into formatted output, e.g. `"INFO"`.
    public let name: String
    /// Optional emoji used by formatters when `includeEmoji` is on.
    public let emoji: String
    private let osLogTypeRawValue: UInt8

    /// The unified logging type used by `OSLogDestination`.
    public var osLogType: OSLogType { OSLogType(rawValue: osLogTypeRawValue) }

    public init(rawValue: Int, name: String, emoji: String = "", osLogType: OSLogType) {
        self.rawValue = rawValue
        self.name = name
        self.emoji = emoji
        self.osLogTypeRawValue = osLogType.rawValue
    }

    public var description: String { name }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func == (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    public static let trace = LogLevel(rawValue: 100, name: "TRACE", emoji: "🔬", osLogType: .debug)
    public static let debug = LogLevel(rawValue: 200, name: "DEBUG", emoji: "🐞", osLogType: .debug)
    public static let info = LogLevel(rawValue: 300, name: "INFO", emoji: "ℹ️", osLogType: .info)
    public static let notice = LogLevel(rawValue: 400, name: "NOTICE", emoji: "📘", osLogType: .default)
    public static let warning = LogLevel(rawValue: 500, name: "WARNING", emoji: "⚠️", osLogType: .default)
    public static let error = LogLevel(rawValue: 600, name: "ERROR", emoji: "❌", osLogType: .error)
    public static let critical = LogLevel(rawValue: 700, name: "CRITICAL", emoji: "🔥", osLogType: .fault)
    /// Use as a minimum level to disable output. Never log at this level.
    public static let off = LogLevel(rawValue: Int.max, name: "OFF", osLogType: .default)
}
````

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LogLevelTests`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "feat: add package scaffold and LogLevel"
```

---

### Task 2: LogEntry and TextLogFormatter

`makeEntry()` in `TestSupport.swift` builds a fixed entry dated 2026-09-15 08:15:12.347 UTC. Tests format it in `+0530`, so it prints as 13:45:12.347.

**Files:**
- Create: `Sources/SwiftOSLogger/Core/LogEntry.swift`
- Create: `Sources/SwiftOSLogger/Formatting/LogFormatter.swift`
- Create: `Sources/SwiftOSLogger/Support/DateFormatterCache.swift`
- Create: `Sources/SwiftOSLogger/Formatting/TextLogFormatter.swift`
- Test: `Tests/SwiftOSLoggerTests/TestSupport.swift`
- Test: `Tests/SwiftOSLoggerTests/TextLogFormatterTests.swift`

**Interfaces:**
- Consumes: `LogLevel` (Task 1), `Lock` (Task 1)
- Produces:
  - `public struct LogEntry: Sendable` with memberwise `public init(level:message:date:subsystem:category:fileID:fileName:filePath:className:function:line:threadID:threadName:isMainThread:processID:)`. Types: `threadID: UInt64`, `line: Int`, `processID: Int32`.
  - `public protocol LogFormatter: Sendable { func format(_ entry: LogEntry) -> String }`
  - `final class DateFormatterCache` (internal) with `static func string(from: Date, format: String, timeZone: TimeZone) -> String`
  - `public struct TextLogFormatter: LogFormatter`. Its `var`s and `init` labels, in order: `dateFormat, timeZone, includeDate, includeEmoji, includeLevel, includeThread, includeSubsystem, includeCategory, includeFileAndLine, includeClassName, includeFunction`. Also `public static let osLogDefault`.
  - Test helper `func makeEntry(level:message:date:threadID:threadName:) -> LogEntry`

- [ ] **Step 1: Write the failing tests**

`Tests/SwiftOSLoggerTests/TestSupport.swift`:

```swift
import Foundation
@testable import SwiftOSLogger

/// A fixed entry: 2026-09-15 08:15:12.347 UTC (13:45:12.347 +0530).
func makeEntry(
    level: LogLevel = .info,
    message: String = "Request started",
    date: Date = Date(timeIntervalSince1970: 1_789_460_112.347),
    threadID: UInt64 = 0x1a2b,
    threadName: String = "main"
) -> LogEntry {
    LogEntry(
        level: level,
        message: message,
        date: date,
        subsystem: "com.acme.app",
        category: "Network",
        fileID: "MyApp/NetworkManager.swift",
        fileName: "NetworkManager.swift",
        filePath: "/src/MyApp/NetworkManager.swift",
        className: "NetworkManager",
        function: "fetch(_:)",
        line: 42,
        threadID: threadID,
        threadName: threadName,
        isMainThread: threadName == "main",
        processID: 4821
    )
}
```

`Tests/SwiftOSLoggerTests/TextLogFormatterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'TextLogFormatterTests'`
Expected: build fails with `cannot find 'LogEntry' in scope`

- [ ] **Step 3: Implement**

`Sources/SwiftOSLogger/Core/LogEntry.swift`:

```swift
import Foundation

/// A single log event with all metadata captured at the call site.
public struct LogEntry: Sendable {
    public let level: LogLevel
    public let message: String
    public let date: Date
    public let subsystem: String
    public let category: String
    /// `#fileID`, e.g. `"MyApp/NetworkManager.swift"`.
    public let fileID: String
    /// Last path component of `fileID`, e.g. `"NetworkManager.swift"`.
    public let fileName: String
    /// `#filePath`.
    public let filePath: String
    public let className: String
    public let function: String
    public let line: Int
    /// Value from `pthread_threadid_np`.
    public let threadID: UInt64
    /// `"main"`, the thread name, the dispatch queue label, or `""`.
    public let threadName: String
    public let isMainThread: Bool
    public let processID: Int32

    public init(
        level: LogLevel,
        message: String,
        date: Date,
        subsystem: String,
        category: String,
        fileID: String,
        fileName: String,
        filePath: String,
        className: String,
        function: String,
        line: Int,
        threadID: UInt64,
        threadName: String,
        isMainThread: Bool,
        processID: Int32
    ) {
        self.level = level
        self.message = message
        self.date = date
        self.subsystem = subsystem
        self.category = category
        self.fileID = fileID
        self.fileName = fileName
        self.filePath = filePath
        self.className = className
        self.function = function
        self.line = line
        self.threadID = threadID
        self.threadName = threadName
        self.isMainThread = isMainThread
        self.processID = processID
    }
}
```

`Sources/SwiftOSLogger/Formatting/LogFormatter.swift`:

```swift
/// Turns a `LogEntry` into a single string. Must not include a trailing newline.
public protocol LogFormatter: Sendable {
    func format(_ entry: LogEntry) -> String
}
```

`Sources/SwiftOSLogger/Support/DateFormatterCache.swift`:

```swift
import Foundation

/// Thread-safe cache of `DateFormatter`s keyed by format and time zone.
/// Creating a `DateFormatter` per log line is expensive.
final class DateFormatterCache: @unchecked Sendable {
    static let shared = DateFormatterCache()

    private let lock = Lock()
    private var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        shared.string(from: date, format: format, timeZone: timeZone)
    }

    private func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        let key = "\(format)|\(timeZone.identifier)"
        return lock.withLock {
            let formatter: DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.dateFormat = format
                formatter.timeZone = timeZone
                formatters[key] = formatter
            }
            return formatter.string(from: date)
        }
    }
}
```

`Sources/SwiftOSLogger/Formatting/TextLogFormatter.swift`:

````swift
import Foundation

/// Human-readable single-line formatter.
///
/// Default output:
/// ```
/// 2026-09-15 13:45:12.347 +0530 [INFO] [main:0x1a2b] [Network] NetworkManager.swift:42 NetworkManager.fetch(_:) - Request started
/// ```
public struct TextLogFormatter: LogFormatter {
    public var dateFormat: String
    public var timeZone: TimeZone
    public var includeDate: Bool
    public var includeEmoji: Bool
    public var includeLevel: Bool
    public var includeThread: Bool
    public var includeSubsystem: Bool
    public var includeCategory: Bool
    public var includeFileAndLine: Bool
    public var includeClassName: Bool
    public var includeFunction: Bool

    public init(
        dateFormat: String = "yyyy-MM-dd HH:mm:ss.SSS Z",
        timeZone: TimeZone = .current,
        includeDate: Bool = true,
        includeEmoji: Bool = false,
        includeLevel: Bool = true,
        includeThread: Bool = true,
        includeSubsystem: Bool = false,
        includeCategory: Bool = true,
        includeFileAndLine: Bool = true,
        includeClassName: Bool = true,
        includeFunction: Bool = true
    ) {
        self.dateFormat = dateFormat
        self.timeZone = timeZone
        self.includeDate = includeDate
        self.includeEmoji = includeEmoji
        self.includeLevel = includeLevel
        self.includeThread = includeThread
        self.includeSubsystem = includeSubsystem
        self.includeCategory = includeCategory
        self.includeFileAndLine = includeFileAndLine
        self.includeClassName = includeClassName
        self.includeFunction = includeFunction
    }

    /// Used by `OSLogDestination`: unified logging already records date, level,
    /// subsystem and category, so those are omitted.
    public static let osLogDefault = TextLogFormatter(includeDate: false, includeLevel: false, includeCategory: false)

    public func format(_ entry: LogEntry) -> String {
        var segments: [String] = []
        if includeDate {
            segments.append(DateFormatterCache.string(from: entry.date, format: dateFormat, timeZone: timeZone))
        }
        if includeEmoji, !entry.level.emoji.isEmpty {
            segments.append(entry.level.emoji)
        }
        if includeLevel {
            segments.append("[\(entry.level.name)]")
        }
        if includeThread {
            let id = "0x" + String(entry.threadID, radix: 16)
            segments.append(entry.threadName.isEmpty ? "[\(id)]" : "[\(entry.threadName):\(id)]")
        }
        if includeSubsystem {
            segments.append("[\(entry.subsystem)]")
        }
        if includeCategory {
            segments.append("[\(entry.category)]")
        }
        if includeFileAndLine {
            segments.append("\(entry.fileName):\(entry.line)")
        }
        switch (includeClassName, includeFunction) {
        case (true, true): segments.append("\(entry.className).\(entry.function)")
        case (true, false): segments.append(entry.className)
        case (false, true): segments.append(entry.function)
        case (false, false): break
        }
        guard !segments.isEmpty else { return entry.message }
        return segments.joined(separator: " ") + " - " + entry.message
    }
}
````

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'TextLogFormatterTests'`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftOSLogger/Core/LogEntry.swift Sources/SwiftOSLogger/Formatting/LogFormatter.swift Sources/SwiftOSLogger/Support/DateFormatterCache.swift Sources/SwiftOSLogger/Formatting/TextLogFormatter.swift Tests/SwiftOSLoggerTests/TestSupport.swift Tests/SwiftOSLoggerTests/TextLogFormatterTests.swift
git commit -m "feat: add LogEntry and TextLogFormatter"
```

---

### Task 3: JSONLogFormatter


**Files:**
- Create: `Sources/SwiftOSLogger/Formatting/JSONLogFormatter.swift`
- Test: `Tests/SwiftOSLoggerTests/JSONLogFormatterTests.swift`

**Interfaces:**
- Consumes: `LogEntry`, `LogFormatter`, `DateFormatterCache`, `makeEntry()` (Task 2)
- Produces: `public struct JSONLogFormatter: LogFormatter { public init() }`. Output keys: `timestamp level levelValue message subsystem category file line class function threadID threadName isMainThread pid`.

- [ ] **Step 1: Write the failing tests**

`Tests/SwiftOSLoggerTests/JSONLogFormatterTests.swift`:

```swift
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

    func testKeysAreSorted() {
        let line = JSONLogFormatter().format(makeEntry())
        XCTAssertTrue(line.hasPrefix("{\"category\":"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'JSONLogFormatterTests'`
Expected: build fails with `cannot find 'JSONLogFormatter' in scope`

- [ ] **Step 3: Implement**

`Sources/SwiftOSLogger/Formatting/JSONLogFormatter.swift`:

```swift
import Foundation

/// Formats each entry as one compact JSON object (JSON Lines), with sorted keys.
public struct JSONLogFormatter: LogFormatter {
    public init() {}

    public func format(_ entry: LogEntry) -> String {
        let object: [String: Any] = [
            "timestamp": DateFormatterCache.string(
                from: entry.date,
                format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                timeZone: TimeZone(identifier: "UTC")!
            ),
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
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{\"level\":\"\(entry.level.name)\",\"message\":\"<unencodable>\"}"
        }
        return string
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'JSONLogFormatterTests'`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftOSLogger/Formatting/JSONLogFormatter.swift Tests/SwiftOSLoggerTests/JSONLogFormatterTests.swift
git commit -m "feat: add JSONLogFormatter"
```

---

### Task 4: LogDestination protocol, OSLogDestination and ConsoleDestination

`testEntriesReachUnifiedLogging` reads the entry back with `OSLogStore(scope: .currentProcessIdentifier)`. The first run can take several seconds.

**Files:**
- Create: `Sources/SwiftOSLogger/Destinations/LogDestination.swift`
- Create: `Sources/SwiftOSLogger/Destinations/OSLogDestination.swift`
- Create: `Sources/SwiftOSLogger/Destinations/ConsoleDestination.swift`
- Test: `Tests/SwiftOSLoggerTests/OSLogDestinationTests.swift`
- Test: `Tests/SwiftOSLoggerTests/ConsoleDestinationTests.swift`

**Interfaces:**
- Consumes: `LogEntry`, `LogFormatter`, `TextLogFormatter` (+ `.osLogDefault`), `Lock`, `makeEntry()`
- Produces:
  - `public protocol LogDestination: Sendable { var minLevel: LogLevel { get }; var formatter: any LogFormatter { get }; func write(_ entry: LogEntry, formatted: String); func flush() }`. It has a default no-op `flush()`.
  - `public struct OSLogDestination: LogDestination`: `init(minLevel: LogLevel = .trace, privacy: Privacy = .public, formatter: any LogFormatter = TextLogFormatter.osLogDefault)`, where `enum Privacy { case public, private, auto }`.
  - `final class OSLoggerCache` (internal): `func logger(subsystem:category:) -> Logger`, `var count: Int`
  - `public struct ConsoleDestination: LogDestination`: `init(minLevel: LogLevel = .trace, formatter: any LogFormatter = TextLogFormatter(includeEmoji: true), output: Output = .standardOutput)`, where `enum Output { case standardOutput, standardError }`. It also has an internal test init `init(minLevel:formatter:output:writer: @escaping @Sendable (Data) -> Void)`.

- [ ] **Step 1: Write the failing tests**

`Tests/SwiftOSLoggerTests/OSLogDestinationTests.swift`:

```swift
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
```

`Tests/SwiftOSLoggerTests/ConsoleDestinationTests.swift`:

```swift
import XCTest
@testable import SwiftOSLogger

final class ConsoleDestinationTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    func testDefaults() {
        let destination = ConsoleDestination()
        XCTAssertEqual(destination.minLevel, .trace)
        XCTAssertEqual(destination.output, .standardOutput)
        XCTAssertEqual((destination.formatter as? TextLogFormatter)?.includeEmoji, true)
    }

    func testWritesFormattedLineWithNewline() {
        let capture = Capture()
        let destination = ConsoleDestination(minLevel: .trace, formatter: TextLogFormatter(), output: .standardOutput,
                                             writer: { capture.append($0) })
        destination.write(makeEntry(), formatted: "line one")
        destination.write(makeEntry(), formatted: "line two")
        XCTAssertEqual(capture.text, "line one\nline two\n")
    }

    func testConcurrentWritesDoNotInterleave() {
        let capture = Capture()
        let destination = ConsoleDestination(minLevel: .trace, formatter: TextLogFormatter(), output: .standardError,
                                             writer: { data in
                                                 // Write byte-by-byte to expose any missing serialization.
                                                 for byte in data { capture.append(Data([byte])) }
                                             })
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            destination.write(makeEntry(), formatted: "entry-\(i)-end")
        }
        let lines = capture.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 200)
        XCTAssertTrue(lines.allSatisfy { $0.range(of: #"^entry-\d+-end$"#, options: .regularExpression) != nil })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'OSLogDestinationTests|ConsoleDestinationTests'`
Expected: build fails with `cannot find 'OSLogDestination' in scope`

- [ ] **Step 3: Implement**

`Sources/SwiftOSLogger/Destinations/LogDestination.swift`:

```swift
/// A place log entries are sent to. Conform to build your own destination
/// (for example, a remote upload or an in-app log viewer).
public protocol LogDestination: Sendable {
    /// Entries below this level are not sent to this destination.
    var minLevel: LogLevel { get }
    /// Formats entries before `write(_:formatted:)` is called.
    var formatter: any LogFormatter { get }
    /// Receives an entry and its formatted text. Called on the logging thread;
    /// must be fast and thread-safe.
    func write(_ entry: LogEntry, formatted: String)
    /// Writes any buffered output. Default implementation does nothing.
    func flush()
}

public extension LogDestination {
    func flush() {}
}
```

`Sources/SwiftOSLogger/Destinations/OSLogDestination.swift`:

```swift
import os

/// Sends entries to Apple's unified logging system via `os.Logger`.
/// View them in Xcode's console, Console.app, or with
/// `log stream --predicate 'subsystem == "com.acme.app"'`.
///
/// Privacy applies to the whole message: the message is a runtime `String`,
/// not an `OSLogMessage` interpolation literal, so per-value privacy is not possible.
public struct OSLogDestination: LogDestination {
    public enum Privacy: Sendable {
        case `public`
        case `private`
        case auto
    }

    public let minLevel: LogLevel
    public let formatter: any LogFormatter
    public let privacy: Privacy
    private let loggers = OSLoggerCache()

    public init(
        minLevel: LogLevel = .trace,
        privacy: Privacy = .public,
        formatter: any LogFormatter = TextLogFormatter.osLogDefault
    ) {
        self.minLevel = minLevel
        self.privacy = privacy
        self.formatter = formatter
    }

    public func write(_ entry: LogEntry, formatted: String) {
        let logger = loggers.logger(subsystem: entry.subsystem, category: entry.category)
        let type = entry.level.osLogType
        switch privacy {
        case .public: logger.log(level: type, "\(formatted, privacy: .public)")
        case .private: logger.log(level: type, "\(formatted, privacy: .private)")
        case .auto: logger.log(level: type, "\(formatted, privacy: .auto)")
        }
    }
}

/// One `os.Logger` per subsystem/category pair.
final class OSLoggerCache: @unchecked Sendable {
    private let lock = Lock()
    private var loggers: [String: Logger] = [:]

    func logger(subsystem: String, category: String) -> Logger {
        let key = "\(subsystem)|\(category)"
        return lock.withLock {
            if let logger = loggers[key] { return logger }
            let logger = Logger(subsystem: subsystem, category: category)
            loggers[key] = logger
            return logger
        }
    }

    var count: Int { lock.withLock { loggers.count } }
}
```

`Sources/SwiftOSLogger/Destinations/ConsoleDestination.swift`:

```swift
import Foundation

/// Prints entries to standard output or standard error.
///
/// Note: `OSLogDestination` output already appears in Xcode's console, so enabling
/// both prints each entry twice there.
public struct ConsoleDestination: LogDestination {
    public enum Output: Sendable {
        case standardOutput
        case standardError
    }

    private static let writeLock = Lock()

    public let minLevel: LogLevel
    public let formatter: any LogFormatter
    public let output: Output
    private let writer: @Sendable (Data) -> Void

    public init(
        minLevel: LogLevel = .trace,
        formatter: any LogFormatter = TextLogFormatter(includeEmoji: true),
        output: Output = .standardOutput
    ) {
        let writer: @Sendable (Data) -> Void
        switch output {
        case .standardOutput: writer = { FileHandle.standardOutput.write($0) }
        case .standardError: writer = { FileHandle.standardError.write($0) }
        }
        self.init(minLevel: minLevel, formatter: formatter, output: output, writer: writer)
    }

    /// Test seam: capture output instead of writing to a file handle.
    init(minLevel: LogLevel, formatter: any LogFormatter, output: Output, writer: @escaping @Sendable (Data) -> Void) {
        self.minLevel = minLevel
        self.formatter = formatter
        self.output = output
        self.writer = writer
    }

    public func write(_ entry: LogEntry, formatted: String) {
        let data = Data((formatted + "\n").utf8)
        Self.writeLock.withLock { writer(data) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'OSLogDestinationTests|ConsoleDestinationTests'`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftOSLogger/Destinations/LogDestination.swift Sources/SwiftOSLogger/Destinations/OSLogDestination.swift Sources/SwiftOSLogger/Destinations/ConsoleDestination.swift Tests/SwiftOSLoggerTests/OSLogDestinationTests.swift Tests/SwiftOSLoggerTests/ConsoleDestinationTests.swift
git commit -m "feat: add OSLog and console destinations"
```

---

### Task 5: OSLogger, LoggerConfiguration, Loggable and thread info


**Files:**
- Create: `Sources/SwiftOSLogger/Support/ThreadInfo.swift`
- Create: `Sources/SwiftOSLogger/Core/LoggerConfiguration.swift`
- Create: `Sources/SwiftOSLogger/Core/OSLogger.swift`
- Create: `Sources/SwiftOSLogger/Core/Loggable.swift`
- Test: `Tests/SwiftOSLoggerTests/MemoryDestination.swift`
- Test: `Tests/SwiftOSLoggerTests/OSLoggerTests.swift`

**Interfaces:**
- Consumes: `LogLevel`, `LogEntry`, `LogDestination`, `OSLogDestination`, `TextLogFormatter`, `Lock`
- Produces:
  - `enum ThreadInfo` (internal): `static var isMainThread: Bool`, `static var currentThreadID: UInt64`, `static var currentThreadName: String`
  - `public struct LoggerConfiguration: Sendable { var minLevel: LogLevel; var destinations: [any LogDestination]; init(minLevel: LogLevel = .debug, destinations: [any LogDestination] = [OSLogDestination()]) }`
  - `public final class OSLogger: @unchecked Sendable` with:
    - `static let shared`
    - `convenience init(subsystem: String = Bundle.main.bundleIdentifier ?? "SwiftOSLogger", category: String = "Default", configuration: LoggerConfiguration = LoggerConfiguration())`
    - properties `subsystem`, `category`, and `var configuration`
    - `configure(_:)`, `withCategory(_:) -> OSLogger`, `bound(to: Any.Type) -> OSLogger`
    - `log(_ level:_ message:type:fileID:file:function:line:)`
    - `trace/debug/info/notice/warning/error/critical(_:type:fileID:file:function:line:)`
    - `flush()`
  - `public protocol Loggable { static var logCategory: String { get }; static var baseLogger: OSLogger { get } }`, with extension members `static var log: OSLogger` and `var log: OSLogger`
  - Test double `final class MemoryDestination: LogDestination` with `entries: [LogEntry]`, `lines: [String]`, `flushCount: Int`

- [ ] **Step 1: Write the failing tests**

`Tests/SwiftOSLoggerTests/MemoryDestination.swift`:

```swift
import Foundation
@testable import SwiftOSLogger

/// Records every entry it receives. Used to test `OSLogger` without I/O.
final class MemoryDestination: LogDestination, @unchecked Sendable {
    let minLevel: LogLevel
    let formatter: any LogFormatter
    private let lock = NSLock()
    private var _records: [(entry: LogEntry, formatted: String)] = []
    private var _flushCount = 0

    init(minLevel: LogLevel = .trace, formatter: any LogFormatter = TextLogFormatter()) {
        self.minLevel = minLevel
        self.formatter = formatter
    }

    var entries: [LogEntry] { lock.lock(); defer { lock.unlock() }; return _records.map(\.entry) }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _records.map(\.formatted) }
    var flushCount: Int { lock.lock(); defer { lock.unlock() }; return _flushCount }

    func write(_ entry: LogEntry, formatted: String) {
        lock.lock(); defer { lock.unlock() }
        _records.append((entry, formatted))
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        _flushCount += 1
    }
}
```

`Tests/SwiftOSLoggerTests/OSLoggerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'SwiftOSLoggerTests.OSLoggerTests'`
Expected: build fails with `cannot find 'OSLogger' in scope`

- [ ] **Step 3: Implement**

`Sources/SwiftOSLogger/Support/ThreadInfo.swift`:

```swift
import Foundation

/// Reads thread metadata with pthread/dispatch APIs, which (unlike `Thread.current`)
/// are safe to call from Swift `async` contexts.
enum ThreadInfo {
    static var isMainThread: Bool { pthread_main_np() != 0 }

    static var currentThreadID: UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    /// `"main"` on the main thread, otherwise the pthread name, otherwise the
    /// current dispatch queue label, otherwise `""`.
    static var currentThreadName: String {
        if isMainThread { return "main" }
        var buffer = [CChar](repeating: 0, count: 128)
        if pthread_getname_np(pthread_self(), &buffer, buffer.count) == 0, buffer[0] != 0 {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return String(cString: __dispatch_queue_get_label(nil))
    }
}
```

`Sources/SwiftOSLogger/Core/LoggerConfiguration.swift`:

```swift
/// Settings shared by an `OSLogger` and every logger derived from it.
public struct LoggerConfiguration: Sendable {
    /// Entries below this level are dropped before any destination sees them.
    public var minLevel: LogLevel
    /// Where entries are sent.
    public var destinations: [any LogDestination]

    public init(minLevel: LogLevel = .debug, destinations: [any LogDestination] = [OSLogDestination()]) {
        self.minLevel = minLevel
        self.destinations = destinations
    }
}
```

`Sources/SwiftOSLogger/Core/OSLogger.swift`:

````swift
import Foundation

/// The main entry point for logging.
///
/// ```swift
/// let log = OSLogger(subsystem: "com.acme.app", category: "Network")
/// log.info("Request started")
/// ```
public final class OSLogger: @unchecked Sendable {
    /// A process-wide logger using the main bundle identifier as subsystem.
    public static let shared = OSLogger()

    public let subsystem: String
    public let category: String
    private let boundTypeName: String?
    private let storage: ConfigurationStorage

    public convenience init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "SwiftOSLogger",
        category: String = "Default",
        configuration: LoggerConfiguration = LoggerConfiguration()
    ) {
        self.init(subsystem: subsystem, category: category, boundTypeName: nil,
                  storage: ConfigurationStorage(configuration))
    }

    private init(subsystem: String, category: String, boundTypeName: String?, storage: ConfigurationStorage) {
        self.subsystem = subsystem
        self.category = category
        self.boundTypeName = boundTypeName
        self.storage = storage
    }

    // MARK: Configuration

    /// A snapshot of the current configuration. Setting it replaces the configuration
    /// for this logger and every logger derived from it.
    public var configuration: LoggerConfiguration {
        get { storage.lock.withLock { storage.value } }
        set { storage.lock.withLock { storage.value = newValue } }
    }

    /// Atomically updates the configuration. Do not log from inside `update`.
    public func configure(_ update: (inout LoggerConfiguration) -> Void) {
        storage.lock.withLock { update(&storage.value) }
    }

    /// A logger with a different category that shares this logger's configuration.
    public func withCategory(_ category: String) -> OSLogger {
        OSLogger(subsystem: subsystem, category: category, boundTypeName: boundTypeName, storage: storage)
    }

    /// A logger whose entries report `type` as their class name. Shares this logger's configuration.
    public func bound(to type: Any.Type) -> OSLogger {
        OSLogger(subsystem: subsystem, category: category, boundTypeName: String(describing: type), storage: storage)
    }

    // MARK: Logging

    /// Logs `message` at `level`. The message is only evaluated if at least one
    /// destination accepts the level.
    ///
    /// - Parameter type: Overrides the class name recorded for this entry.
    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        type: Any.Type? = nil,
        fileID: String = #fileID,
        file: String = #filePath,
        function: String = #function,
        line: Int = #line
    ) {
        let config = configuration
        guard level < .off, level >= config.minLevel else { return }
        let destinations = config.destinations.filter { level >= $0.minLevel }
        guard !destinations.isEmpty else { return }

        let fileName = fileID.split(separator: "/").last.map(String.init) ?? fileID
        let className = type.map { String(describing: $0) }
            ?? boundTypeName
            ?? (fileName.hasSuffix(".swift") ? String(fileName.dropLast(".swift".count)) : fileName)

        let entry = LogEntry(
            level: level,
            message: message(),
            date: Date(),
            subsystem: subsystem,
            category: category,
            fileID: fileID,
            fileName: fileName,
            filePath: file,
            className: className,
            function: function,
            line: line,
            threadID: ThreadInfo.currentThreadID,
            threadName: ThreadInfo.currentThreadName,
            isMainThread: ThreadInfo.isMainThread,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        for destination in destinations {
            destination.write(entry, formatted: destination.formatter.format(entry))
        }
    }

    public func trace(_ message: @autoclosure () -> String, type: Any.Type? = nil,
                      fileID: String = #fileID, file: String = #filePath, function: String = #function, line: Int = #line) {
        log(.trace, message(), type: type, fileID: fileID, file: file, function: function, line: line)
    }

    public func debug(_ message: @autoclosure () -> String, type: Any.Type? = nil,
                      fileID: String = #fileID, file: String = #filePath, function: String = #function, line: Int = #line) {
        log(.debug, message(), type: type, fileID: fileID, file: file, function: function, line: line)
    }

    public func info(_ message: @autoclosure () -> String, type: Any.Type? = nil,
                     fileID: String = #fileID, file: String = #filePath, function: String = #function, line: Int = #line) {
        log(.info, message(), type: type, fileID: fileID, file: file, function: function, line: line)
    }

    public func notice(_ message: @autoclosure () -> String, type: Any.Type? = nil,
                       fileID: String = #fileID, file: String = #filePath, function: String = #function, line: Int = #line) {
        log(.notice, message(), type: type, fileID: fileID, file: file, function: function, line: line)
    }

    public func warning(_ message: @autoclosure () -> String, type: Any.Type? = nil,
                        fileID: String = #fileID, file: String = #filePath, function: String = #function, line: Int = #line) {
        log(.warning, message(), type: type, fileID: fileID, file: file, function: function, line: line)
    }

    public func error(_ message: @autoclosure () -> String, type: Any.Type? = nil,
                      fileID: String = #fileID, file: String = #filePath, function: String = #function, line: Int = #line) {
        log(.error, message(), type: type, fileID: fileID, file: file, function: function, line: line)
    }

    public func critical(_ message: @autoclosure () -> String, type: Any.Type? = nil,
                         fileID: String = #fileID, file: String = #filePath, function: String = #function, line: Int = #line) {
        log(.critical, message(), type: type, fileID: fileID, file: file, function: function, line: line)
    }

    /// Flushes every destination. Blocks until buffered output is written.
    public func flush() {
        for destination in configuration.destinations {
            destination.flush()
        }
    }
}

private final class ConfigurationStorage: @unchecked Sendable {
    let lock = Lock()
    var value: LoggerConfiguration

    init(_ value: LoggerConfiguration) {
        self.value = value
    }
}
````

`Sources/SwiftOSLogger/Core/Loggable.swift`:

````swift
/// Adopt to get a `log` property whose entries carry the adopting type's name
/// as class name and category.
///
/// ```swift
/// final class NetworkManager: Loggable {
///     func fetch() { log.debug("go") }   // class "NetworkManager", category "NetworkManager"
/// }
/// ```
public protocol Loggable {
    /// Category for this type's entries. Defaults to the type name.
    static var logCategory: String { get }
    /// Logger the type's `log` is derived from. Defaults to `OSLogger.shared`.
    static var baseLogger: OSLogger { get }
}

public extension Loggable {
    static var logCategory: String { String(describing: Self.self) }
    static var baseLogger: OSLogger { .shared }

    static var log: OSLogger { baseLogger.withCategory(logCategory).bound(to: Self.self) }
    var log: OSLogger { Self.log }
}
````

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'SwiftOSLoggerTests.OSLoggerTests'`
Expected: `Executed 14 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftOSLogger/Support/ThreadInfo.swift Sources/SwiftOSLogger/Core/LoggerConfiguration.swift Sources/SwiftOSLogger/Core/OSLogger.swift Sources/SwiftOSLogger/Core/Loggable.swift Tests/SwiftOSLoggerTests/MemoryDestination.swift Tests/SwiftOSLoggerTests/OSLoggerTests.swift
git commit -m "feat: add OSLogger core API and Loggable"
```

---

### Task 6: AppInfo, FileDestinationConfiguration and LogFileHeader

`testAppInfoReadsBundleAndProcess` builds a fake bundle with an `Info.plist` in a temp directory. It expects `osName == "macOS"` because tests run on macOS.

**Files:**
- Create: `Sources/SwiftOSLogger/Support/AppInfo.swift`
- Create: `Sources/SwiftOSLogger/File/FileDestinationConfiguration.swift`
- Create: `Sources/SwiftOSLogger/File/LogFileHeader.swift`
- Test: `Tests/SwiftOSLoggerTests/FileTestSupport.swift`
- Test: `Tests/SwiftOSLoggerTests/LogFileHeaderTests.swift`

**Interfaces:**
- Consumes: `LogLevel`, `DateFormatterCache`, `SwiftOSLoggerVersion`, `makeEntry()`
- Produces:
  - `struct AppInfo: Sendable, Equatable` (internal) with `var`s `appName, bundleID, appVersion, buildNumber, processName, processID: Int32, osName, osVersion, deviceModel`, `static let current`, and `init(bundle: Bundle, processInfo: ProcessInfo)`
  - `public struct FileDestinationConfiguration: Sendable`. Its `var`s and `init` labels, in order: `directory, fileNamePrefix, fileExtension, maxFileSize: Int?, maxLinesPerFile: Int?, maxFileCount: Int?, newFilePerLaunch, includeHeader, customHeaderFields, bufferSize, flushLevel, flushOnAppLifecycle`. Also `public static var defaultDirectory: URL`.
  - `enum LogFileHeader` (internal): `static func make(appInfo:creationDate:fileIndex:configuration:timeZone: = .current) -> String`. It returns lines prefixed with `# ` and ends with `\n`.
  - Test helpers `makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL`, `readLines(_ url: URL) throws -> [String]`, `bodyLines(_ url: URL) throws -> [String]` (lines not starting with `#`)

- [ ] **Step 1: Write the failing tests**

`Tests/SwiftOSLoggerTests/FileTestSupport.swift`:

```swift
import Foundation
import XCTest

/// Creates a unique empty directory under the system temp dir and removes it after the test.
func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftOSLoggerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
    return url
}

func readLines(_ url: URL) throws -> [String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

func bodyLines(_ url: URL) throws -> [String] {
    try readLines(url).filter { !$0.hasPrefix("#") }
}
```

`Tests/SwiftOSLoggerTests/LogFileHeaderTests.swift`:

```swift
import XCTest
@testable import SwiftOSLogger

final class LogFileHeaderTests: XCTestCase {
    private func makeAppInfo() -> AppInfo {
        var info = AppInfo(bundle: .main, processInfo: .processInfo)
        info.appName = "MyApp"
        info.bundleID = "com.acme.myapp"
        info.appVersion = "2.3.1"
        info.buildNumber = "145"
        info.processName = "MyApp"
        info.processID = 4821
        info.osName = "iOS"
        info.osVersion = "18.2"
        info.deviceModel = "iPhone16,2"
        return info
    }

    func testHeaderContainsLoggerAppAndProcessInfo() {
        let configuration = FileDestinationConfiguration(
            directory: URL(fileURLWithPath: "/tmp"),
            maxFileSize: 5_242_880, maxLinesPerFile: nil, maxFileCount: 10,
            customHeaderFields: ["User": "42", "Environment": "staging"]
        )
        let header = LogFileHeader.make(
            appInfo: makeAppInfo(),
            creationDate: makeEntry().date,
            fileIndex: 3,
            configuration: configuration,
            timeZone: TimeZone(secondsFromGMT: 19_800)!
        )

        XCTAssertEqual(header, """
        # ==================== SwiftOSLogger Log File ====================
        # Logger:          SwiftOSLogger \(SwiftOSLoggerVersion.current)
        # Application:     MyApp
        # Bundle ID:       com.acme.myapp
        # App Version:     2.3.1 (145)
        # Process:         MyApp
        # PID:             4821
        # OS:              iOS 18.2
        # Device Model:    iPhone16,2
        # File Created:    2026-09-15 13:45:12.347 +0530
        # File Index:      3
        # Rotation:        maxFileSize=5242880 bytes, maxLinesPerFile=unlimited, maxFileCount=10
        # Environment:     staging
        # User:            42
        # ================================================================

        """)
    }

    func testEveryHeaderLineStartsWithHash() {
        let header = LogFileHeader.make(appInfo: makeAppInfo(), creationDate: Date(), fileIndex: 1,
                                        configuration: FileDestinationConfiguration(customHeaderFields: ["A very long custom key": "v"]))
        let lines = header.split(separator: "\n")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("# ") })
        XCTAssertTrue(header.contains("# A very long custom key: v"))
    }

    func testAppInfoReadsBundleAndProcess() throws {
        let bundleURL = try makeTemporaryDirectory(self).appendingPathComponent("Fake.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.acme.fake",
            "CFBundleName": "FakeName",
            "CFBundleDisplayName": "Fake Display",
            "CFBundleShortVersionString": "9.8",
            "CFBundleVersion": "765",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        let info = AppInfo(bundle: bundle, processInfo: .processInfo)
        XCTAssertEqual(info.appName, "Fake Display")
        XCTAssertEqual(info.bundleID, "com.acme.fake")
        XCTAssertEqual(info.appVersion, "9.8")
        XCTAssertEqual(info.buildNumber, "765")
        XCTAssertEqual(info.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(info.processName, ProcessInfo.processInfo.processName)
        XCTAssertEqual(info.osName, "macOS")
        XCTAssertFalse(info.osVersion.isEmpty)
        XCTAssertNotEqual(info.deviceModel, "unknown")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'LogFileHeaderTests'`
Expected: build fails with `cannot find 'FileDestinationConfiguration' in scope`

- [ ] **Step 3: Implement**

`Sources/SwiftOSLogger/Support/AppInfo.swift`:

```swift
import Foundation

/// Application, process and device details written into log file headers.
struct AppInfo: Sendable, Equatable {
    var appName: String
    var bundleID: String
    var appVersion: String
    var buildNumber: String
    var processName: String
    var processID: Int32
    var osName: String
    var osVersion: String
    var deviceModel: String

    static let current = AppInfo(bundle: .main, processInfo: .processInfo)

    init(bundle: Bundle, processInfo: ProcessInfo) {
        let info = bundle.infoDictionary ?? [:]
        processName = processInfo.processName
        appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? processInfo.processName
        bundleID = bundle.bundleIdentifier ?? "unknown"
        appVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
        buildNumber = info["CFBundleVersion"] as? String ?? "unknown"
        processID = processInfo.processIdentifier
        osName = AppInfo.platformName

        let version = processInfo.operatingSystemVersion
        osVersion = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        if let simulatorModel = processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            deviceModel = simulatorModel + " (Simulator)"
        } else {
            deviceModel = AppInfo.sysctlString(AppInfo.modelSysctlName) ?? "unknown"
        }
    }

    private static var platformName: String {
        #if targetEnvironment(macCatalyst)
        return "Mac Catalyst"
        #elseif os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }

    private static var modelSysctlName: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return "hw.model"      // e.g. "MacBookPro18,1"
        #else
        return "hw.machine"    // e.g. "iPhone16,2"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
```

`Sources/SwiftOSLogger/File/FileDestinationConfiguration.swift`:

```swift
import Foundation

/// File naming, rotation and buffering options for `FileDestination`.
public struct FileDestinationConfiguration: Sendable {
    /// Folder the log files are written to. Created if missing.
    /// Default: `<Caches>/Logs`. Note that the system may purge Caches when storage is low;
    /// use Application Support if logs must survive that.
    public var directory: URL
    /// File names are `<prefix>_yyyy-MM-dd_HH-mm-ss-SSS.<extension>`.
    public var fileNamePrefix: String
    public var fileExtension: String
    /// Rotate before a file would exceed this many bytes. `nil` = unlimited.
    public var maxFileSize: Int?
    /// Rotate after this many log entries (header lines excluded). `nil` = unlimited.
    public var maxLinesPerFile: Int?
    /// Keep at most this many files; the oldest are deleted. `nil` = unlimited.
    public var maxFileCount: Int?
    /// When `false`, a launch appends to the newest existing file if it is under the limits.
    public var newFilePerLaunch: Bool
    /// Write the logger/app/process header at the top of every new file.
    public var includeHeader: Bool
    /// Extra `key: value` lines appended to the header, sorted by key.
    public var customHeaderFields: [String: String]
    /// Bytes buffered in memory before they are written to disk.
    public var bufferSize: Int
    /// Entries at or above this level are written to disk immediately.
    public var flushLevel: LogLevel
    /// Flush when the app moves to the background or terminates.
    public var flushOnAppLifecycle: Bool

    public init(
        directory: URL = FileDestinationConfiguration.defaultDirectory,
        fileNamePrefix: String = "log",
        fileExtension: String = "log",
        maxFileSize: Int? = 5 * 1024 * 1024,
        maxLinesPerFile: Int? = nil,
        maxFileCount: Int? = 10,
        newFilePerLaunch: Bool = false,
        includeHeader: Bool = true,
        customHeaderFields: [String: String] = [:],
        bufferSize: Int = 32 * 1024,
        flushLevel: LogLevel = .error,
        flushOnAppLifecycle: Bool = true
    ) {
        self.directory = directory
        self.fileNamePrefix = fileNamePrefix
        self.fileExtension = fileExtension
        self.maxFileSize = maxFileSize
        self.maxLinesPerFile = maxLinesPerFile
        self.maxFileCount = maxFileCount
        self.newFilePerLaunch = newFilePerLaunch
        self.includeHeader = includeHeader
        self.customHeaderFields = customHeaderFields
        self.bufferSize = bufferSize
        self.flushLevel = flushLevel
        self.flushOnAppLifecycle = flushOnAppLifecycle
    }

    /// `<Caches>/Logs`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }
}
```

`Sources/SwiftOSLogger/File/LogFileHeader.swift`:

```swift
import Foundation

/// Builds the `# `-prefixed header written at the top of every new log file.
enum LogFileHeader {
    static func make(
        appInfo: AppInfo,
        creationDate: Date,
        fileIndex: Int,
        configuration: FileDestinationConfiguration,
        timeZone: TimeZone = .current
    ) -> String {
        func limit(_ value: Int?, unit: String = "") -> String {
            value.map { "\($0)\(unit)" } ?? "unlimited"
        }

        var fields: [(String, String)] = [
            ("Logger", "SwiftOSLogger \(SwiftOSLoggerVersion.current)"),
            ("Application", appInfo.appName),
            ("Bundle ID", appInfo.bundleID),
            ("App Version", "\(appInfo.appVersion) (\(appInfo.buildNumber))"),
            ("Process", appInfo.processName),
            ("PID", "\(appInfo.processID)"),
            ("OS", "\(appInfo.osName) \(appInfo.osVersion)"),
            ("Device Model", appInfo.deviceModel),
            ("File Created", DateFormatterCache.string(from: creationDate, format: "yyyy-MM-dd HH:mm:ss.SSS Z", timeZone: timeZone)),
            ("File Index", "\(fileIndex)"),
            ("Rotation", "maxFileSize=\(limit(configuration.maxFileSize, unit: " bytes")), "
                + "maxLinesPerFile=\(limit(configuration.maxLinesPerFile)), "
                + "maxFileCount=\(limit(configuration.maxFileCount))"),
        ]
        fields += configuration.customHeaderFields.sorted { $0.key < $1.key }

        let width = max(16, fields.map { $0.0.count + 1 }.max() ?? 0)
        var lines = ["# ==================== SwiftOSLogger Log File ===================="]
        for (key, value) in fields {
            let label = (key + ":").padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("# \(label) \(value)")
        }
        lines.append("# " + String(repeating: "=", count: 64))
        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'LogFileHeaderTests'`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftOSLogger/Support/AppInfo.swift Sources/SwiftOSLogger/File/FileDestinationConfiguration.swift Sources/SwiftOSLogger/File/LogFileHeader.swift Tests/SwiftOSLoggerTests/FileTestSupport.swift Tests/SwiftOSLoggerTests/LogFileHeaderTests.swift
git commit -m "feat: add file configuration, app info and log file header"
```

---

### Task 7: LogFileManager: naming, buffering and rotation

Rotation rules (spec section 7):
- Rotate before appending when `currentBodyLines >= maxLinesPerFile`.
- Rotate when `currentBodyLines > 0 && currentSize + bytes > maxFileSize`.
- After creating a file, delete the oldest files beyond `maxFileCount`, never the current one.
- Limit values below 1 are treated as 1.

**Files:**
- Create: `Sources/SwiftOSLogger/File/LogFileManager.swift`
- Test: `Tests/SwiftOSLoggerTests/LogFileManagerTests.swift`

**Interfaces:**
- Consumes: `FileDestinationConfiguration`, `AppInfo`, `LogFileHeader`, `DateFormatterCache`, and the test helpers from Task 6
- Produces:
  - `public enum FileDestinationError: Error { case cannotCreateDirectory(URL, underlying: Error); case cannotCreateFile(URL) }`
  - `final class LogFileManager` (internal, not thread-safe) with:
    - `init(configuration:appInfo: = .current) throws`
    - `private(set) var currentFileURL: URL?`
    - `func append(_ line: String, flushImmediately: Bool) throws`
    - `func flush() throws`, `func close() throws`, `func discardCurrentFile()`
    - `func logFileURLs() -> [URL]`, `func deleteAllLogFiles()`
    - `static func logFileURLs(in: URL, prefix: String, fileExtension: String) -> [URL]`

- [ ] **Step 1: Write the failing tests**

`Tests/SwiftOSLoggerTests/LogFileManagerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'LogFileManagerTests'`
Expected: build fails with `cannot find 'LogFileManager' in scope`

- [ ] **Step 3: Implement**

`Sources/SwiftOSLogger/File/LogFileManager.swift`:

```swift
import Foundation

/// Errors thrown or reported by `FileDestination`.
public enum FileDestinationError: Error {
    case cannotCreateDirectory(URL, underlying: Error)
    case cannotCreateFile(URL)
}

/// Owns the log files of one `FileDestination`: naming, header, buffering, rotation
/// and cleanup. Not thread-safe; `FileDestination` confines it to a serial queue.
final class LogFileManager {
    let configuration: FileDestinationConfiguration
    private let appInfo: AppInfo
    private let fileManager = FileManager.default

    private(set) var currentFileURL: URL?
    private var handle: FileHandle?
    private var buffer = Data()
    /// Bytes in the current file, including bytes still in `buffer`.
    private var currentSize = 0
    /// Log entries in the current file (header lines excluded), including buffered ones.
    private var currentBodyLines = 0
    private var filesCreated = 0
    private var hasOpenedFile = false

    init(configuration: FileDestinationConfiguration, appInfo: AppInfo = .current) throws {
        self.configuration = configuration
        self.appInfo = appInfo
        do {
            try fileManager.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        } catch {
            throw FileDestinationError.cannotCreateDirectory(configuration.directory, underlying: error)
        }
    }

    deinit {
        try? close()
    }

    // MARK: Writing

    /// Buffers one log line, rotating first if it would exceed a limit.
    func append(_ line: String, flushImmediately: Bool) throws {
        let data = Data((line + "\n").utf8)
        if currentFileURL == nil {
            try openInitialFile()
        } else if shouldRotate(adding: data.count) {
            try createNewFile()
        }
        buffer.append(data)
        currentSize += data.count
        currentBodyLines += 1
        if flushImmediately || buffer.count >= configuration.bufferSize {
            try flush()
        }
    }

    func flush() throws {
        guard !buffer.isEmpty, let handle else { return }
        defer { buffer.removeAll(keepingCapacity: true) }
        try handle.write(contentsOf: buffer)
    }

    func close() throws {
        let closingHandle = handle
        defer {
            handle = nil
            buffer.removeAll()
            try? closingHandle?.close()
        }
        try flush()
    }

    /// Forgets the current file without flushing, so the next append creates a new file.
    /// Used after an I/O error.
    func discardCurrentFile() {
        try? handle?.close()
        handle = nil
        buffer.removeAll()
        currentFileURL = nil
        currentSize = 0
        currentBodyLines = 0
    }

    // MARK: Files

    func logFileURLs() -> [URL] {
        LogFileManager.logFileURLs(in: configuration.directory,
                                   prefix: configuration.fileNamePrefix,
                                   fileExtension: configuration.fileExtension)
    }

    func deleteAllLogFiles() {
        discardCurrentFile()
        for url in logFileURLs() {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Log files for `prefix`/`fileExtension` in `directory`, oldest first.
    static func logFileURLs(in directory: URL, prefix: String, fileExtension: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .compactMap { url -> (url: URL, stamp: String, sequence: Int)? in
                guard url.pathExtension == fileExtension else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                guard name.hasPrefix(prefix + "_") else { return nil }
                // "<date>_<time>" or "<date>_<time>_<sequence>"
                let parts = name.dropFirst(prefix.count + 1).split(separator: "_")
                guard parts.count == 2 || parts.count == 3,
                      parts[0].count == 10, parts[1].count == 12
                else { return nil }
                let sequence = parts.count == 3 ? Int(parts[2]) : 0
                guard let sequence else { return nil }
                // Rebuild from `directory` so URLs compare equal to `currentFileURL`
                // (directory listings resolve symlinks such as /var -> /private/var).
                return (directory.appendingPathComponent(url.lastPathComponent),
                        String(parts[0]) + "_" + String(parts[1]), sequence)
            }
            .sorted { ($0.stamp, $0.sequence) < ($1.stamp, $1.sequence) }
            .map(\.url)
    }

    // MARK: Private

    private var maxFileSize: Int? { configuration.maxFileSize.map { max(1, $0) } }
    private var maxLinesPerFile: Int? { configuration.maxLinesPerFile.map { max(1, $0) } }
    private var maxFileCount: Int? { configuration.maxFileCount.map { max(1, $0) } }

    private func shouldRotate(adding bytes: Int) -> Bool {
        if let maxLinesPerFile, currentBodyLines >= maxLinesPerFile { return true }
        // A file always accepts its first entry, so an oversized line is never dropped.
        if let maxFileSize, currentBodyLines > 0, currentSize + bytes > maxFileSize { return true }
        return false
    }

    private func openInitialFile() throws {
        defer { hasOpenedFile = true }
        if !hasOpenedFile, !configuration.newFilePerLaunch, let latest = logFileURLs().last,
           let stats = measure(latest), isUnderLimits(size: stats.size, bodyLines: stats.bodyLines),
           let handle = try? FileHandle(forWritingTo: latest) {
            try handle.seekToEnd()
            self.handle = handle
            currentFileURL = latest
            currentSize = stats.size
            currentBodyLines = stats.bodyLines
            return
        }
        try createNewFile()
    }

    private func isUnderLimits(size: Int, bodyLines: Int) -> Bool {
        if let maxFileSize, size >= maxFileSize { return false }
        if let maxLinesPerFile, bodyLines >= maxLinesPerFile { return false }
        return true
    }

    private func createNewFile() throws {
        if handle != nil {
            try close()
        }
        let now = Date()
        let url = uniqueFileURL(for: now)
        filesCreated += 1
        let header = configuration.includeHeader
            ? LogFileHeader.make(appInfo: appInfo, creationDate: now, fileIndex: filesCreated, configuration: configuration)
            : ""
        let headerData = Data(header.utf8)
        guard fileManager.createFile(atPath: url.path, contents: headerData),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            throw FileDestinationError.cannotCreateFile(url)
        }
        try handle.seekToEnd()
        self.handle = handle
        currentFileURL = url
        currentSize = headerData.count
        currentBodyLines = 0
        deleteFilesOverLimit()
    }

    private func uniqueFileURL(for date: Date) -> URL {
        // UTC so that name order stays chronological across time zone and DST changes.
        let stamp = DateFormatterCache.string(from: date, format: "yyyy-MM-dd_HH-mm-ss-SSS", timeZone: TimeZone(identifier: "UTC")!)
        let base = "\(configuration.fileNamePrefix)_\(stamp)"
        var url = configuration.directory.appendingPathComponent("\(base).\(configuration.fileExtension)")
        var sequence = 1
        while fileManager.fileExists(atPath: url.path) {
            url = configuration.directory.appendingPathComponent("\(base)_\(sequence).\(configuration.fileExtension)")
            sequence += 1
        }
        return url
    }

    private func deleteFilesOverLimit() {
        guard let maxFileCount else { return }
        var files = logFileURLs()
        let currentName = currentFileURL?.lastPathComponent
        while files.count > maxFileCount {
            let oldest = files.removeFirst()
            guard oldest.lastPathComponent != currentName else { continue }
            try? fileManager.removeItem(at: oldest)
        }
    }

    /// Size and number of non-header lines of an existing file.
    private func measure(_ url: URL) -> (size: Int, bodyLines: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let newline = UInt8(ascii: "\n")
        let hash = UInt8(ascii: "#")
        var size = 0
        var bodyLines = 0
        var atLineStart = true
        var inHeader = true
        var currentLineIsHeader = false
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            size += chunk.count
            for byte in chunk {
                if atLineStart {
                    if byte != hash { inHeader = false }
                    currentLineIsHeader = inHeader
                    atLineStart = false
                }
                if byte == newline {
                    if !currentLineIsHeader { bodyLines += 1 }
                    atLineStart = true
                }
            }
        }
        return (size, bodyLines)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'LogFileManagerTests'`
Expected: `Executed 15 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftOSLogger/File/LogFileManager.swift Tests/SwiftOSLoggerTests/LogFileManagerTests.swift
git commit -m "feat: add LogFileManager with size/line/count rotation"
```

---

### Task 8: FileDestination

`testFlushesOnAppTermination` posts `NSApplication.willTerminateNotification` (tests run on macOS). `testReportsErrorThenDisablesAfterRepeatedFailure` sets the log directory to `0o555` so creating a file fails.

**Files:**
- Create: `Sources/SwiftOSLogger/Destinations/FileDestination.swift`
- Test: `Tests/SwiftOSLoggerTests/FileDestinationTests.swift`

**Interfaces:**
- Consumes: `LogFileManager`, `FileDestinationError`, `FileDestinationConfiguration`, `LogDestination`, `TextLogFormatter`, `OSLogger`, `ThreadInfo`, `makeEntry()`, and the test helpers from Task 6
- Produces: `public final class FileDestination: LogDestination, @unchecked Sendable` with:
  - `init(configuration: FileDestinationConfiguration = FileDestinationConfiguration(), minLevel: LogLevel = .trace, formatter: any LogFormatter = TextLogFormatter(), onInternalError: (@Sendable (Error) -> Void)? = nil) throws`
  - `let configuration`, `var currentLogFileURL: URL?`
  - `func logFileURLs() -> [URL]`, `func deleteAllLogFiles()`, `func flush()`
  - `static func logFileURLs(in: URL, prefix: String = "log", fileExtension: String = "log") -> [URL]`

- [ ] **Step 1: Write the failing tests**

`Tests/SwiftOSLoggerTests/FileDestinationTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'FileDestinationTests'`
Expected: build fails with `cannot find 'FileDestination' in scope`

- [ ] **Step 3: Implement**

`Sources/SwiftOSLogger/Destinations/FileDestination.swift`:

```swift
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif

/// Writes entries to rotating log files.
///
/// Writes are buffered and performed on a private serial queue, so logging never
/// blocks on disk I/O. Entries at or above `configuration.flushLevel` are written
/// immediately; call `flush()` before reading files.
///
/// Errors never reach the caller of `log`. The first I/O failure is reported through
/// `onInternalError` and the destination retries with a new file; a second consecutive
/// failure disables the destination for the rest of the process.
public final class FileDestination: LogDestination, @unchecked Sendable {
    public let minLevel: LogLevel
    public let formatter: any LogFormatter
    public let configuration: FileDestinationConfiguration

    private let onInternalError: (@Sendable (Error) -> Void)?
    private let queue = DispatchQueue(label: "com.swiftoslogger.file-destination")
    private let internalLogger = Logger(subsystem: "SwiftOSLogger", category: "Internal")

    // Confined to `queue`.
    private let manager: LogFileManager
    private var consecutiveFailures = 0
    private var isDisabled = false
    private var reportedErrors = Set<String>()

    // Written only in init/deinit.
    private var observers: [NSObjectProtocol] = []

    /// - Throws: `FileDestinationError.cannotCreateDirectory` if the log directory cannot be created.
    public init(
        configuration: FileDestinationConfiguration = FileDestinationConfiguration(),
        minLevel: LogLevel = .trace,
        formatter: any LogFormatter = TextLogFormatter(),
        onInternalError: (@Sendable (Error) -> Void)? = nil
    ) throws {
        self.configuration = configuration
        self.minLevel = minLevel
        self.formatter = formatter
        self.onInternalError = onInternalError
        self.manager = try LogFileManager(configuration: configuration)
        if configuration.flushOnAppLifecycle {
            observeAppLifecycle()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: LogDestination

    public func write(_ entry: LogEntry, formatted: String) {
        let flushImmediately = entry.level >= configuration.flushLevel
        queue.async { [self] in
            guard !isDisabled else { return }
            if perform({ try manager.append(formatted, flushImmediately: flushImmediately) }) {
                consecutiveFailures = 0
            }
        }
    }

    /// Blocks until buffered entries are written to disk.
    public func flush() {
        queue.sync {
            guard !isDisabled else { return }
            perform { try manager.flush() }
        }
    }

    // MARK: Files

    /// The file currently being written to, or `nil` before the first entry.
    public var currentLogFileURL: URL? {
        queue.sync { manager.currentFileURL }
    }

    /// All log files for this configuration, oldest first. Flushes first.
    public func logFileURLs() -> [URL] {
        queue.sync {
            if !isDisabled { perform { try manager.flush() } }
            return manager.logFileURLs()
        }
    }

    /// Deletes every log file for this configuration. The next entry starts a new file.
    public func deleteAllLogFiles() {
        queue.sync { manager.deleteAllLogFiles() }
    }

    /// Log files for `prefix`/`fileExtension` in `directory`, oldest first.
    public static func logFileURLs(in directory: URL, prefix: String = "log", fileExtension: String = "log") -> [URL] {
        LogFileManager.logFileURLs(in: directory, prefix: prefix, fileExtension: fileExtension)
    }

    // MARK: Private

    /// Runs a file operation on `queue`, applying the retry-then-disable error policy.
    /// Returns `true` if the operation succeeded.
    @discardableResult
    private func perform(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            consecutiveFailures += 1
            report(error)
            manager.discardCurrentFile()
            if consecutiveFailures >= 2 {
                isDisabled = true
                internalLogger.fault("FileDestination disabled after repeated failures in \(self.configuration.directory.path, privacy: .public)")
            }
            return false
        }
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        let key = "\(String(reflecting: type(of: error)))|\(nsError.domain)|\(nsError.code)"
        guard reportedErrors.insert(key).inserted else { return }
        internalLogger.fault("FileDestination error: \(String(describing: error), privacy: .public)")
        onInternalError?(error)
    }

    private func observeAppLifecycle() {
        var names: [Notification.Name] = []
        #if canImport(UIKit) && !os(watchOS)
        names = [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        #elseif canImport(AppKit)
        names = [NSApplication.willTerminateNotification]
        #elseif os(watchOS)
        names = [WKExtension.applicationDidEnterBackgroundNotification]
        #endif
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.flush()
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'FileDestinationTests'`
Expected: `Executed 8 tests, with 0 failures`

Then run the whole suite:

Run: `swift test`
Expected: `Executed 60 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftOSLogger/Destinations/FileDestination.swift Tests/SwiftOSLoggerTests/FileDestinationTests.swift
git commit -m "feat: add FileDestination with background writes, flush and error policy"
```

---

### Task 9: XCFramework build script

**Files:**
- Create: `scripts/build-xcframework.sh`

**Interfaces:**
- Consumes: the `SwiftOSLogger` scheme SwiftPM generates for `Package.swift`, and `Sources/SwiftOSLogger/Support/Version.swift` (the version string is parsed with `sed`)
- Produces: `build/SwiftOSLogger.xcframework`, `build/SwiftOSLogger.xcframework.zip`, and a printed `checksum: <sha256>`

- [ ] **Step 1: Write the script**

`scripts/build-xcframework.sh`:

```bash
#!/usr/bin/env bash
# Builds build/SwiftOSLogger.xcframework (static frameworks) plus a zip and its SwiftPM checksum.
#
# Usage: scripts/build-xcframework.sh [platform ...]
# Platforms: ios ios-simulator maccatalyst macos tvos tvos-simulator watchos watchos-simulator visionos visionos-simulator
# With no arguments every platform is attempted; platforms whose SDK is not installed are skipped.
set -euo pipefail

MODULE="SwiftOSLogger"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
OUTPUT="$BUILD/$MODULE.xcframework"
ALL_PLATFORMS=(ios ios-simulator maccatalyst macos tvos tvos-simulator watchos watchos-simulator visionos visionos-simulator)
if [ "$#" -gt 0 ]; then PLATFORMS=("$@"); else PLATFORMS=("${ALL_PLATFORMS[@]}"); fi

VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/$MODULE/Support/Version.swift")"

destination_for() {
  case "$1" in
    ios) echo "generic/platform=iOS" ;;
    ios-simulator) echo "generic/platform=iOS Simulator" ;;
    maccatalyst) echo "generic/platform=macOS,variant=Mac Catalyst" ;;
    macos) echo "generic/platform=macOS" ;;
    tvos) echo "generic/platform=tvOS" ;;
    tvos-simulator) echo "generic/platform=tvOS Simulator" ;;
    watchos) echo "generic/platform=watchOS" ;;
    watchos-simulator) echo "generic/platform=watchOS Simulator" ;;
    visionos) echo "generic/platform=visionOS" ;;
    visionos-simulator) echo "generic/platform=visionOS Simulator" ;;
    *) echo "Unknown platform '$1'. Valid: ${ALL_PLATFORMS[*]}" >&2; exit 2 ;;
  esac
}

write_info_plist() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$MODULE</string>
  <key>CFBundleIdentifier</key><string>com.swiftoslogger.$MODULE</string>
  <key>CFBundleName</key><string>$MODULE</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
}

# Assembles a static <MODULE>.framework from an archived object file and module interfaces.
make_framework() {
  local platform="$1" object="$2" swiftmodule="$3" framework="$4"
  rm -rf "$framework"
  local contents="$framework"
  if [ "$platform" = "macos" ] || [ "$platform" = "maccatalyst" ]; then
    contents="$framework/Versions/A"
    mkdir -p "$contents/Resources"
    write_info_plist "$contents/Resources/Info.plist"
  else
    mkdir -p "$contents"
    write_info_plist "$contents/Info.plist"
  fi
  mkdir -p "$contents/Modules"
  libtool -static -o "$contents/$MODULE" "$object"
  cp -R "$swiftmodule" "$contents/Modules/"
  # Ship only textual interfaces so any compiler version can import the module.
  find "$contents/Modules" \( -name "*.swiftmodule" -type f -o -name "Project" -type d \) -prune -exec rm -rf {} +
  if [ "$contents" != "$framework" ]; then
    ln -s A "$framework/Versions/Current"
    ln -s "Versions/Current/$MODULE" "$framework/$MODULE"
    ln -s Versions/Current/Modules "$framework/Modules"
    ln -s Versions/Current/Resources "$framework/Resources"
  fi
}

rm -rf "$BUILD/archives" "$BUILD/frameworks" "$BUILD/logs" "$OUTPUT" "$OUTPUT.zip"
mkdir -p "$BUILD/archives" "$BUILD/frameworks" "$BUILD/logs"

FRAMEWORK_ARGS=()
cd "$ROOT"
for platform in "${PLATFORMS[@]}"; do
  destination="$(destination_for "$platform")"
  archive="$BUILD/archives/$platform.xcarchive"
  derived="$BUILD/DerivedData/$platform"
  log="$BUILD/logs/$platform.log"
  echo "==> Archiving $platform"
  if ! xcodebuild archive \
      -scheme "$MODULE" \
      -destination "$destination" \
      -archivePath "$archive" \
      -derivedDataPath "$derived" \
      SKIP_INSTALL=NO \
      BUILD_LIBRARY_FOR_DISTRIBUTION=YES > "$log" 2>&1; then
    if grep -qE "is not installed|Unable to find a destination" "$log"; then
      echo "warning: skipping $platform (SDK/platform not installed, see $log)"
      continue
    fi
    echo "error: archive failed for $platform, see $log" >&2
    tail -n 30 "$log" >&2
    exit 1
  fi

  object="$(find "$archive/Products" -name "$MODULE.o" | head -n 1)"
  swiftmodule="$(find "$derived/Build/Intermediates.noindex/ArchiveIntermediates" -type d -name "$MODULE.swiftmodule" -path "*BuildProductsPath*" | head -n 1)"
  if [ -z "$object" ] || [ -z "$swiftmodule" ]; then
    echo "error: could not find $MODULE.o or $MODULE.swiftmodule for $platform" >&2
    exit 1
  fi

  framework="$BUILD/frameworks/$platform/$MODULE.framework"
  make_framework "$platform" "$object" "$swiftmodule" "$framework"
  FRAMEWORK_ARGS+=(-framework "$framework")
done

if [ "${#FRAMEWORK_ARGS[@]}" -eq 0 ]; then
  echo "error: no platform could be built" >&2
  exit 1
fi

echo "==> Creating $OUTPUT"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$OUTPUT"

(cd "$BUILD" && ditto -c -k --sequesterRsrc --keepParent "$MODULE.xcframework" "$MODULE.xcframework.zip")
echo "==> $OUTPUT.zip"
echo "checksum: $(swift package compute-checksum "$OUTPUT.zip")"
```

- [ ] **Step 2: Make it executable and run it**

Run: `chmod +x scripts/build-xcframework.sh && scripts/build-xcframework.sh`
Expected: one `==> Archiving <platform>` line per platform. Platforms whose Xcode component isn't installed print `warning: skipping <platform> (SDK/platform not installed ...)`. The run ends with `xcframework successfully written out to: .../build/SwiftOSLogger.xcframework` and a `checksum:` line. With only the iOS and macOS components installed, the slices are `ios-arm64`, `ios-arm64_x86_64-simulator`, `ios-arm64_x86_64-maccatalyst` and `macos-arm64_x86_64`. Takes about 1–2 minutes.

- [ ] **Step 3: Verify the XCFramework is consumable**

Create `build/consumer/main.swift` (it's under the ignored `build/` folder, so it won't be committed):

```swift
import Foundation
import SwiftOSLogger

final class Demo: Loggable {
    func run() { log.warning("hello from xcframework") }
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try FileDestination(configuration: FileDestinationConfiguration(directory: dir, maxLinesPerFile: 2))
OSLogger.shared.configure { $0.minLevel = .trace; $0.destinations = [ConsoleDestination(), file] }
Demo().run()
OSLogger.shared.info("second"); OSLogger.shared.error("third")
OSLogger.shared.flush()
for url in file.logFileURLs() { print("--- \(url.lastPathComponent)"); print(try String(contentsOf: url, encoding: .utf8)) }
```

Run:
```bash
cd build/consumer
SLICE=$(ls -d ../SwiftOSLogger.xcframework/macos-*)
swiftc main.swift -F "$SLICE" -o demo && ./demo "$PWD/out"
SIM=$(ls -d ../SwiftOSLogger.xcframework/ios-*-simulator)
xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -F "$SIM" main.swift && echo ios-ok
cd ../..
```
Expected:
- Three console lines, the first ending in `[Demo] main.swift:5 Demo.run() - hello from xcframework`.
- Two log files, each starting with the `# ==== SwiftOSLogger Log File ====` header. The first holds 2 entries and the second holds 1.
- Then `ios-ok`.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-xcframework.sh
git commit -m "build: add static XCFramework build script"
```

---

### Task 10: README, spec sync and final verification

**Files:**
- Create: `README.md (replace the existing 2-line file)`
- Modify: `docs/superpowers/specs/2026-09-15-swiftoslogger-design.md`

**Interfaces:**
- Consumes: every public API from Tasks 1–9. The README snippets were typechecked against the built module while the plan was written.

- [ ] **Step 1: Replace README.md**

`README.md`:

````markdown
# SwiftOSLogger

A logging framework for Apple platforms built on Apple's unified logging system ([`os.Logger`](https://developer.apple.com/documentation/os/logging)). Send every log entry to unified logging, the console and rotating log files, each with its own level and format.

```
2026-09-15 13:45:12.347 +0530 [INFO] [main:0x1a2b] [Network] NetworkManager.swift:42 NetworkManager.fetch(_:) - Request started
```

- Levels `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`, plus your own custom levels
- Destinations: unified logging (`OSLogDestination`), console (`ConsoleDestination`), files (`FileDestination`), or your own
- Every entry records date and time with milliseconds, level, thread ID and name, category, file, class, function and line
- File rotation by size, by line count and by maximum number of files
- A header at the top of each log file: logger version, app name, bundle ID, app version, process, PID, OS and device model
- Text and JSON Lines formatters, or your own
- Thread-safe; file I/O runs on a background queue
- iOS 15+, macOS 12+, tvOS 15+, watchOS 8+, visionOS 1+

## Installation

### Swift Package Manager

In Xcode choose **File › Add Package Dependencies…** and enter `https://github.com/tapanshah1/OSlogger.git`, or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tapanshah1/OSlogger.git", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "SwiftOSLogger", package: "OSlogger")]),
]
```

### XCFramework

Build a static XCFramework and drag `build/SwiftOSLogger.xcframework` into your Xcode project:

```sh
scripts/build-xcframework.sh                        # every platform whose SDK is installed
scripts/build-xcframework.sh ios ios-simulator      # only some platforms
```

The script also writes `build/SwiftOSLogger.xcframework.zip` and prints its checksum, for use in a `.binaryTarget`.

## Quick start

```swift
import SwiftOSLogger

let log = OSLogger(subsystem: "com.acme.app", category: "Network")
log.info("Request started")
log.error("Request failed: \(error)")
```

By default a logger sends entries at `.debug` and above to unified logging. To also write to the console and to files, configure the shared logger once at launch:

```swift
let fileDestination = try FileDestination(configuration: FileDestinationConfiguration(
    maxFileSize: 2 * 1024 * 1024,   // 2 MB per file
    maxLinesPerFile: 10_000,
    maxFileCount: 5
))

OSLogger.shared.configure {
    $0.minLevel = .trace
    $0.destinations = [
        OSLogDestination(minLevel: .info),
        ConsoleDestination(),
        fileDestination,
    ]
}

OSLogger.shared.notice("App launched")
```

Log messages are `@autoclosure`s: when no destination accepts the level, the string is never built.

### Class names with `Loggable`

Swift has no `#class`. Adopt `Loggable` to get a `log` property that records your type's name as the class name and the category:

```swift
final class NetworkManager: Loggable {
    func fetch() {
        log.debug("Fetching")   // [NetworkManager] NetworkManager.swift:3 NetworkManager.fetch() - Fetching
    }
}
```

Override `static var logCategory` to change the category, or `static var baseLogger` to derive from a logger other than `OSLogger.shared`. Without `Loggable`, the class name is the file name, or whatever you pass as `type:`:

```swift
log.info("Saved", type: Self.self)
```

Derived loggers share their parent's configuration:

```swift
let dbLog = OSLogger.shared.withCategory("Database")
let cacheLog = OSLogger.shared.bound(to: ImageCache.self)
```

## Levels

| Level       | Value | OSLogType  |
|-------------|------:|------------|
| `.trace`    | 100   | `.debug`   |
| `.debug`    | 200   | `.debug`   |
| `.info`     | 300   | `.info`    |
| `.notice`   | 400   | `.default` |
| `.warning`  | 500   | `.default` |
| `.error`    | 600   | `.error`   |
| `.critical` | 700   | `.fault`   |

Setting `minLevel` to `.off` disables logging. You can define custom levels:

```swift
extension LogLevel {
    static let audit = LogLevel(rawValue: 450, name: "AUDIT", emoji: "🧾", osLogType: .default)
}

log.log(.audit, "User exported data")
```

Filtering happens twice: first against the logger's `minLevel`, then against each destination's `minLevel`.

## Destinations

### `OSLogDestination`

Sends entries to unified logging through `os.Logger`, using the entry's subsystem and category. You can read them in Xcode's console, in Console.app, or from the terminal:

```sh
log stream --level debug --predicate 'subsystem == "com.acme.app"'
```

```swift
OSLogDestination(minLevel: .trace, privacy: .public)   // .public, .private or .auto
```

Its default formatter leaves out the date, level and category, because unified logging records those already.

> **Privacy note:** privacy applies to the whole message. The framework passes `os.Logger` a finished `String`, not an interpolation literal, so per-value privacy markers are not possible.

### `ConsoleDestination`

Prints to standard output (or standard error), with an emoji for each level by default:

```swift
ConsoleDestination(minLevel: .debug, output: .standardError)
```

> Output from `OSLogDestination` already appears in Xcode's console. If you enable both, every entry appears twice there.

### `FileDestination`

```swift
let files = try FileDestination(
    configuration: FileDestinationConfiguration(
        directory: FileDestinationConfiguration.defaultDirectory,  // <Caches>/Logs
        fileNamePrefix: "log",
        fileExtension: "log",
        maxFileSize: 5 * 1024 * 1024,     // nil = unlimited
        maxLinesPerFile: nil,             // nil = unlimited
        maxFileCount: 10,                 // nil = unlimited; oldest deleted
        newFilePerLaunch: false,          // false = append to newest file if under limits
        includeHeader: true,
        customHeaderFields: ["Environment": "staging"],
        bufferSize: 32 * 1024,
        flushLevel: .error,               // entries >= .error are written immediately
        flushOnAppLifecycle: true         // flush on background / terminate
    ),
    minLevel: .debug,
    formatter: JSONLogFormatter(),
    onInternalError: { error in print("File logging failed: \(error)") }
)
```

**Rotation.** A new file is started before an entry would push the current file past `maxFileSize`, or once the file holds `maxLinesPerFile` entries (header lines don't count). An entry larger than `maxFileSize` still gets written, into its own file. After a new file is created, the oldest files are deleted until at most `maxFileCount` remain. The current file is never deleted.

**File names** are `<prefix>_yyyy-MM-dd_HH-mm-ss-SSS.<extension>` in UTC, so sorting by name sorts from oldest to newest.

**Header.** Each new file starts with:

```
# ==================== SwiftOSLogger Log File ====================
# Logger:          SwiftOSLogger 1.0.0
# Application:     MyApp
# Bundle ID:       com.acme.myapp
# App Version:     2.3.1 (145)
# Process:         MyApp
# PID:             4821
# OS:              iOS 18.2
# Device Model:    iPhone16,2
# File Created:    2026-09-15 13:45:12.347 +0530
# File Index:      3
# Rotation:        maxFileSize=5242880 bytes, maxLinesPerFile=unlimited, maxFileCount=10
# Environment:     staging
# ================================================================
```

**Reading and sharing logs:**

```swift
let urls = files.logFileURLs()          // flushes, then returns files oldest first
let activityVC = UIActivityViewController(activityItems: urls, applicationActivities: nil)

files.deleteAllLogFiles()
OSLogger.shared.flush()                 // flush every destination, e.g. before a crash report
```

**Errors.** Logging never throws. If a file write fails, the error goes to `onInternalError` and the destination retries with a new file. If the retry fails too, file logging turns itself off for the rest of the run. `init` throws only when the log directory cannot be created.

> iOS may clear `Caches` when the device is low on storage. If your logs must survive that, use a folder under Application Support.

## Formatters

`TextLogFormatter` lets you turn each part of the line on or off:

```swift
TextLogFormatter(
    dateFormat: "HH:mm:ss.SSS",
    timeZone: .current,
    includeDate: true, includeEmoji: false, includeLevel: true, includeThread: true,
    includeSubsystem: false, includeCategory: true, includeFileAndLine: true,
    includeClassName: true, includeFunction: true
)
```

`JSONLogFormatter` writes one JSON object per line:

```json
{"category":"Network","class":"NetworkManager","file":"NetworkManager.swift","function":"fetch(_:)","isMainThread":true,"level":"INFO","levelValue":300,"line":42,"message":"Request started","pid":4821,"subsystem":"com.acme.app","threadID":6699,"threadName":"main","timestamp":"2026-09-15T08:15:12.347Z"}
```

To write your own formatter:

```swift
struct CompactFormatter: LogFormatter {
    func format(_ entry: LogEntry) -> String {
        "\(entry.level.name.prefix(1)) \(entry.className).\(entry.function):\(entry.line) \(entry.message)"
    }
}
```

## Custom destinations

```swift
final class InMemoryDestination: LogDestination, @unchecked Sendable {
    let minLevel: LogLevel = .warning
    let formatter: any LogFormatter = TextLogFormatter(includeThread: false)
    private let lock = NSLock()
    private(set) var lines: [String] = []

    func write(_ entry: LogEntry, formatted: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(formatted)
    }
}
```

`write(_:formatted:)` runs on the thread that logged the entry, so keep it fast and thread-safe. Hand any slow work off to your own queue.

## License

MIT. See [LICENSE](LICENSE).
````

- [ ] **Step 2: Sync the spec with the prototyping decisions**

Edit `docs/superpowers/specs/2026-09-15-swiftoslogger-design.md`:
- **§3:** drop the `SwiftOSLoggerDynamic` product sentence. Add `Support/DateFormatterCache.swift` to the layout.
- **§4.4:** add `static var baseLogger: OSLogger { get }` (default `.shared`) to `Loggable`, and change `log` to derive from `baseLogger`.
- **§6.3 / §7:** file name timestamps are UTC. `FileDestinationError` lives in `LogFileManager.swift`.
- **§9:** the failure counter resets only after a successful append.
- **§10:** replace the archive description. The script archives the `SwiftOSLogger` scheme, builds a static framework from the archived `SwiftOSLogger.o` with `libtool -static`, and copies only the `.swiftinterface`/`.swiftdoc`/`.abi.json` files into `Modules/`. macOS and Mac Catalyst slices use a versioned (`Versions/A`) bundle. Add `maccatalyst` to the platform list.
- **Status line:** set to `Implemented`.

- [ ] **Step 3: Full verification**

```bash
swift build 2>&1 | grep -E "warning|error" ; echo "build-checked"
swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests" | tail -1
xcodebuild build -scheme SwiftOSLogger -destination 'generic/platform=iOS Simulator' -quiet && echo ios-sim-ok
xcodebuild build -scheme SwiftOSLogger -destination 'generic/platform=macOS,variant=Mac Catalyst' -quiet && echo catalyst-ok
for t in "iphonesimulator arm64-apple-ios15.0-simulator" "macosx arm64-apple-macos12.0" "watchsimulator arm64-apple-watchos8.0-simulator" "appletvsimulator arm64-apple-tvos15.0-simulator" "xrsimulator arm64-apple-xros1.0-simulator"; do
  set -- $t
  echo "== $2"
  xcrun --sdk "$1" swiftc -typecheck -module-name SwiftOSLogger -target "$2" -swift-version 6 $(find Sources -name "*.swift")
done
```
Run this block with `bash` (under zsh, `set -- $t` doesn't split words). Expected:
- `build-checked` with no warning lines above it.
- `Executed 60 tests, with 0 failures`, then `ios-sim-ok` and `catalyst-ok`.
- Each `== <target>` header followed by no diagnostics.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-09-15-swiftoslogger-design.md
git commit -m "docs: add README and sync spec with implementation"
```

