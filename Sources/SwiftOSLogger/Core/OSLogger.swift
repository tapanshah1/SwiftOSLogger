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
        get { storage.valueLock.withLock { storage.value } }
        set { storage.updateLock.withLock { storage.valueLock.withLock { storage.value = newValue } } }
    }

    /// Atomically updates the configuration: concurrent `configure` calls and setters of
    /// `configuration` never lose each other's changes.
    ///
    /// `update` may log and read `configuration`; both see the configuration from before
    /// this update. Do not call `configure` or set `configuration` on this logger, or on a
    /// logger derived from it, from inside `update`.
    public func configure(_ update: (inout LoggerConfiguration) -> Void) {
        storage.updateLock.withLock {
            var value = storage.valueLock.withLock { storage.value }
            update(&value)
            storage.valueLock.withLock { storage.value = value }
        }
    }

    /// A logger with a different category that shares this logger's configuration.
    public func withCategory(_ category: String) -> OSLogger {
        OSLogger(subsystem: subsystem, category: category, boundTypeName: boundTypeName, storage: storage)
    }

    /// A logger whose entries report `type` as their class name. Shares this logger's configuration.
    public func bound(to type: Any.Type) -> OSLogger {
        OSLogger(subsystem: subsystem, category: category, boundTypeName: TypeNameCache.name(of: type), storage: storage)
    }

    /// `withCategory(category).bound(to: type)` in one allocation (used by `Loggable`).
    func derived(category: String, boundTo type: Any.Type) -> OSLogger {
        OSLogger(subsystem: subsystem, category: category, boundTypeName: TypeNameCache.name(of: type), storage: storage)
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
        guard level < .off, level >= config.minLevel,
              config.destinations.contains(where: { level >= $0.minLevel })
        else { return }

        // Scan UTF-8 bytes: `lastIndex(of:)` on the String itself walks grapheme clusters.
        let fileName = fileID.utf8.lastIndex(of: UInt8(ascii: "/"))
            .map { String(fileID[fileID.utf8.index(after: $0)...]) } ?? fileID
        let className = type.map { TypeNameCache.name(of: $0) }
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
            processID: getpid()
        )
        for destination in config.destinations where level >= destination.minLevel {
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
    /// Guards `value`. Held only for the copy in or out, never while user code runs.
    let valueLock = Lock()
    /// Serializes writers (`configure` and the `configuration` setter), so an update can run
    /// its closure without `valueLock` held and still not lose a concurrent change.
    let updateLock = Lock()
    var value: LoggerConfiguration

    init(_ value: LoggerConfiguration) {
        self.value = value
    }
}
