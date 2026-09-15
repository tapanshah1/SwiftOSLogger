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
