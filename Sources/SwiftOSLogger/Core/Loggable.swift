/// Adopt to get a `log` property whose entries carry the adopting type's name
/// as class name and category.
///
/// ```swift
/// final class NetworkManager: Loggable {
///     func fetch() { log.debug("go") }   // class "NetworkManager", category "NetworkManager"
/// }
/// ```
public protocol Loggable {
    /// Category for this type's entries. Defaults to the type name.
    static var logCategory: String { get }
    /// Logger the type's `log` is derived from. Defaults to `OSLogger.shared`.
    static var baseLogger: OSLogger { get }
}

public extension Loggable {
    static var logCategory: String { String(describing: Self.self) }
    static var baseLogger: OSLogger { .shared }

    static var log: OSLogger { baseLogger.withCategory(logCategory).bound(to: Self.self) }
    var log: OSLogger { Self.log }
}
