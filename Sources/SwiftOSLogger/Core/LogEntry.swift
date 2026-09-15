import Foundation

/// A single log event with all metadata captured at the call site.
public struct LogEntry: Sendable {
    public let level: LogLevel
    public let message: String
    public let date: Date
    public let subsystem: String
    public let category: String
    /// `#fileID`, e.g. `"MyApp/NetworkManager.swift"`.
    public let fileID: String
    /// Last path component of `fileID`, e.g. `"NetworkManager.swift"`.
    public let fileName: String
    /// `#filePath`.
    public let filePath: String
    public let className: String
    public let function: String
    public let line: Int
    /// Value from `pthread_threadid_np`.
    public let threadID: UInt64
    /// `"main"`, the thread name, the dispatch queue label, or `""`.
    public let threadName: String
    public let isMainThread: Bool
    public let processID: Int32

    public init(
        level: LogLevel,
        message: String,
        date: Date,
        subsystem: String,
        category: String,
        fileID: String,
        fileName: String,
        filePath: String,
        className: String,
        function: String,
        line: Int,
        threadID: UInt64,
        threadName: String,
        isMainThread: Bool,
        processID: Int32
    ) {
        self.level = level
        self.message = message
        self.date = date
        self.subsystem = subsystem
        self.category = category
        self.fileID = fileID
        self.fileName = fileName
        self.filePath = filePath
        self.className = className
        self.function = function
        self.line = line
        self.threadID = threadID
        self.threadName = threadName
        self.isMainThread = isMainThread
        self.processID = processID
    }
}
