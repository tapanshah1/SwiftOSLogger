# SwiftOSLogger — Design Spec

**Date:** 2026-09-15
**Status:** Implemented

## 1. Purpose

A public, open-source Swift logging framework for Apple platforms, built on Apple's unified logging system (`os.Logger`, see <https://developer.apple.com/documentation/oslog> and <https://developer.apple.com/documentation/os/logging>). It gives developers one API that sends each log entry to any combination of:

- Apple unified logging (Console.app, `log stream`, Xcode console)
- the standard output console
- rotating log files on disk

Every entry carries rich call-site metadata: date/time with milliseconds, level, thread ID/name, category, file name, class name, function name and line number. Each log file starts with a header describing the logger, the application and the process.

## 2. Goals and non-goals

**Goals**
- Configurable log levels, including developer-defined custom levels.
- Destinations: OSLog, Console, File, plus developer-supplied custom destinations.
- File rotation by size, by line count, and by maximum number of files (oldest deleted).
- A file header on every newly created log file (logger version, app name, bundle ID, app version/build, process name, PID, OS, device model, creation date, file index, rotation limits, custom fields).
- Pluggable formatting (text by default, JSON Lines included, custom formatters allowed).
- Safe under concurrency; logging never blocks the caller on disk I/O and never crashes or throws.
- Distributed via Swift Package Manager and as a prebuilt XCFramework.

**Non-goals (v1)**
- Reading logs back via `OSLogStore`.
- Remote/network upload destination (possible via custom `LogDestination`).
- Compression or encryption of rotated files.
- swift-log (`LogHandler`) integration.
- CocoaPods / Carthage.

## 3. Platforms and packaging

- Module / product name: **`SwiftOSLogger`** (`import SwiftOSLogger`).
- Minimum platforms: iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1.
- `swift-tools-version: 5.9`; no third-party dependencies. Strict concurrency checking enabled for the target.
- Library product is `.library(name: "SwiftOSLogger", targets: ["SwiftOSLogger"])` (automatic linkage). An earlier design added a second `SwiftOSLoggerDynamic` product for the XCFramework script; it was dropped because an SPM dynamic product archives as `SwiftOSLoggerDynamic.framework`, which doesn't match the module name. The script instead archives the normal `SwiftOSLogger` scheme and assembles a static framework itself (see §10).

### Layout

```
Package.swift
Sources/SwiftOSLogger/
  Core/         OSLogger.swift, LogLevel.swift, LogEntry.swift, Loggable.swift, LoggerConfiguration.swift
  Destinations/ LogDestination.swift, OSLogDestination.swift, ConsoleDestination.swift, FileDestination.swift
  Formatting/   LogFormatter.swift, TextLogFormatter.swift, JSONLogFormatter.swift
  File/         FileDestinationConfiguration.swift, LogFileManager.swift, LogFileHeader.swift
  Support/      ThreadInfo.swift, AppInfo.swift, Lock.swift, Version.swift, DateFormatterCache.swift
Tests/SwiftOSLoggerTests/
scripts/build-xcframework.sh
README.md
```

## 4. Public API

### 4.1 `LogLevel`

```swift
public struct LogLevel: Comparable, Hashable, Sendable {
    public let rawValue: Int
    public let name: String        // e.g. "INFO"
    public let emoji: String       // used by ConsoleDestination when enabled
    public let osLogType: OSLogType
    public init(rawValue: Int, name: String, emoji: String = "", osLogType: OSLogType)
}
```

Presets (ordering by `rawValue`):

| Preset     | rawValue | name     | OSLogType  |
|------------|---------:|----------|------------|
| `.trace`   | 100      | TRACE    | `.debug`   |
| `.debug`   | 200      | DEBUG    | `.debug`   |
| `.info`    | 300      | INFO     | `.info`    |
| `.notice`  | 400      | NOTICE   | `.default` |
| `.warning` | 500      | WARNING  | `.default` |
| `.error`   | 600      | ERROR    | `.error`   |
| `.critical`| 700      | CRITICAL | `.fault`   |

Comparison and equality are based on `rawValue` only. `LogLevel.off` (`Int.max`) disables output when used as a minimum level. `OSLogType` is not `Sendable`-annotated in all SDKs; the struct stores its `rawValue` (`UInt8`) and exposes `osLogType` as a computed property.

### 4.2 `OSLogger`

