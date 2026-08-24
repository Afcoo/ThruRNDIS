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
        case vmNetworkNeedsAttention
        case active
    }

    let activity: Activity
    let stage: Stage

    init(
        vmRuntimeState: VMRuntimeState,
        isUSBAttached: Bool,
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

        if !isVMRunning {
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
        case .waitingForGuestNetwork, .waitingForRNDIS, .vmNetworkNeedsAttention:
            String(localized: "Preparing Network")
        case .active:
            String(localized: "menuBar.combinedStatus.running", defaultValue: "Running")
        }
    }
}
