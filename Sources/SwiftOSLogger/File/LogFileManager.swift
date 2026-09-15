import Foundation

/// Errors thrown or reported by `FileDestination`.
public enum FileDestinationError: Error {
    case cannotCreateDirectory(URL, underlying: Error)
    case cannotCreateFile(URL)
}

/// Owns the log files of one `FileDestination`: naming, header, buffering, rotation
/// and cleanup. Not thread-safe; `FileDestination` confines it to a serial queue.
final class LogFileManager {
    let configuration: FileDestinationConfiguration
    private let appInfo: AppInfo
    private let fileManager = FileManager.default

    private(set) var currentFileURL: URL?
    private var handle: FileHandle?
    private var buffer = Data()
    /// Bytes in the current file, including bytes still in `buffer`.
    private var currentSize = 0
    /// Log entries in the current file (header lines excluded), including buffered ones.
    private var currentBodyLines = 0
    private var filesCreated = 0
    private var hasOpenedFile = false

    /// Writes buffered bytes to the current file. Test seam for injecting write failures.
    var writeData: (FileHandle, Data) throws -> Void = { handle, data in
        try handle.write(contentsOf: data)
    }

    init(configuration: FileDestinationConfiguration, appInfo: AppInfo = .current) throws {
        self.configuration = configuration
        self.appInfo = appInfo
        do {
            try fileManager.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        } catch {
            throw FileDestinationError.cannotCreateDirectory(configuration.directory, underlying: error)
        }
    }

    deinit {
        _ = try? close()
    }

    // MARK: Writing

    /// Buffers one log line, rotating first if it would exceed a limit.
    /// - Returns: `true` if buffered bytes were written to disk (by a rotation or a buffer flush),
    ///   `false` if the line was only buffered. Writing a new file's header does not count.
    @discardableResult
    func append(_ line: String, flushImmediately: Bool) throws -> Bool {
        let data = Data((line + "\n").utf8)
        var wroteToDisk = false
        if currentFileURL == nil {
            try openInitialFile()
        } else if shouldRotate(adding: data.count) {
            wroteToDisk = try createNewFile()
        }
        buffer.append(data)
        currentSize += data.count
        currentBodyLines += 1
        if flushImmediately || buffer.count >= configuration.bufferSize {
            wroteToDisk = try flush() || wroteToDisk
        }
        return wroteToDisk
    }

    /// - Returns: `true` if a non-empty buffer was written to disk.
    @discardableResult
    func flush() throws -> Bool {
        guard !buffer.isEmpty, let handle else { return false }
        defer { buffer.removeAll(keepingCapacity: true) }
        try writeData(handle, buffer)
        return true
    }

    /// - Returns: `true` if a non-empty buffer was written to disk before closing.
    @discardableResult
    func close() throws -> Bool {
        let closingHandle = handle
        defer {
            handle = nil
            buffer.removeAll()
            try? closingHandle?.close()
        }
        return try flush()
    }

    /// Forgets the current file without flushing, so the next append creates a new file.
    /// Used after an I/O error.
    func discardCurrentFile() {
        try? handle?.close()
        handle = nil
        buffer.removeAll()
        currentFileURL = nil
        currentSize = 0
        currentBodyLines = 0
    }

    // MARK: Files

    func logFileURLs() -> [URL] {
        LogFileManager.logFileURLs(in: configuration.directory,
                                   prefix: configuration.fileNamePrefix,
                                   fileExtension: configuration.fileExtension)
    }

