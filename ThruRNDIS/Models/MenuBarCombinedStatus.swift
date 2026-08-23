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
        case waitingForGuestAddress
        case waitingForRNDIS
        case networkHelperProblem
        case networkRouteNeedsAttention
        case active
    }

    let activity: Activity
    let stage: Stage

    init(
        vmRuntimeState: VMRuntimeState,
        isUSBAttached: Bool,
        isNetworkHelperAvailable: Bool,
        guestIPv4Address: String?,
        isRNDISRouteReady: Bool,
        networkRouteSnapshot: NetworkRouteSnapshot?
    ) {
        let isVMRunning = vmRuntimeState == .running
        let isRouteActive = networkRouteSnapshot?.state == .active
        let components = [isVMRunning, isUSBAttached, isRouteActive]
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
        } else if guestIPv4Address == nil {
            stage = .waitingForGuestAddress
        } else if !isRNDISRouteReady {
            stage = .waitingForRNDIS
        } else if !isRouteActive {
            stage = .networkRouteNeedsAttention
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
        case .waitingForGuestAddress:
            String(localized: "Waiting for Guest Network")
        case .waitingForRNDIS:
            String(localized: "Waiting for RNDIS Route")
        case .networkHelperProblem:
            String(localized: "Network helper problem")
        case .networkRouteNeedsAttention:
            String(localized: "Network route needs attention")
        case .active:
            String(localized: "menuBar.combinedStatus.running", defaultValue: "Running")
        }
    }
}
