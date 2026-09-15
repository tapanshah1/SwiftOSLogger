import Foundation

/// Human-readable single-line formatter.
///
/// Default output:
/// ```
/// 2026-09-15 13:45:12.347 +0530 [INFO] [main:0x1a2b] [Network] NetworkManager.swift:42 NetworkManager.fetch(_:) - Request started
/// ```
public struct TextLogFormatter: LogFormatter {
    public var dateFormat: String
    public var timeZone: TimeZone
    public var includeDate: Bool
    public var includeEmoji: Bool
    public var includeLevel: Bool
    public var includeThread: Bool
    public var includeSubsystem: Bool
    public var includeCategory: Bool
    public var includeFileAndLine: Bool
    public var includeClassName: Bool
    public var includeFunction: Bool

    public init(
        dateFormat: String = "yyyy-MM-dd HH:mm:ss.SSS Z",
        timeZone: TimeZone = .current,
        includeDate: Bool = true,
        includeEmoji: Bool = false,
        includeLevel: Bool = true,
        includeThread: Bool = true,
        includeSubsystem: Bool = false,
        includeCategory: Bool = true,
        includeFileAndLine: Bool = true,
        includeClassName: Bool = true,
        includeFunction: Bool = true
    ) {
        self.dateFormat = dateFormat
        self.timeZone = timeZone
        self.includeDate = includeDate
        self.includeEmoji = includeEmoji
        self.includeLevel = includeLevel
        self.includeThread = includeThread
        self.includeSubsystem = includeSubsystem
        self.includeCategory = includeCategory
        self.includeFileAndLine = includeFileAndLine
        self.includeClassName = includeClassName
        self.includeFunction = includeFunction
    }

    /// Used by `OSLogDestination`: unified logging already records date, level,
    /// subsystem and category, so those are omitted.
    public static let osLogDefault = TextLogFormatter(includeDate: false, includeLevel: false, includeCategory: false)

    public func format(_ entry: LogEntry) -> String {
        var segments: [String] = []
        if includeDate {
            segments.append(DateFormatterCache.string(from: entry.date, format: dateFormat, timeZone: timeZone))
        }
        if includeEmoji, !entry.level.emoji.isEmpty {
            segments.append(entry.level.emoji)
        }
        if includeLevel {
            segments.append("[\(entry.level.name)]")
        }
        if includeThread {
            let id = "0x" + String(entry.threadID, radix: 16)
            segments.append(entry.threadName.isEmpty ? "[\(id)]" : "[\(entry.threadName):\(id)]")
        }
        if includeSubsystem {
            segments.append("[\(entry.subsystem)]")
        }
        if includeCategory {
            segments.append("[\(entry.category)]")
        }
        if includeFileAndLine {
            segments.append("\(entry.fileName):\(entry.line)")
        }
        switch (includeClassName, includeFunction) {
        case (true, true): segments.append("\(entry.className).\(entry.function)")
        case (true, false): segments.append(entry.className)
        case (false, true): segments.append(entry.function)
        case (false, false): break
        }
        guard !segments.isEmpty else { return entry.message }
        return segments.joined(separator: " ") + " - " + entry.message
    }
}
