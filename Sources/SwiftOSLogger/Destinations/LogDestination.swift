/// A place log entries are sent to. Conform to build your own destination
/// (for example, a remote upload or an in-app log viewer).
public protocol LogDestination: Sendable {
    /// Entries below this level are not sent to this destination.
    var minLevel: LogLevel { get }
    /// Formats entries before `write(_:formatted:)` is called.
    var formatter: any LogFormatter { get }
    /// Receives an entry and its formatted text. Called on the logging thread;
    /// must be fast and thread-safe.
    func write(_ entry: LogEntry, formatted: String)
    /// Writes any buffered output. Default implementation does nothing.
    func flush()
}

public extension LogDestination {
    func flush() {}
}
