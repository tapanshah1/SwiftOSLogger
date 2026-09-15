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
