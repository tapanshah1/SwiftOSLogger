import Foundation

/// Builds the `# `-prefixed header written at the top of every new log file.
enum LogFileHeader {
    static func make(
        appInfo: AppInfo,
        creationDate: Date,
        fileIndex: Int,
        configuration: FileDestinationConfiguration,
        timeZone: TimeZone = .current
    ) -> String {
        func limit(_ value: Int?, unit: String = "") -> String {
            value.map { "\($0)\(unit)" } ?? "unlimited"
        }

        var fields: [(String, String)] = [
            ("Logger", "SwiftOSLogger \(SwiftOSLoggerVersion.current)"),
            ("Application", appInfo.appName),
            ("Bundle ID", appInfo.bundleID),
            ("App Version", "\(appInfo.appVersion) (\(appInfo.buildNumber))"),
            ("Process", appInfo.processName),
            ("PID", "\(appInfo.processID)"),
            ("OS", "\(appInfo.osName) \(appInfo.osVersion)"),
            ("Device Model", appInfo.deviceModel),
            ("File Created", DateFormatterCache.string(from: creationDate, format: "yyyy-MM-dd HH:mm:ss.SSS Z", timeZone: timeZone)),
            ("File Index", "\(fileIndex)"),
            ("Rotation", "maxFileSize=\(limit(configuration.maxFileSize, unit: " bytes")), "
                + "maxLinesPerFile=\(limit(configuration.maxLinesPerFile)), "
                + "maxFileCount=\(limit(configuration.maxFileCount))"),
        ]
        fields += configuration.customHeaderFields.sorted { $0.key < $1.key }

        let width = max(16, fields.map { $0.0.count + 1 }.max() ?? 0)
        var lines = ["# ==================== SwiftOSLogger Log File ===================="]
        for (key, value) in fields {
            let label = (key + ":").padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("# \(label) \(value)")
        }
        lines.append("# " + String(repeating: "=", count: 64))
        return lines.joined(separator: "\n") + "\n"
    }
}
