/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum VMRuntimeState: String {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed
}

enum VMDisplayState: String {
    case stopped = "Stopped"
    case running = "Running"
    case restarting = "Restarting"

    var localizedName: String {
        switch self {
        case .stopped:
            return String(localized: "Stopped")
        case .running:
            return String(localized: "Running")
        case .restarting:
            return String(localized: "Restarting")
        }
    }
}
