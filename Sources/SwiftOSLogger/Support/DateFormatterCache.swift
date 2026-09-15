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
