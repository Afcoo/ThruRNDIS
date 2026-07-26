/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum EventLogLevel: Int, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    static func < (lhs: EventLogLevel, rhs: EventLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var logLabel: String {
        switch self {
        case .debug:
            "DEBUG"
        case .info:
            "INFO"
        case .warning:
            "WARNING"
        case .error:
            "ERROR"
        }
    }
}

enum EventLogCategory: String, CaseIterable, Identifiable {
    case usb = "USB"
    case vm = "VM"
    case vmAsset = "VM Assets"
    case wireGuard = "WireGuard"
    case application = "Application"

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .vm:
            String(localized: "VM")
        case .usb:
            String(localized: "USB")
        case .wireGuard:
            String(localized: "WireGuard")
        case .vmAsset:
            String(localized: "VM Assets")
        case .application:
            String(localized: "Application")
        }
    }
}

struct EventLogRecord: Equatable {
    let date: Date
    let level: EventLogLevel
    let category: EventLogCategory
    let message: String
}

typealias EventLogHandler = (_ message: String, _ level: EventLogLevel) -> Void