```swift
public final class OSLogger: @unchecked Sendable {   // all mutable state lock-protected
    public static let shared: OSLogger

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "SwiftOSLogger",
                category: String = "Default",
                configuration: LoggerConfiguration = .init())

    public let subsystem: String
    public let category: String
    public var configuration: LoggerConfiguration { get set }
    public func configure(_ update: (inout LoggerConfiguration) -> Void)

    /// Returns a logger sharing this logger's configuration storage and destinations,
    /// with a different category and/or bound type.
    public func withCategory(_ category: String) -> OSLogger
    public func bound(to type: Any.Type) -> OSLogger

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String,
                    type: Any.Type? = nil,
                    fileID: String = #fileID, file: String = #filePath,
                    function: String = #function, line: Int = #line)

    // Convenience: trace, debug, info, notice, warning, error, critical
    // Same parameters as log(_:_:...) minus the level.

    public func flush()                          // blocks until every destination has flushed
}
```

- `configuration` is a value type; reads take a snapshot under the lock.
- `configure` is atomic: writers (`configure` and the `configuration` setter) are serialized by a separate update lock. `configure` copies the value out, runs `update` without the value lock held, then stores the result, so `update` may log and read `configuration` (both see the value from before the update). Calling `configure` or setting `configuration` on the same storage from inside `update` is not allowed.
- Loggers made by `withCategory` / `bound(to:)` share the parent's configuration storage, so `configure` on either affects both.
- If `level < configuration.minLevel`, or every destination filters it out, the message autoclosure is **not** evaluated.

### 4.3 `LoggerConfiguration`

```swift
public struct LoggerConfiguration: Sendable {
    public var minLevel: LogLevel = .debug
    public var destinations: [any LogDestination] = [OSLogDestination()]
    public init(minLevel: LogLevel = .debug, destinations: [any LogDestination] = [OSLogDestination()])
}
```

### 4.4 `Loggable`

```swift
public protocol Loggable {
    static var logCategory: String { get }          // default: String(describing: Self.self)
    static var baseLogger: OSLogger { get }         // default: .shared
}
public extension Loggable {
    static var log: OSLogger { get }   // baseLogger.withCategory(logCategory).bound(to: Self.self)
    var log: OSLogger { get }
}
```

### 4.5 Class name resolution

Swift has no `#class`. `LogEntry.className` is resolved in order:
1. the `type:` argument, if given;
2. the type bound via `bound(to:)` / `Loggable`;
3. the file name from `#fileID` without the `.swift` extension.

Type names are produced by `String(describing:)` (unqualified, generic parameters retained).

### 4.6 `LogEntry`

```swift
public struct LogEntry: Sendable {
    public let level: LogLevel
    public let message: String
    public let date: Date
    public let subsystem: String
    public let category: String
    public let fileID: String      // "MyApp/NetworkManager.swift"
    public let fileName: String    // "NetworkManager.swift"
    public let filePath: String
    public let className: String
    public let function: String
    public let line: Int
    public let threadID: UInt64    // pthread_threadid_np
    public let threadName: String  // "main", Thread name, dispatch queue label, or ""
    public let isMainThread: Bool
    public let processID: Int32
}
```

All metadata is captured synchronously on the calling thread (works in `async` contexts because it uses `pthread` / `dispatch` APIs, not `Thread.current`).

## 5. Formatting

```swift
public protocol LogFormatter: Sendable {
    func format(_ entry: LogEntry) -> String
}
```

### 5.1 `TextLogFormatter` (default)

Default output:

```
2026-09-15 13:45:12.347 +0530 [INFO] [main:0x1a2b] [Network] NetworkManager.swift:42 NetworkManager.fetch(_:) - Request started
```

Options (all `var`, all default on unless noted):
- `dateFormat: String = "yyyy-MM-dd HH:mm:ss.SSS Z"`, `timeZone: TimeZone = .current` (there is no locale option: dates are always formatted with the `en_US_POSIX` locale)
- `includeDate`, `includeLevel`, `includeThread`, `includeCategory`, `includeFileAndLine`, `includeFunction` (`Bool`)
- `includeClassName: Bool`: when true, the function is printed as `ClassName.function`
- `includeSubsystem: Bool = false`, `includeEmoji: Bool = false`

Segments that are off are omitted with their separators. The thread segment is `name:0xID`, or just `0xID` when the name is empty. Date formatting uses a cached `DateFormatter` guarded by a lock.

### 5.2 `JSONLogFormatter`

