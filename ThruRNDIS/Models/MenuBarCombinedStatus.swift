/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct MenuBarCombinedStatus: Equatable {
    enum DummyEthernetState: Equatable {
        case helperProblem
        case notChecked
        case stopped
        case active
        case needsAttention
    }

    enum Activity: Equatable {
        case inactive
        case partiallyActive
        case active
    }

    enum Stage: Equatable {
        case inactive
        case usbNotAttached
        case wireGuardNeedsAttention
        case wireGuardDisconnected
        case dummyEthernetHelperProblem
        case dummyEthernetNotChecked
        case dummyEthernetStopped
        case dummyEthernetNeedsAttention
        case active
    }

    let activity: Activity
    let stage: Stage

    init(
        vmRuntimeState: VMRuntimeState,
        isUSBAttached: Bool,
        dummyEthernetState: DummyEthernetState? = nil,
        wireGuardTunnelStatus: WireGuardTunnelStatus?,
        hasWireGuardFailure: Bool = false
    ) {
        let isVMRunning = vmRuntimeState == .running
        let isWireGuardConnected = wireGuardTunnelStatus == .connected
        let isWireGuardActive = isWireGuardConnected && !hasWireGuardFailure
        var activeComponents = [
            isVMRunning,
            isUSBAttached,
        ]
        if wireGuardTunnelStatus != nil {
            activeComponents.append(isWireGuardActive)
        }
        if let dummyEthernetState {
            activeComponents.append(dummyEthernetState == .active)
        }
        let activeComponentCount = activeComponents.filter { $0 }.count

        switch activeComponentCount {
        case 0:
            activity = .inactive
        case activeComponents.count:
            activity = .active
        default:
            activity = .partiallyActive
        }

        if !isVMRunning {
            stage = .inactive
        } else if !isUSBAttached {
            stage = .usbNotAttached
        } else if wireGuardTunnelStatus != nil, hasWireGuardFailure {
            stage = .wireGuardNeedsAttention
        } else if wireGuardTunnelStatus != nil, !isWireGuardConnected {
            stage = .wireGuardDisconnected
        } else if let dummyEthernetState,
                  dummyEthernetState != .active {
            switch dummyEthernetState {
            case .helperProblem:
                stage = .dummyEthernetHelperProblem
            case .notChecked:
                stage = .dummyEthernetNotChecked
            case .stopped:
                stage = .dummyEthernetStopped
            case .needsAttention:
                stage = .dummyEthernetNeedsAttention
            case .active:
                preconditionFailure("Active Dummy Ethernet cannot block status")
            }
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
        case .wireGuardNeedsAttention:
            return String(
                localized: "WireGuard: \(String(localized: "Needs Attention"))"
            )
        case .wireGuardDisconnected:
            return String(localized: "WireGuard Disconnected")
        case .dummyEthernetHelperProblem:
            return String(localized: "Dummy Ethernet helper problem")
        case .dummyEthernetNotChecked:
            return String(
                localized: "Dummy Ethernet: \(String(localized: "Not Checked"))"
            )
        case .dummyEthernetStopped:
            return String(
                localized: "Dummy Ethernet: \(String(localized: "Stopped"))"
            )
        case .dummyEthernetNeedsAttention:
            return String(
                localized: "Dummy Ethernet: \(String(localized: "Needs Attention"))"
            )
        case .active:
            return String(
                localized: "menuBar.combinedStatus.running",
                defaultValue: "Running"
            )
        }
    }
}
