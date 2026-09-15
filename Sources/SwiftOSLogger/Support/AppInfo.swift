import Foundation

/// Application, process and device details written into log file headers.
struct AppInfo: Sendable, Equatable {
    var appName: String
    var bundleID: String
    var appVersion: String
    var buildNumber: String
    var processName: String
    var processID: Int32
    var osName: String
    var osVersion: String
    var deviceModel: String

    static let current = AppInfo(bundle: .main, processInfo: .processInfo)

    init(bundle: Bundle, processInfo: ProcessInfo) {
        let info = bundle.infoDictionary ?? [:]
        processName = processInfo.processName
        appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? processInfo.processName
        bundleID = bundle.bundleIdentifier ?? "unknown"
        appVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
        buildNumber = info["CFBundleVersion"] as? String ?? "unknown"
        processID = processInfo.processIdentifier
        osName = AppInfo.platformName

        let version = processInfo.operatingSystemVersion
        osVersion = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        if let simulatorModel = processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            deviceModel = simulatorModel + " (Simulator)"
        } else {
            deviceModel = AppInfo.sysctlString(AppInfo.modelSysctlName) ?? "unknown"
        }
    }

    private static var platformName: String {
        #if targetEnvironment(macCatalyst)
        return "Mac Catalyst"
        #elseif os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }

    private static var modelSysctlName: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return "hw.model"      // e.g. "MacBookPro18,1"
        #else
        return "hw.machine"    // e.g. "iPhone16,2"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
