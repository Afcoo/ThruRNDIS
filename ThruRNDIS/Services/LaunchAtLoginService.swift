/*
Copyright (C) 2026 Afcoo.
*/

import ServiceManagement

struct LaunchAtLoginSnapshot: Equatable {
    let isEnabled: Bool
    let requiresApproval: Bool
    let statusText: String
}

@MainActor
protocol LaunchAtLoginManaging {
    func snapshot() -> LaunchAtLoginSnapshot
    func setEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginSnapshot
}

struct LaunchAtLoginService: LaunchAtLoginManaging {
    func snapshot() -> LaunchAtLoginSnapshot {
        switch SMAppService.mainApp.status {
        case .enabled:
            return LaunchAtLoginSnapshot(
                isEnabled: true,
                requiresApproval: false,
                statusText: String(localized: "ThruRNDIS will open automatically when you log in.")
            )
        case .requiresApproval:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: true,
                statusText: String(localized: "Allow ThruRNDIS in System Settings > General > Login Items.")
            )
        case .notFound:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: false,
                statusText: String(localized: "The login item could not be found. Run ThruRNDIS from its app bundle.")
            )
        case .notRegistered:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: false,
                statusText: String(localized: "ThruRNDIS will not open automatically at login.")
            )
        @unknown default:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: false,
                statusText: String(localized: "Login item status is unavailable.")
            )
        }
    }

    func setEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginSnapshot {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        }

        return snapshot()
    }
}