One JSON object per line (JSON Lines), keys sorted, no pretty-printing. Keys: `timestamp` (ISO-8601 with fractional seconds), `level`, `levelValue`, `message`, `subsystem`, `category`, `file`, `line`, `class`, `function`, `threadID`, `threadName`, `isMainThread`, `pid`.

## 6. Destinations

```swift
public protocol LogDestination: Sendable {
    var minLevel: LogLevel { get }
    var formatter: any LogFormatter { get }
    func write(_ entry: LogEntry, formatted: String)
    func flush()
}
public extension LogDestination { func flush() {} }
```

`OSLogger` checks `entry.level >= destination.minLevel`, formats the entry with that destination's formatter (once per destination), then calls `write`.

### 6.1 `OSLogDestination`

- `init(minLevel: LogLevel = .trace, privacy: Privacy = .public, formatter: any LogFormatter = TextLogFormatter.osLogDefault)`
- Caches one `os.Logger` per `(subsystem, category)` pair in a lock-protected dictionary.
- Writes `logger.log(level: entry.level.osLogType, "\(formatted, privacy: .public)")` (or `.private`, `.auto`).
- `TextLogFormatter.osLogDefault` omits date, level and subsystem/category, since unified logging records those already. It keeps thread, file:line, class.function and the message.
- Limitation (documented): privacy applies to the whole message, because the message is a runtime `String` rather than an `OSLogMessage` interpolation literal.

### 6.2 `ConsoleDestination`

