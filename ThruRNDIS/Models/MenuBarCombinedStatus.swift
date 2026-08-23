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
        case waitingForGuestNetwork
        case waitingForRNDIS
        case networkHelperProblem
        case vmNetworkNeedsAttention
        case active
    }

    let activity: Activity
    let stage: Stage

    init(
        vmRuntimeState: VMRuntimeState,
        isUSBAttached: Bool,
        isNetworkHelperAvailable: Bool,
        guestIPv4Address: String?,
        vznatGatewayIPv4Address: String?,
        isRNDISRouteReady: Bool,
        networkRouteSnapshot: NetworkRouteSnapshot?
    ) {
        let isVMRunning = vmRuntimeState == .running
        let isVMNetworkActive = networkRouteSnapshot?.state == .active
        let components = [isVMRunning, isUSBAttached, isVMNetworkActive]
        switch components.filter({ $0 }).count {
        case 0:
            activity = .inactive
        case components.count:
            activity = .active
        default:
            activity = .partiallyActive
        }

        if !isNetworkHelperAvailable {
            stage = .networkHelperProblem
        } else if !isVMRunning {
            stage = .inactive
        } else if !isUSBAttached {
            stage = .usbNotAttached
        } else if guestIPv4Address == nil
            || vznatGatewayIPv4Address == nil {
            stage = .waitingForGuestNetwork
        } else if !isRNDISRouteReady {
            stage = .waitingForRNDIS
        } else if !isVMNetworkActive {
            stage = .vmNetworkNeedsAttention
        } else {
            stage = .active
        }
    }

    var title: String {
        switch stage {
        case .inactive:
            String(localized: "menuBar.combinedStatus.notRunning", defaultValue: "Not Running")
        case .usbNotAttached:
            String(localized: "USB Not Attached")
        case .waitingForGuestNetwork:
            String(localized: "Waiting for Guest Network")
        case .waitingForRNDIS:
            String(localized: "Waiting for RNDIS")
        case .networkHelperProblem:
            String(localized: "Network helper problem")
        case .vmNetworkNeedsAttention:
            String(localized: "VM network needs attention")
        case .active:
            String(localized: "menuBar.combinedStatus.running", defaultValue: "Running")
        }
    }
}
