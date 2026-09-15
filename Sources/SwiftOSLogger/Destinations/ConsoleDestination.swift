import Foundation

/// Prints entries to standard output or standard error.
///
/// Note: `OSLogDestination` output already appears in Xcode's console, so enabling
/// both prints each entry twice there.
public struct ConsoleDestination: LogDestination {
    public enum Output: Sendable {
        case standardOutput
        case standardError
    }

    private static let writeLock = Lock()

    public let minLevel: LogLevel
    public let formatter: any LogFormatter
    public let output: Output
    private let writer: @Sendable (Data) -> Void

    public init(
        minLevel: LogLevel = .trace,
        formatter: any LogFormatter = TextLogFormatter(includeEmoji: true),
        output: Output = .standardOutput
    ) {
        let writer: @Sendable (Data) -> Void
        switch output {
        // The throwing `write(contentsOf:)`: `write(_:)` raises an Objective-C exception,
        // which crashes the process, when the stream is closed.
        case .standardOutput: writer = { try? FileHandle.standardOutput.write(contentsOf: $0) }
        case .standardError: writer = { try? FileHandle.standardError.write(contentsOf: $0) }
        }
        self.init(minLevel: minLevel, formatter: formatter, output: output, writer: writer)
    }

    /// Test seam: capture output instead of writing to a file handle.
    init(minLevel: LogLevel, formatter: any LogFormatter, output: Output, writer: @escaping @Sendable (Data) -> Void) {
        self.minLevel = minLevel
        self.formatter = formatter
        self.output = output
        self.writer = writer
    }

    public func write(_ entry: LogEntry, formatted: String) {
        let data = Data((formatted + "\n").utf8)
        Self.writeLock.withLock { writer(data) }
    }
}