- `init(minLevel: LogLevel = .trace, formatter: any LogFormatter = TextLogFormatter(includeEmoji: true), output: Output = .standardOutput)`, where `Output` is `.standardOutput` or `.standardError`.
- Writes `formatted + "\n"` with the throwing `FileHandle.standardOutput/standardError.write(contentsOf:)` (errors ignored, so a closed stream can't crash the process), serialized by a lock so lines never interleave.
- README warns that `OSLogDestination` output already shows in the Xcode console, so enabling both duplicates lines in Xcode.

### 6.3 `FileDestination`

`init(configuration: FileDestinationConfiguration = .init(), minLevel: LogLevel = .trace, formatter: any LogFormatter = TextLogFormatter(), onInternalError: (@Sendable (Error) -> Void)? = nil) throws`. It throws only if the directory cannot be created, with a `FileDestinationError` defined in `LogFileManager.swift`. `onInternalError` is called asynchronously on a background (`.utility`) global queue, so a handler may call back into the destination (`flush()`, `logFileURLs()`, …) without deadlocking its private queue.

```swift
public struct FileDestinationConfiguration: Sendable {
    public var directory: URL                      // default: <Caches>/<bundle ID ?? process name>/Logs
    public var fileNamePrefix: String = "log"
    public var fileExtension: String = "log"
    public var maxFileSize: Int? = 5 * 1024 * 1024 // bytes; nil = unlimited
    public var maxLinesPerFile: Int? = nil         // nil = unlimited
    public var maxFileCount: Int? = 10             // nil = unlimited
    public var newFilePerLaunch: Bool = false
    public var includeHeader: Bool = true
    public var customHeaderFields: [String: String] = [:]   // written sorted by key
    public var bufferSize: Int = 32 * 1024         // bytes buffered before a disk write
    public var maxPendingBytes: Int? = 4 * 1024 * 1024 // cap on entries waiting for the queue; nil = unlimited
    public var flushLevel: LogLevel = .error       // entries >= this flush immediately
    public var flushOnAppLifecycle: Bool = true
}
```

Public helpers on `FileDestination`: `currentLogFileURL: URL?`, `logFileURLs() -> [URL]` (oldest first), `deleteAllLogFiles()`, `flush()`.

Also exposed as a static helper on `FileDestination`: `static func logFileURLs(in directory: URL, prefix: String, extension: String) -> [URL]`.

The default directory includes `Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName`, because unsandboxed macOS apps and command-line tools share `~/Library/Caches`; a shared `<Caches>/Logs` would let processes append into and delete each other's files. Two `FileDestination`s must never use the same directory and file name prefix.

## 7. File management and rotation (`LogFileManager`)

Internal type, used only from the destination's private serial `DispatchQueue`.

**File naming:** `<prefix>_yyyy-MM-dd_HH-mm-ss-SSS.<ext>`, using UTC and the `en_US_POSIX` locale, so name order stays chronological across time zone and DST changes. (The header's `File Created` line stays in local time.) If the name already exists (same millisecond), `_1`, `_2`, … is appended. Files are listed by filtering the directory for `<prefix>_<date>_<time>[_<N>].<ext>` and sorting by the timestamp part of the name (lexicographic == chronological), with ties broken by the numeric `_N` sequence suffix (no suffix counts as 0).

**Opening at startup:**
- If `newFilePerLaunch == false` and a latest file exists and is under both limits, append to it. The current size and line count both come from a single chunked read of the file: the size is the number of bytes read, and the line count is the number of `\n`-terminated lines after the leading `#` header lines. No header is written.
- Otherwise, create a new file.

**Creating a file:** recreate the directory if it was deleted while running (errors ignored), create the file, write the header (if `includeHeader`), set counters to the header's bytes/lines, then enforce `maxFileCount`.

**Rotation rule (checked per line, when the line is appended to the buffer):** before appending a formatted line of `b` bytes (including `\n`):
- rotate if `maxFileSize != nil && currentBodyLines > 0 && currentSize + b > maxFileSize`
- rotate if `maxLinesPerFile != nil && currentBodyLines >= maxLinesPerFile`

Here `currentBodyLines` counts log lines only, excluding header lines, so `maxLinesPerFile` means log entries per file. For appended-to existing files, header lines are identified as lines at the top starting with `#`.

A single line larger than `maxFileSize` is still written, into a fresh file, so the file stays at one entry and nothing is dropped. Rotation closes the current handle (after flushing) and creates a new file.

**Max file count:** after creating a file, if the matching file count exceeds `maxFileCount`, delete the oldest until count == `maxFileCount`. The current file is never deleted.

**Pending entries and the drop policy (in `FileDestination`):** `write` never schedules one queue block per entry. It adds the formatted line to a lock-protected pending list and schedules a single drain on the serial queue only if none is scheduled; the drain takes the whole list, appends each line to the `LogFileManager`, and repeats until the list is empty. The list is capped at `maxPendingBytes` (UTF-8 bytes plus one newline per entry): an entry that would exceed the cap is dropped and counted, except that an entry is always accepted when the list is empty. After writing a batch that had drops, the drain appends `# SwiftOSLogger dropped <N> entries: more than <maxPendingBytes> bytes were waiting to be written`. `flush()`, `currentLogFileURL` and `logFileURLs()` drain the list first; `deleteAllLogFiles()` discards it. A disabled destination still drains (and discards) so waiting memory is released. Peak memory for waiting entries is therefore about `maxPendingBytes` for the list being filled plus the batch being written.

**Buffering:** formatted lines go to an in-memory buffer on the serial queue. Rotation checks are done per line at append time (counters track the buffered bytes, not just bytes on disk). The buffer is written when it reaches `bufferSize`, when an entry `>= flushLevel` arrives, on `flush()`, on rotation, and on app lifecycle events.

**Lifecycle flush:** when `flushOnAppLifecycle` is true, observe:
- UIKit (iOS/tvOS/visionOS): `didEnterBackgroundNotification`, `willTerminateNotification`
- AppKit (macOS): `willTerminateNotification`
- WatchKit (watchOS): `WKExtension.applicationDidEnterBackgroundNotification`

The flush is `queue.sync`.

## 8. File header (`LogFileHeader`)

Each line starts with `# `, which makes the header easy to skip and to identify:

```
# ==================== SwiftOSLogger Log File ====================
# Logger:          SwiftOSLogger 1.1.0
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
# <custom key>:    <custom value>
# ================================================================
```

Sources:
- **Application name:** `CFBundleDisplayName` → `CFBundleName` → process name.
- **Bundle ID:** `Bundle.main.bundleIdentifier ?? "unknown"`.
- **App version:** `CFBundleShortVersionString` and `CFBundleVersion`.
- **Process name and PID:** `ProcessInfo.processInfo`.
- **OS:** platform name plus `operatingSystemVersionString` / `operatingSystemVersion`.
- **Device model:** `sysctlbyname("hw.model")` on macOS and Mac Catalyst (e.g. `MacBookPro18,1`), `sysctlbyname("hw.machine")` elsewhere (e.g. `iPhone16,2`). On the simulator, `SIMULATOR_MODEL_IDENTIFIER` followed by ` (Simulator)`.
- **File Index:** a 1-based counter of files created by this `FileDestination` instance during the current process (the first file it creates is 1).

## 9. Concurrency and error handling

- `OSLogger` protects its configuration box with internal `Lock`s (`os_unfair_lock` wrappers allocated on the heap): a value lock held only to copy the value in or out, and an update lock that serializes writers (see §4.2). `OSAllocatedUnfairLock` is iOS 16+, so it is not used.
- Destinations must be `Sendable`. `FileDestination` confines all file state to its private serial queue (QoS `.utility`) and marks itself `@unchecked Sendable`. Writes add to a pending list guarded by a `Lock` and schedule at most one `queue.async` drain at a time (§7); `flush()` is `queue.sync`. Logging never waits for the disk: under sustained overload entries are dropped rather than growing memory.
- **No throws or crashes from `log`.** When a file destination hits an I/O error, it:
  1. reports the error through the destination's `onInternalError` callback (once per distinct failure kind), dispatched asynchronously to a background global queue;
  2. emits one `os.Logger` fault under subsystem `SwiftOSLogger`, category `Internal`;
  3. drops the buffered bytes and creates a new file on the next write. If another failure happens before any buffered bytes have reached disk, the destination disables itself for the rest of the process.
- The failure counter behind step 3 resets only when bytes actually reach disk: `LogFileManager.append` and `flush` return `true` only when they wrote a non-empty buffer (directly, or while rotating). An append that only buffers, creating a file and writing its header, or a `flush()` with nothing to write does not reset it, so none of them can hide a destination that is still failing (for example when every buffer write fails but creating a new file still succeeds).
- `FileDestination.init` throws `FileDestinationError.cannotCreateDirectory(URL, underlying:)`.

## 10. XCFramework build

`scripts/build-xcframework.sh [platforms...]`:
- Default platforms: `ios ios-simulator maccatalyst macos tvos tvos-simulator watchos watchos-simulator visionos visionos-simulator`.
- For each platform, run `xcodebuild archive -scheme SwiftOSLogger -destination "generic/platform=<X>" -archivePath build/<X> SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES`.
- Build a static `SwiftOSLogger.framework` from the archived `SwiftOSLogger.o` with `libtool -static`, and copy only the `.swiftinterface` / `.swiftdoc` / `.abi.json` files into `Modules/` (so any compiler version can import the module). macOS and Mac Catalyst slices use a versioned (`Versions/A`) bundle.
- Run `xcodebuild -create-xcframework -framework ... -output build/SwiftOSLogger.xcframework`, then zip it and print its SHA-256 checksum (for a `binaryTarget`).
- Platforms whose SDK or runtime is missing are skipped with a warning, not a failure.

## 11. Testing

XCTest target `SwiftOSLoggerTests`, run with `swift test` on macOS. Uses a temp directory per test and a `MemoryDestination` test double.

- **LogLevel:** ordering, custom level, OSLogType mapping, `.off`.
- **OSLogger:**
  - min level filtering
  - autoclosure not evaluated when filtered
  - per-destination min level
  - `withCategory` / `bound(to:)` share configuration
  - a `configure` closure may log and read `configuration`
  - `Loggable` category and class name
  - class name resolution order
  - metadata correctness (file name, line, function, main-thread flag, thread ID non-zero)
- **TextLogFormatter:** default layout matches the documented format (fixed date/time zone), every toggle, thread segment variants.
- **JSONLogFormatter:** valid JSON per line, expected keys and values.
- **FileDestination / LogFileManager:**
  - header written with required fields and custom fields
  - rotation by size, including the oversize single line
  - rotation by line count, where the header is not counted
  - max file count deletes oldest and never the current file
  - append to existing file when under limits (line count restored); `newFilePerLaunch` creates a new file
  - buffering plus `flush()` makes content visible
  - `flushLevel` triggers immediate write
  - `logFileURLs` ordering, `deleteAllLogFiles`
  - error policy: repeated create failures disable the destination; persistent write failures disable it even with buffered appends (and an empty `flush()`) in between; `onInternalError` may call back into the destination
- **Concurrency:** 10 threads × 1,000 entries into a file destination with rotation. The total body lines across files equals 10,000 (with `maxFileCount` nil), and there are no interleaved or partial lines.
- **Build verification:** `swift build`, `swift test`, `xcodebuild build -scheme SwiftOSLogger -destination 'generic/platform=iOS Simulator'`.

## 12. Documentation

The README covers:
- installation (SPM URL, XCFramework)
- quick start and `Loggable`
- levels and custom levels
- each destination and its options
- rotation semantics
- header example
- custom formatter and destination examples
- retrieving and sharing log files
- the OSLog privacy limitation and the Xcode duplicate-output note
- viewing logs in Console.app / `log stream --predicate 'subsystem == "..."'`

Public APIs carry `///` doc comments.
