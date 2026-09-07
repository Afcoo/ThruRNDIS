/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct MenuBarCombinedStatus: Equatable {
    enum Activity: Equatable {
        case inactive
        case partiallyActive
        case active
        case error
    }

    enum Stage: Equatable {
        case vmAssetsNotConfigured
        case networkHelperNotConfigured
        case vmAssetsAndNetworkHelperNotConfigured
        case error
        case inactive
        case usbNotAttached
        case waitingForGuestNetwork
        case waitingForRNDIS
        case preparingNetworkRouting
        case vmNetworkNeedsAttention
        case active
    }

    let activity: Activity
    let stage: Stage
    let requiresConfiguration: Bool

    init(
        hasConfiguredVMAssets: Bool,
        isNetworkHelperEnabled: Bool,
        vmRuntimeState: VMRuntimeState,
        isUSBAttached: Bool,
        guestIPv4Address: String?,
        vznatGatewayIPv4Address: String?,
        isRNDISRouteReady: Bool,
        isNetworkRouteTransitioning: Bool,
        networkRouteSnapshot: NetworkRouteSnapshot?,
        hasBlockingError: Bool
    ) {
        let isVMRunning = vmRuntimeState == .running
        let isVMNetworkActive = networkRouteSnapshot?.state == .active
        let components = [isVMRunning, isUSBAttached, isVMNetworkActive]
        requiresConfiguration = !hasConfiguredVMAssets || !isNetworkHelperEnabled
        if requiresConfiguration || hasBlockingError {
            activity = .error
        } else {
            switch components.filter({ $0 }).count {
            case 0:
                activity = .inactive
            case components.count:
                activity = .active
            default:
                activity = .partiallyActive
            }
        }

        if !hasConfiguredVMAssets && !isNetworkHelperEnabled {
            stage = .vmAssetsAndNetworkHelperNotConfigured
        } else if !hasConfiguredVMAssets {
            stage = .vmAssetsNotConfigured
        } else if !isNetworkHelperEnabled {
            stage = .networkHelperNotConfigured
        } else if hasBlockingError {
            stage = .error
        } else if !isVMRunning {
            stage = .inactive
        } else if !isUSBAttached {
            stage = .usbNotAttached
        } else if guestIPv4Address == nil
            || vznatGatewayIPv4Address == nil {
            stage = .waitingForGuestNetwork
        } else if !isRNDISRouteReady {
            stage = .waitingForRNDIS
        } else if !isVMNetworkActive && isNetworkRouteTransitioning {
            stage = .preparingNetworkRouting
        } else if !isVMNetworkActive {
            stage = .vmNetworkNeedsAttention
        } else {
            stage = .active
        }
    }

    var title: String {
        switch stage {
        case .vmAssetsNotConfigured:
            String(localized: "VM Assets Setup Required")
        case .networkHelperNotConfigured:
            String(localized: "Network Helper Setup Required")
        case .vmAssetsAndNetworkHelperNotConfigured:
            String(localized: "VM Assets and Network Helper Setup Required")
        case .error:
            String(localized: "Error")
        case .inactive:
            String(localized: "menuBar.combinedStatus.notRunning", defaultValue: "Not Running")
        case .usbNotAttached:
            String(localized: "USB Not Attached")
        case .waitingForGuestNetwork, .waitingForRNDIS,
             .preparingNetworkRouting:
            String(localized: "Preparing Network Routing")
        case .vmNetworkNeedsAttention:
            String(localized: "Network Routing") + ": "
                + String(localized: "Needs Attention")
        case .active:
            String(localized: "menuBar.combinedStatus.running", defaultValue: "Running")
        }
    }
}
