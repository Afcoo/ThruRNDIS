/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum EventLogLevel: Int, CaseIterable, Comparable, Sendable {
    /// Internal decisions, identifiers, parameters, and routine transitions.
    case debug
    /// A completed user-visible action or meaningful runtime state change.
    case info
    /// A degraded or blocked operation that may need user attention.
    case warning
    /// An operation failed and did not reach its intended outcome.
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

enum EventLogCategory: String, CaseIterable, Identifiable, Sendable {
    case usb = "USB"
    case vm = "VM"
    case vmAsset = "VM Assets"
    case wireGuard = "WireGuard"
    case dummyEthernet = "Dummy Ethernet"
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
        case .dummyEthernet:
            String(localized: "Dummy Ethernet")
        case .vmAsset:
            String(localized: "VM Assets")
        case .application:
            String(localized: "Application")
        }
    }
}

struct EventLogRecord: Equatable, Sendable {
    let date: Date
    let level: EventLogLevel
    let category: EventLogCategory
    let message: String
}

typealias EventLogHandler = (_ message: String, _ level: EventLogLevel) -> Void
