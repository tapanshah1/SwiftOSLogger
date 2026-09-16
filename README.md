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

## Requirements

| Requirement | Minimum |
|-------------|---------|
| iOS / iPadOS | 15.0 |
| macOS | 12.0 (Mac Catalyst 15.0) |
| tvOS | 15.0 |
| watchOS | 8.0 |
| visionOS | 1.0 |
| Swift | 5.9 |
| Xcode | 15.0 |
| Dependencies | None |

The Swift and Xcode minimums come from the package's `swift-tools-version: 5.9`. The package is built and tested with Xcode 26 and Swift 6.2, and the library compiles without warnings in both Swift 5 and Swift 6 language modes.

Building the XCFramework with `scripts/build-xcframework.sh` also needs Xcode's platform components (Xcode › Settings › Components) for every platform you want a slice for. Platforms that aren't installed are skipped.

## Installation

### Swift Package Manager

In Xcode choose **File › Add Package Dependencies…** and enter `https://github.com/tapanshah1/SwiftOSLogger.git`, or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tapanshah1/SwiftOSLogger.git", from: "1.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "SwiftOSLogger", package: "SwiftOSLogger")]),
]
```

### XCFramework

Build a static XCFramework and drag `build/SwiftOSLogger.xcframework` into your Xcode project:

```sh
scripts/build-xcframework.sh                        # every platform whose SDK is installed
scripts/build-xcframework.sh ios ios-simulator      # only some platforms
```

The script also writes `build/SwiftOSLogger.xcframework.zip` and prints its checksum, for use in a `.binaryTarget`.

The XCFramework is static: in your target's **Frameworks, Libraries, and Embedded Content**, set it to **Do Not Embed**.

Each slice needs its platform installed in Xcode (Xcode › Settings › Components), and the visionOS simulator needs an Apple Silicon Mac; platforms that are missing are skipped with a warning. The prebuilt archive attached to a release therefore covers **iOS, iOS Simulator, Mac Catalyst and macOS**. For tvOS, watchOS or visionOS, either install those components and run the script yourself, or use Swift Package Manager, which builds from source on every supported platform.

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
        log.debug("Fetching")
    }
}
```

With `ConsoleDestination()` this prints:

```
2026-09-15 13:45:12.347 +0530 🐞 [DEBUG] [main:0x1a2b] [NetworkManager] NetworkManager.swift:3 NetworkManager.fetch() - Fetching
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

> **Privacy note:** the default privacy is `.public`, so message text is visible in Console.app, `log stream` and sysdiagnoses. Use `.private` (or `.auto`) if messages may contain sensitive data.
>
> Privacy applies to the whole message. The framework passes `os.Logger` a finished `String`, not an interpolation literal, so per-value privacy markers are not possible.

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
        directory: FileDestinationConfiguration.defaultDirectory,  // <Caches>/<bundle ID or process name>/Logs
        fileNamePrefix: "log",
        fileExtension: "log",
        maxFileSize: 5 * 1024 * 1024,     // nil = unlimited
        maxLinesPerFile: nil,             // nil = unlimited
        maxFileCount: 10,                 // nil = unlimited; oldest deleted
        newFilePerLaunch: false,          // false = append to newest file if under limits
        includeHeader: true,
        customHeaderFields: ["Environment": "staging"],
        bufferSize: 32 * 1024,
        maxPendingBytes: 4 * 1024 * 1024, // memory cap for entries waiting to be written; nil = unlimited
        flushLevel: .error,               // entries >= .error are written immediately
        flushOnAppLifecycle: true         // flush on background / terminate
    ),
    minLevel: .debug,
    formatter: JSONLogFormatter(),
    onInternalError: { [weak self] error in self?.report(error) }   // capture weakly: see Memory
)
```

**Rotation.** A new file is started before an entry would push the current file past `maxFileSize`, or once the file holds `maxLinesPerFile` entries (header lines don't count). An entry larger than `maxFileSize` still gets written, into its own file. After a new file is created, the oldest files are deleted until at most `maxFileCount` remain. The current file is never deleted.

`maxLinesPerFile` counts entries, not lines. When the app relaunches and appends to an existing file, the count is rebuilt by counting lines in the file, so multi-line messages make it approximate.

**File names** are `<prefix>_yyyy-MM-dd_HH-mm-ss-SSS.<extension>` in UTC, so sorting by name sorts from oldest to newest.

**One destination per folder.** Never point two `FileDestination`s, in the same process or in different ones, at the same `directory` with the same `fileNamePrefix`. They would write into each other's files and delete each other's files under `maxFileCount`. The default directory includes the bundle ID (or process name), so separate apps don't share it.

**Buffering.** Entries are kept in memory until `bufferSize` bytes are buffered, an entry at or above `flushLevel` arrives, or `flush()` is called. Apps also flush when they move to the background or terminate. Command-line tools and other processes without a UIKit/AppKit app lifecycle get no such notification: call `flush()` (or `OSLogger.shared.flush()`) before exiting, or the last buffered entries are lost.

**Memory and dropped entries.** Logging never waits for the disk. Entries wait in memory for a background writer, up to `maxPendingBytes` (4 MB by default). If your app logs faster than the writer can keep up, for example in a tight loop on several threads, new entries are dropped instead of using more memory. When the writer catches up it writes a line like:

```
# SwiftOSLogger dropped 1532 entries: more than 4194304 bytes were waiting to be written
```

A single entry is always accepted when nothing else is waiting, however large it is. Set `maxPendingBytes: nil` to never drop entries, at the cost of unbounded memory during a log storm.

**Header.** Each new file starts with:

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

**Errors.** Logging never throws. If creating or writing a log file fails, the error goes to `onInternalError`, the entries still in the buffer are dropped, and the next entry starts a new file. If another failure happens before any buffered entries have reached disk again, file logging turns itself off for the rest of the run. `onInternalError` is called once per kind of error, asynchronously on a background queue, so it may call back into the destination (for example `flush()` or `logFileURLs()`). `init` throws only when the log directory cannot be created.

> iOS may clear `Caches` when the device is low on storage. If your logs must survive that, use a folder under Application Support.

## Memory

- **Capture weakly in `onInternalError`.** The destination keeps its handler alive. If the handler captures an object that owns the destination (or the logger using it), neither is ever freed. Use `[weak self]`.
- **Use a fixed set of categories.** `OSLogDestination` keeps one `os.Logger` per subsystem and category for the life of the destination. Names like `withCategory("Network")` are fine; names built from IDs, like `withCategory("request-\(id)")`, grow that cache without limit.
- **Removing a destination frees it.** Once no logger's configuration refers to it, a `FileDestination` finishes writing any waiting entries, closes its file and is released.
- **Waiting entries are capped.** See *Memory and dropped entries* under `FileDestination`.

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
    private var storage: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func write(_ entry: LogEntry, formatted: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(formatted)
    }
}
```

`write(_:formatted:)` runs on the thread that logged the entry, so keep it fast and thread-safe. Hand any slow work off to your own queue.

## License

MIT. See [LICENSE](LICENSE).
