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
/// Errors never reach the caller of `log`. An I/O failure is reported through
/// `onInternalError`, the buffered entries are dropped and the next entry starts a new file.
/// If another failure happens before any buffered bytes have reached disk again, the
/// destination disables itself for the rest of the process.
public final class FileDestination: LogDestination, @unchecked Sendable {
    public let minLevel: LogLevel
    public let formatter: any LogFormatter
    public let configuration: FileDestinationConfiguration

    private let onInternalError: (@Sendable (Error) -> Void)?
    private let queue = DispatchQueue(label: "com.swiftoslogger.file-destination", qos: .utility)
    private let internalLogger = Logger(subsystem: "SwiftOSLogger", category: "Internal")

    // Confined to `queue`.
    private let manager: LogFileManager
    private var consecutiveFailures = 0
    private var isDisabled = false
    private var reportedErrors = Set<String>()

    // Written only in init/deinit.
    private var observers: [NSObjectProtocol] = []

    /// - Parameter onInternalError: Called once per distinct kind of I/O failure. It is called
    ///   asynchronously on a background queue, so it may call back into this destination
    ///   (for example `flush()` or `logFileURLs()`).
    /// - Throws: `FileDestinationError.cannotCreateDirectory` if the log directory cannot be created.
    public convenience init(
        configuration: FileDestinationConfiguration = FileDestinationConfiguration(),
        minLevel: LogLevel = .trace,
        formatter: any LogFormatter = TextLogFormatter(),
        onInternalError: (@Sendable (Error) -> Void)? = nil
    ) throws {
        self.init(manager: try LogFileManager(configuration: configuration),
                  minLevel: minLevel, formatter: formatter, onInternalError: onInternalError)
    }

    /// Test seam: uses a prepared `manager`, whose configuration becomes this destination's.
    init(
        manager: LogFileManager,
        minLevel: LogLevel = .trace,
        formatter: any LogFormatter = TextLogFormatter(),
        onInternalError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.configuration = manager.configuration
        self.minLevel = minLevel
        self.formatter = formatter
        self.onInternalError = onInternalError
        self.manager = manager
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
            perform { try manager.append(formatted, flushImmediately: flushImmediately) }
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
    ///
    /// `operation` returns `true` when bytes reached disk. Only then does the failure count
    /// reset: an append that only buffered, or a flush with nothing to write, can't hide a
    /// file that is still failing.
    private func perform(_ operation: () throws -> Bool) {
        do {
            if try operation() {
                consecutiveFailures = 0
            }
        } catch {
            consecutiveFailures += 1
            report(error)
            manager.discardCurrentFile()
            if consecutiveFailures >= 2 {
                isDisabled = true
                internalLogger.fault("FileDestination disabled after repeated failures in \(self.configuration.directory.path, privacy: .public)")
            }
        }
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        let key = "\(String(reflecting: type(of: error)))|\(nsError.domain)|\(nsError.code)"
        guard reportedErrors.insert(key).inserted else { return }
        internalLogger.fault("FileDestination error: \(String(describing: error), privacy: .public)")
        guard let onInternalError else { return }
        // Async, off `queue`: a handler that calls `flush()` etc. would otherwise deadlock.
        DispatchQueue.global(qos: .utility).async {
            onInternalError(error)
        }
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
