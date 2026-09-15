import Foundation

/// Formats each entry as one compact JSON object (JSON Lines), with sorted keys.
public struct JSONLogFormatter: LogFormatter {
    public init() {}

    public func format(_ entry: LogEntry) -> String {
        let object: [String: Any] = [
            "timestamp": DateFormatterCache.string(
                from: entry.date,
                format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                timeZone: TimeZone(identifier: "UTC")!
            ),
            "level": entry.level.name,
            "levelValue": entry.level.rawValue,
            "message": entry.message,
            "subsystem": entry.subsystem,
            "category": entry.category,
            "file": entry.fileName,
            "line": entry.line,
            "class": entry.className,
            "function": entry.function,
            "threadID": entry.threadID,
            "threadName": entry.threadName,
            "isMainThread": entry.isMainThread,
            "pid": entry.processID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8)
        else {
            // Unreachable with the current String/Int/Bool values; kept so `format` never fails.
            let level = entry.level.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"level\":\"\(level)\",\"message\":\"<unencodable>\"}"
        }
        return string
    }
}