    func deleteAllLogFiles() {
        discardCurrentFile()
        for url in logFileURLs() {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Log files for `prefix`/`fileExtension` in `directory`, oldest first.
    static func logFileURLs(in directory: URL, prefix: String, fileExtension: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .compactMap { url -> (url: URL, stamp: String, sequence: Int)? in
                guard url.pathExtension == fileExtension else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                guard name.hasPrefix(prefix + "_") else { return nil }
                // "<date>_<time>" or "<date>_<time>_<sequence>"
                let parts = name.dropFirst(prefix.count + 1).split(separator: "_")
                guard parts.count == 2 || parts.count == 3,
                      parts[0].count == 10, parts[1].count == 12
                else { return nil }
                let sequence = parts.count == 3 ? Int(parts[2]) : 0
                guard let sequence else { return nil }
                // Rebuild from `directory` so URLs compare equal to `currentFileURL`
                // (directory listings resolve symlinks such as /var -> /private/var).
                return (directory.appendingPathComponent(url.lastPathComponent),
                        String(parts[0]) + "_" + String(parts[1]), sequence)
            }
            .sorted { ($0.stamp, $0.sequence) < ($1.stamp, $1.sequence) }
            .map(\.url)
    }

    // MARK: Private

    private var maxFileSize: Int? { configuration.maxFileSize.map { max(1, $0) } }
    private var maxLinesPerFile: Int? { configuration.maxLinesPerFile.map { max(1, $0) } }
    private var maxFileCount: Int? { configuration.maxFileCount.map { max(1, $0) } }

    private func shouldRotate(adding bytes: Int) -> Bool {
        if let maxLinesPerFile, currentBodyLines >= maxLinesPerFile { return true }
        // A file always accepts its first entry, so an oversized line is never dropped.
        if let maxFileSize, currentBodyLines > 0, currentSize + bytes > maxFileSize { return true }
        return false
    }

    private func openInitialFile() throws {
        defer { hasOpenedFile = true }
        if !hasOpenedFile, !configuration.newFilePerLaunch, let latest = logFileURLs().last,
           let stats = measure(latest), isUnderLimits(size: stats.size, bodyLines: stats.bodyLines),
           let handle = try? FileHandle(forWritingTo: latest) {
            try handle.seekToEnd()
            self.handle = handle
            currentFileURL = latest
            currentSize = stats.size
            currentBodyLines = stats.bodyLines
            return
        }
        try createNewFile()
    }

    private func isUnderLimits(size: Int, bodyLines: Int) -> Bool {
        if let maxFileSize, size >= maxFileSize { return false }
        if let maxLinesPerFile, bodyLines >= maxLinesPerFile { return false }
        return true
    }

    /// - Returns: `true` if closing the previous file wrote buffered bytes to disk.
    @discardableResult
    private func createNewFile() throws -> Bool {
        var wroteToDisk = false
        if handle != nil {
            wroteToDisk = try close()
        }
        // Recreate the directory in case it was deleted while running.
        try? fileManager.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let now = Date()
        let url = uniqueFileURL(for: now)
        filesCreated += 1
        let header = configuration.includeHeader
            ? LogFileHeader.make(appInfo: appInfo, creationDate: now, fileIndex: filesCreated, configuration: configuration)
            : ""
        let headerData = Data(header.utf8)
        guard fileManager.createFile(atPath: url.path, contents: headerData),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            throw FileDestinationError.cannotCreateFile(url)
        }
        try handle.seekToEnd()
        self.handle = handle
        currentFileURL = url
        currentSize = headerData.count
        currentBodyLines = 0
        deleteFilesOverLimit()
        return wroteToDisk
    }

    private func uniqueFileURL(for date: Date) -> URL {
        // UTC so that name order stays chronological across time zone and DST changes.
        let stamp = DateFormatterCache.string(from: date, format: "yyyy-MM-dd_HH-mm-ss-SSS", timeZone: TimeZone(identifier: "UTC")!)
        let base = "\(configuration.fileNamePrefix)_\(stamp)"
        var url = configuration.directory.appendingPathComponent("\(base).\(configuration.fileExtension)")
        var sequence = 1
        while fileManager.fileExists(atPath: url.path) {
            url = configuration.directory.appendingPathComponent("\(base)_\(sequence).\(configuration.fileExtension)")
            sequence += 1
        }
        return url
    }

    private func deleteFilesOverLimit() {
        guard let maxFileCount else { return }
        var files = logFileURLs()
        let currentName = currentFileURL?.lastPathComponent
        while files.count > maxFileCount {
            let oldest = files.removeFirst()
            guard oldest.lastPathComponent != currentName else { continue }
            try? fileManager.removeItem(at: oldest)
        }
    }

    /// Size and number of non-header lines of an existing file.
    private func measure(_ url: URL) -> (size: Int, bodyLines: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let newline = UInt8(ascii: "\n")
        let hash = UInt8(ascii: "#")
        var size = 0
        var bodyLines = 0
        var atLineStart = true
        var inHeader = true
        var currentLineIsHeader = false
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            size += chunk.count
            for byte in chunk {
                if atLineStart {
                    if byte != hash { inHeader = false }
                    currentLineIsHeader = inHeader
                    atLineStart = false
                }
                if byte == newline {
                    if !currentLineIsHeader { bodyLines += 1 }
                    atLineStart = true
                }
            }
        }
        return (size, bodyLines)
    }
}
