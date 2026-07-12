/*
Copyright (C) 2026 Afcoo.
*/

import ServiceManagement

struct LaunchAtLoginSnapshot: Equatable {
    let isEnabled: Bool
    let requiresApproval: Bool
    let statusText: String
}

enum LaunchAtLoginService {
    static func snapshot() -> LaunchAtLoginSnapshot {
        switch SMAppService.mainApp.status {
        case .enabled:
            return LaunchAtLoginSnapshot(
                isEnabled: true,
                requiresApproval: false,
                statusText: "RTPVM will open automatically when you log in."
            )
        case .requiresApproval:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: true,
                statusText: "Allow RTPVM in System Settings > General > Login Items."
            )
        case .notFound:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: false,
                statusText: "The login item could not be found. Run RTPVM from its app bundle."
            )
        case .notRegistered:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: false,
                statusText: "RTPVM will not open automatically at login."
            )
        @unknown default:
            return LaunchAtLoginSnapshot(
                isEnabled: false,
                requiresApproval: false,
                statusText: "Login item status is unavailable."
            )
        }
    }

    static func setEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginSnapshot {
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

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
