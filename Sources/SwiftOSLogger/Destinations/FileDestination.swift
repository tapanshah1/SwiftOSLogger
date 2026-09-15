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
/// Memory is bounded: at most `configuration.maxPendingBytes` of entries wait for the queue.
/// When logging outpaces the disk, further entries are dropped and counted, and a
/// `# SwiftOSLogger dropped N entries` line is written once the writer catches up.
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

    // Entries waiting for `queue`. Guarded by `pendingLock`.
    private let pendingLock = Lock()
    private var pending = PendingEntries()

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
        let needsDrain = pendingLock.withLock {
            pending.add(formatted, flushImmediately: flushImmediately, maxBytes: configuration.maxPendingBytes)
        }
        if needsDrain {
            queue.async { [self] in drainPending() }
        }
    }

    /// Blocks until buffered entries are written to disk.
    public func flush() {
        queue.sync {
            drainPending()
            guard !isDisabled else { return }
            perform { try manager.flush() }
        }
    }

    // MARK: Files

    /// The file currently being written to, or `nil` before the first entry.
    public var currentLogFileURL: URL? {
        queue.sync {
            drainPending()
            return manager.currentFileURL
        }
    }

    /// All log files for this configuration, oldest first. Flushes first.
    public func logFileURLs() -> [URL] {
        queue.sync {
            drainPending()
            if !isDisabled { perform { try manager.flush() } }
            return manager.logFileURLs()
        }
    }

    /// Deletes every log file for this configuration, including entries not yet written.
    /// The next entry starts a new file.
    public func deleteAllLogFiles() {
        queue.sync {
            _ = pendingLock.withLock { pending.takeAll() }
            manager.deleteAllLogFiles()
        }
    }

    /// Log files for `prefix`/`fileExtension` in `directory`, oldest first.
    public static func logFileURLs(in directory: URL, prefix: String = "log", fileExtension: String = "log") -> [URL] {
        LogFileManager.logFileURLs(in: directory, prefix: prefix, fileExtension: fileExtension)
    }

    // MARK: Private

    /// Writes every waiting entry, then the dropped-entries notice if any were dropped.
    /// Runs on `queue` until nothing is waiting.
    private func drainPending() {
        while let batch = pendingLock.withLock({ pending.takeAll() }) {
            guard !isDisabled else { continue }   // keep draining so waiting memory is released
            for (index, line) in batch.lines.enumerated() {
                let isLast = index == batch.lines.count - 1 && batch.droppedCount == 0
                perform { try manager.append(line, flushImmediately: batch.flushImmediately && isLast) }
                if isDisabled { break }
            }
            if batch.droppedCount > 0, !isDisabled, let maxBytes = configuration.maxPendingBytes {
                let notice = "# SwiftOSLogger dropped \(batch.droppedCount) entries: "
                    + "more than \(maxBytes) bytes were waiting to be written"
                perform { try manager.append(notice, flushImmediately: batch.flushImmediately) }
            }
        }
    }

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

/// Formatted entries waiting for `FileDestination`'s queue, capped by byte count.
private struct PendingEntries {
    struct Batch {
        let lines: [String]
        let flushImmediately: Bool
        let droppedCount: Int
    }

    private var lines: [String] = []
    private var bytes = 0
    private var flushImmediately = false
    private var droppedCount = 0
    private var drainScheduled = false

    /// Adds `line` unless waiting entries would exceed `maxBytes` (it is then dropped and counted).
    /// - Returns: `true` if the caller must schedule a drain.
    mutating func add(_ line: String, flushImmediately: Bool, maxBytes: Int?) -> Bool {
        let size = line.utf8.count + 1
        if let maxBytes, !lines.isEmpty, bytes + size > maxBytes {
            droppedCount += 1
        } else {
            lines.append(line)
            bytes += size
            self.flushImmediately = self.flushImmediately || flushImmediately
        }
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// Takes everything waiting, or returns `nil` (and clears the scheduled flag) when empty.
    mutating func takeAll() -> Batch? {
        guard !lines.isEmpty || droppedCount > 0 else {
            drainScheduled = false
            return nil
        }
        let batch = Batch(lines: lines, flushImmediately: flushImmediately, droppedCount: droppedCount)
        lines = []
        bytes = 0
        flushImmediately = false
        droppedCount = 0
        return batch
    }
}
