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
