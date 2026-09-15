import Foundation

/// Formats each entry as one compact JSON object (JSON Lines), with sorted keys.
///
/// The JSON is written directly, byte for byte identical to `JSONSerialization` with
/// `.sortedKeys` and `.withoutEscapingSlashes`, without its dictionary and bridging overhead.
public struct JSONLogFormatter: LogFormatter {
    private static let utc = TimeZone(identifier: "UTC")!

    public init() {}

    public func format(_ entry: LogEntry) -> String {
        let timestamp = DateFormatterCache.string(from: entry.date, format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                                                  timeZone: Self.utc)
        var json = JSONWriter(capacity: 192 + entry.message.utf8.count)
        // Keys in sorted order.
        json.field("category", string: entry.category, first: true)
        json.field("class", string: entry.className)
        json.field("file", string: entry.fileName)
        json.field("function", string: entry.function)
        json.field("isMainThread", raw: entry.isMainThread ? "true" : "false")
        json.field("level", string: entry.level.name)
        json.field("levelValue", raw: String(entry.level.rawValue))
        json.field("line", raw: String(entry.line))
        json.field("message", string: entry.message)
        json.field("pid", raw: String(entry.processID))
        json.field("subsystem", string: entry.subsystem)
        json.field("threadID", raw: String(entry.threadID))
        json.field("threadName", string: entry.threadName)
        json.field("timestamp", string: timestamp)
        return json.finish()
    }
}

/// Appends JSON object syntax to a UTF-8 buffer.
private struct JSONWriter {
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
    private var bytes: [UInt8]

    init(capacity: Int) {
        bytes = [UInt8(ascii: "{")]
        bytes.reserveCapacity(capacity)
    }

    mutating func field(_ key: StaticString, string value: String, first: Bool = false) {
        appendKey(key, first: first)
        quoted(value)
    }

    mutating func field(_ key: StaticString, raw value: String) {
        appendKey(key, first: false)
        bytes.append(contentsOf: value.utf8)
    }

    mutating func finish() -> String {
        bytes.append(UInt8(ascii: "}"))
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func appendKey(_ key: StaticString, first: Bool) {
        if !first { bytes.append(UInt8(ascii: ",")) }
        bytes.append(UInt8(ascii: "\""))
        key.withUTF8Buffer { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: [UInt8(ascii: "\""), UInt8(ascii: ":")])
    }

    private mutating func quoted(_ value: String) {
        bytes.append(UInt8(ascii: "\""))
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "\""): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x08: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
            case 0x0C: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
            case 0x0A: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0D: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x09: bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0x00..<0x20:
                bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"),
                                          Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 0x0F)]])
            default: bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }
}
