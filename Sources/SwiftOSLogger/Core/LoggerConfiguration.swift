/// Settings shared by an `OSLogger` and every logger derived from it.
public struct LoggerConfiguration: Sendable {
    /// Entries below this level are dropped before any destination sees them.
    public var minLevel: LogLevel
    /// Where entries are sent.
    public var destinations: [any LogDestination]

    public init(minLevel: LogLevel = .debug, destinations: [any LogDestination] = [OSLogDestination()]) {
        self.minLevel = minLevel
        self.destinations = destinations
    }
}
