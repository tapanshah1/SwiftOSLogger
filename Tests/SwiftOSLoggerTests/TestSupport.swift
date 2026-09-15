import Foundation
@testable import SwiftOSLogger

/// A fixed entry: 2026-09-15 08:15:12.347 UTC (13:45:12.347 +0530).
func makeEntry(
    level: LogLevel = .info,
    message: String = "Request started",
    date: Date = Date(timeIntervalSince1970: 1_789_460_112.347),
    threadID: UInt64 = 0x1a2b,
    threadName: String = "main"
) -> LogEntry {
    LogEntry(
        level: level,
        message: message,
        date: date,
        subsystem: "com.acme.app",
        category: "Network",
        fileID: "MyApp/NetworkManager.swift",
        fileName: "NetworkManager.swift",
        filePath: "/src/MyApp/NetworkManager.swift",
        className: "NetworkManager",
        function: "fetch(_:)",
        line: 42,
        threadID: threadID,
        threadName: threadName,
        isMainThread: threadName == "main",
        processID: 4821
    )
}
