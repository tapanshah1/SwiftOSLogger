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
        // Built in one pre-sized string; segments are separated by " ", then " - " and the message.
        var line = ""
        line.reserveCapacity(160 + entry.message.utf8.count)
        var hasSegment = false

        if includeDate {
            Self.beginSegment(&line, &hasSegment)
            line.append(DateFormatterCache.string(from: entry.date, format: dateFormat, timeZone: timeZone))
        }
        if includeEmoji, !entry.level.emoji.isEmpty {
            Self.beginSegment(&line, &hasSegment)
            line.append(entry.level.emoji)
        }
        if includeLevel {
            Self.beginSegment(&line, &hasSegment)
            line.append("[")
            line.append(entry.level.name)
            line.append("]")
        }
        if includeThread {
            Self.beginSegment(&line, &hasSegment)
            line.append("[")
            if !entry.threadName.isEmpty {
                line.append(entry.threadName)
                line.append(":")
            }
            line.append("0x")
            line.append(String(entry.threadID, radix: 16))
            line.append("]")
        }
        if includeSubsystem {
            Self.beginSegment(&line, &hasSegment)
            line.append("[")
            line.append(entry.subsystem)
            line.append("]")
        }
        if includeCategory {
            Self.beginSegment(&line, &hasSegment)
            line.append("[")
            line.append(entry.category)
            line.append("]")
        }
        if includeFileAndLine {
            Self.beginSegment(&line, &hasSegment)
            line.append(entry.fileName)
            line.append(":")
            line.append(String(entry.line))
        }
        if includeClassName || includeFunction {
            Self.beginSegment(&line, &hasSegment)
            if includeClassName { line.append(entry.className) }
            if includeClassName && includeFunction { line.append(".") }
            if includeFunction { line.append(entry.function) }
        }
        guard hasSegment else { return entry.message }
        line.append(" - ")
        line.append(entry.message)
        return line
    }

    @inline(__always)
    private static func beginSegment(_ line: inout String, _ hasSegment: inout Bool) {
        if hasSegment { line.append(" ") }
        hasSegment = true
    }
}
