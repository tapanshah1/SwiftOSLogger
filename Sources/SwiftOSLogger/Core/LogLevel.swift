import os

/// The severity of a log entry.
///
/// Levels are ordered by `rawValue`. Use the presets, or define your own:
///
/// ```swift
/// extension LogLevel {
///     static let audit = LogLevel(rawValue: 450, name: "AUDIT", emoji: "🧾", osLogType: .default)
/// }
/// ```
public struct LogLevel: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Ordering value. Higher is more severe.
    public let rawValue: Int
    /// Label written into formatted output, e.g. `"INFO"`.
    public let name: String
    /// Optional emoji used by formatters when `includeEmoji` is on.
    public let emoji: String
    private let osLogTypeRawValue: UInt8

    /// The unified logging type used by `OSLogDestination`.
    public var osLogType: OSLogType { OSLogType(rawValue: osLogTypeRawValue) }

    public init(rawValue: Int, name: String, emoji: String = "", osLogType: OSLogType) {
        self.rawValue = rawValue
        self.name = name
        self.emoji = emoji
        self.osLogTypeRawValue = osLogType.rawValue
    }

    public var description: String { name }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func == (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    public static let trace = LogLevel(rawValue: 100, name: "TRACE", emoji: "🔬", osLogType: .debug)
    public static let debug = LogLevel(rawValue: 200, name: "DEBUG", emoji: "🐞", osLogType: .debug)
    public static let info = LogLevel(rawValue: 300, name: "INFO", emoji: "ℹ️", osLogType: .info)
    public static let notice = LogLevel(rawValue: 400, name: "NOTICE", emoji: "📘", osLogType: .default)
    public static let warning = LogLevel(rawValue: 500, name: "WARNING", emoji: "⚠️", osLogType: .default)
    public static let error = LogLevel(rawValue: 600, name: "ERROR", emoji: "❌", osLogType: .error)
    public static let critical = LogLevel(rawValue: 700, name: "CRITICAL", emoji: "🔥", osLogType: .fault)
    /// Use as a minimum level to disable output. Never log at this level.
    public static let off = LogLevel(rawValue: Int.max, name: "OFF", osLogType: .default)
}
