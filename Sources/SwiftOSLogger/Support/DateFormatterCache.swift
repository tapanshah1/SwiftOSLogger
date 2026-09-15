import Foundation

/// Thread-safe date formatting keyed by format and time zone.
///
/// Numeric patterns (all the framework's own formats) go through `FastDateFormat`, which needs
/// no lock and creates no Foundation objects. Other patterns, and dates outside the fast path,
/// use a cached `DateFormatter` under a lock.
final class DateFormatterCache: @unchecked Sendable {
    static let shared = DateFormatterCache()

    private let lock = Lock()
    private var compiled: [String: [FastDateFormat.Token]?] = [:]
    private var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        shared.string(from: date, format: format, timeZone: timeZone)
    }

    private func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        let tokens = lock.withLock { () -> [FastDateFormat.Token]? in
            if let cached = compiled[format] { return cached }
            let tokens = FastDateFormat.compile(format)
            compiled[format] = .some(tokens)
            return tokens
        }
        if let tokens, let fast = FastDateFormat.string(from: date, tokens: tokens, timeZone: timeZone) {
            return fast
        }
        return formatterString(from: date, format: format, timeZone: timeZone)
    }

    private func formatterString(from date: Date, format: String, timeZone: TimeZone) -> String {
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
