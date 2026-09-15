import Foundation

/// File naming, rotation and buffering options for `FileDestination`.
public struct FileDestinationConfiguration: Sendable {
    /// Folder the log files are written to. Created if missing.
    /// Default: `<Caches>/Logs`. Note that the system may purge Caches when storage is low;
    /// use Application Support if logs must survive that.
    public var directory: URL
    /// File names are `<prefix>_yyyy-MM-dd_HH-mm-ss-SSS.<extension>`.
    public var fileNamePrefix: String
    public var fileExtension: String
    /// Rotate before a file would exceed this many bytes. `nil` = unlimited.
    public var maxFileSize: Int?
    /// Rotate after this many log entries (header lines excluded). `nil` = unlimited.
    public var maxLinesPerFile: Int?
    /// Keep at most this many files; the oldest are deleted. `nil` = unlimited.
    public var maxFileCount: Int?
    /// When `false`, a launch appends to the newest existing file if it is under the limits.
    public var newFilePerLaunch: Bool
    /// Write the logger/app/process header at the top of every new file.
    public var includeHeader: Bool
    /// Extra `key: value` lines appended to the header, sorted by key.
    public var customHeaderFields: [String: String]
    /// Bytes buffered in memory before they are written to disk.
    public var bufferSize: Int
    /// Entries at or above this level are written to disk immediately.
    public var flushLevel: LogLevel
    /// Flush when the app moves to the background or terminates.
    public var flushOnAppLifecycle: Bool

    public init(
        directory: URL = FileDestinationConfiguration.defaultDirectory,
        fileNamePrefix: String = "log",
        fileExtension: String = "log",
        maxFileSize: Int? = 5 * 1024 * 1024,
        maxLinesPerFile: Int? = nil,
        maxFileCount: Int? = 10,
        newFilePerLaunch: Bool = false,
        includeHeader: Bool = true,
        customHeaderFields: [String: String] = [:],
        bufferSize: Int = 32 * 1024,
        flushLevel: LogLevel = .error,
        flushOnAppLifecycle: Bool = true
    ) {
        self.directory = directory
        self.fileNamePrefix = fileNamePrefix
        self.fileExtension = fileExtension
        self.maxFileSize = maxFileSize
        self.maxLinesPerFile = maxLinesPerFile
        self.maxFileCount = maxFileCount
        self.newFilePerLaunch = newFilePerLaunch
        self.includeHeader = includeHeader
        self.customHeaderFields = customHeaderFields
        self.bufferSize = bufferSize
        self.flushLevel = flushLevel
        self.flushOnAppLifecycle = flushOnAppLifecycle
    }

    /// `<Caches>/Logs`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }
}
