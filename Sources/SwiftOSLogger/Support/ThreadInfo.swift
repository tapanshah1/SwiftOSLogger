import Foundation

/// Reads thread metadata with pthread/dispatch APIs, which (unlike `Thread.current`)
/// are safe to call from Swift `async` contexts.
enum ThreadInfo {
    static var isMainThread: Bool { pthread_main_np() != 0 }

    static var currentThreadID: UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    /// `"main"` on the main thread, otherwise the pthread name, otherwise the
    /// current dispatch queue label, otherwise `""`.
    static var currentThreadName: String {
        if isMainThread { return "main" }
        var buffer = [CChar](repeating: 0, count: 128)
        if pthread_getname_np(pthread_self(), &buffer, buffer.count) == 0, buffer[0] != 0 {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return String(cString: __dispatch_queue_get_label(nil))
    }
}
