import XCTest
@testable import SwiftOSLogger

final class LogFileHeaderTests: XCTestCase {
    private func makeAppInfo() -> AppInfo {
        var info = AppInfo(bundle: .main, processInfo: .processInfo)
        info.appName = "MyApp"
        info.bundleID = "com.acme.myapp"
        info.appVersion = "2.3.1"
        info.buildNumber = "145"
        info.processName = "MyApp"
        info.processID = 4821
        info.osName = "iOS"
        info.osVersion = "18.2"
        info.deviceModel = "iPhone16,2"
        return info
    }

    func testHeaderContainsLoggerAppAndProcessInfo() {
        let configuration = FileDestinationConfiguration(
            directory: URL(fileURLWithPath: "/tmp"),
            maxFileSize: 5_242_880, maxLinesPerFile: nil, maxFileCount: 10,
            customHeaderFields: ["User": "42", "Environment": "staging"]
        )
        let header = LogFileHeader.make(
            appInfo: makeAppInfo(),
            creationDate: makeEntry().date,
            fileIndex: 3,
            configuration: configuration,
            timeZone: TimeZone(secondsFromGMT: 19_800)!
        )

        XCTAssertEqual(header, """
        # ==================== SwiftOSLogger Log File ====================
        # Logger:          SwiftOSLogger \(SwiftOSLoggerVersion.current)
        # Application:     MyApp
        # Bundle ID:       com.acme.myapp
        # App Version:     2.3.1 (145)
        # Process:         MyApp
        # PID:             4821
        # OS:              iOS 18.2
        # Device Model:    iPhone16,2
        # File Created:    2026-09-15 13:45:12.347 +0530
        # File Index:      3
        # Rotation:        maxFileSize=5242880 bytes, maxLinesPerFile=unlimited, maxFileCount=10
        # Environment:     staging
        # User:            42
        # ================================================================

        """)
    }

    func testEveryHeaderLineStartsWithHash() {
        let header = LogFileHeader.make(appInfo: makeAppInfo(), creationDate: Date(), fileIndex: 1,
                                        configuration: FileDestinationConfiguration(customHeaderFields: ["A very long custom key": "v"]))
        let lines = header.split(separator: "\n")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("# ") })
        XCTAssertTrue(header.contains("# A very long custom key: v"))
    }

    func testAppInfoReadsBundleAndProcess() throws {
        let bundleURL = try makeTemporaryDirectory(self).appendingPathComponent("Fake.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.acme.fake",
            "CFBundleName": "FakeName",
            "CFBundleDisplayName": "Fake Display",
            "CFBundleShortVersionString": "9.8",
            "CFBundleVersion": "765",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        let info = AppInfo(bundle: bundle, processInfo: .processInfo)
        XCTAssertEqual(info.appName, "Fake Display")
        XCTAssertEqual(info.bundleID, "com.acme.fake")
        XCTAssertEqual(info.appVersion, "9.8")
        XCTAssertEqual(info.buildNumber, "765")
        XCTAssertEqual(info.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(info.processName, ProcessInfo.processInfo.processName)
        XCTAssertEqual(info.osName, "macOS")
        XCTAssertFalse(info.osVersion.isEmpty)
        XCTAssertNotEqual(info.deviceModel, "unknown")
    }
}
