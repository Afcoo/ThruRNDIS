/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct MenuBarCombinedStatus: Equatable {
    enum Activity: Equatable {
        case inactive
        case partiallyActive
        case active
    }

    enum Stage: Equatable {
        case inactive
        case usbNotAttached
        case wireGuardDisconnected
        case active
    }

    let activity: Activity
    let stage: Stage

    init(
        vmRuntimeState: VMRuntimeState,
        isUSBAttached: Bool,
        wireGuardTunnelStatus: HostWireGuardTunnelStatus
    ) {
        let isVMRunning = vmRuntimeState == .running
        let isWireGuardConnected = wireGuardTunnelStatus == .connected
        let activeComponentCount = [
            isVMRunning,
            isUSBAttached,
            isWireGuardConnected,
        ].filter { $0 }.count

        switch activeComponentCount {
        case 0:
            activity = .inactive
        case 3:
            activity = .active
        default:
            activity = .partiallyActive
        }

        if !isVMRunning {
            stage = .inactive
        } else if !isUSBAttached {
            stage = .usbNotAttached
        } else if !isWireGuardConnected {
            stage = .wireGuardDisconnected
        } else {
            stage = .active
        }
    }

    var title: String {
        switch stage {
        case .inactive:
            return String(
                localized: "menuBar.combinedStatus.notRunning",
                defaultValue: "Not Running"
            )
        case .usbNotAttached:
            return String(localized: "USB Not Attached")
        case .wireGuardDisconnected:
            return String(localized: "WireGuard Disconnected")
        case .active:
            return String(
                localized: "menuBar.combinedStatus.running",
                defaultValue: "Running"
            )
        }
    }
}
