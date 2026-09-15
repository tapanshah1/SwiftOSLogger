/// Turns a `LogEntry` into a single string. Must not include a trailing newline.
public protocol LogFormatter: Sendable {
    func format(_ entry: LogEntry) -> String
}
