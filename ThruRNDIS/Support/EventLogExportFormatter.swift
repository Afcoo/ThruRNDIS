/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct EventLogExportMetadata: Equatable {
    let appVersion: String
    let appBuild: String
    let operatingSystemVersion: String

    static var current: EventLogExportMetadata {
        EventLogExportMetadata(
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

enum EventLogExportFormatter {
    static func defaultFileName(
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "thrurndis-\(formatter.string(from: date)).log"
    }

    static func content(
        logText: String,
        metadata: EventLogExportMetadata = .current
    ) -> String {
        "ThruRNDIS Version: \(metadata.appVersion) (\(metadata.appBuild))\n" +
            "macOS: \(metadata.operatingSystemVersion)\n\n" +
            logText
    }
}
