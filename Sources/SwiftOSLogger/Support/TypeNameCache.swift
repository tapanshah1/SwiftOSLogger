/// Caches `String(describing:)` for metatypes, which is slow (it demangles) and is needed on
/// every `Loggable` log call. Metatypes are never deallocated, so the cache is bounded by the
/// number of distinct types that log.
enum TypeNameCache {
    private final class Storage: @unchecked Sendable {
        let lock = Lock()
        var names: [ObjectIdentifier: String] = [:]
    }

    private static let storage = Storage()

    static func name(of type: Any.Type) -> String {
        let id = ObjectIdentifier(type)
        if let cached = storage.lock.withLock({ storage.names[id] }) { return cached }
        let name = String(describing: type)
        storage.lock.withLock { storage.names[id] = name }
        return name
    }
}
