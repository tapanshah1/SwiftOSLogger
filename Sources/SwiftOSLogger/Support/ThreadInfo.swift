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
        let pthreadName = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer -> String? in
            guard let base = buffer.baseAddress,
                  pthread_getname_np(pthread_self(), base, buffer.count) == 0, base.pointee != 0
            else { return nil }
            return String(cString: base)
        }
        return pthreadName ?? String(cString: __dispatch_queue_get_label(nil))
    }
}
