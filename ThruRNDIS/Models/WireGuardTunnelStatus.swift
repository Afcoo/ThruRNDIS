/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum WireGuardTunnelStatus: Equatable {
    case unconfigured
    case disconnected
    case connecting
    case connected
    case disconnecting

    var title: String {
        switch self {
        case .unconfigured:
            return String(localized: "Not configured")
        case .disconnected:
            return String(localized: "Disconnected")
        case .connecting:
            return String(localized: "Connecting")
        case .connected:
            return String(localized: "Provider connected")
        case .disconnecting:
            return String(localized: "Disconnecting")
        }
    }

    var eventLogDescription: String {
        switch self {
        case .unconfigured:
            return "Not configured — Start the VM and wait for its WireGuard endpoint."
        case .disconnected:
            return "Disconnected — Ready to connect macOS to the VM WireGuard peer."
        case .connecting:
            return "Connecting — Preparing and starting the WireGuard packet tunnel provider."
        case .connected:
            return "Provider connected — Verify the handshake separately through the VM console."
        case .disconnecting:
            return "Disconnecting — Stopping the WireGuard packet tunnel."
        }
    }

    var isConnectingOrConnected: Bool {
        switch self {
        case .connected, .connecting:
            return true
        case .unconfigured, .disconnected, .disconnecting:
            return false
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .connecting, .disconnecting:
            return true
        case .unconfigured, .disconnected, .connected:
            return false
        }
    }

    var canRequestStop: Bool {
        switch self {
        case .connecting, .connected:
            return true
        case .unconfigured, .disconnected, .disconnecting:
            return false
        }
    }
}

struct WireGuardTunnelFailure: Equatable {
    let message: String

    static let missingPacketTunnelEntitlement = Self(
        message: "NetworkExtension packet tunnel entitlement is missing."
    )
    static let missingSystemExtensionInstallEntitlement = Self(
        message: "System Extension installation entitlement is missing."
    )
}

enum WireGuardSystemExtensionStatus: Equatable {
    case unknown
    case checking
    case inactive
    case activationRequested
    case awaitingUserApproval
    case active
    case uninstalling
    case restartRequired
    case failed(String)

    var title: String {
        switch self {
        case .unknown:
            return String(localized: "Not Checked")
        case .checking:
            return String(localized: "Checking…")
        case .inactive:
            return String(localized: "Inactive")
        case .activationRequested:
            return String(localized: "Activation Requested")
        case .awaitingUserApproval:
            return String(localized: "Awaiting User Approval")
        case .active:
            return String(localized: "Active")
        case .uninstalling:
            return String(localized: "Uninstalling")
        case .restartRequired:
            return String(localized: "Restart Required")
        case .failed:
            return String(localized: "Unavailable")
        }
    }

    var eventLogDescription: String {
        switch self {
        case .unknown:
            return "Not Checked — The network extension status is unknown."
        case .checking:
            return "Checking — Reading the network extension properties."
        case .inactive:
            return "Inactive — Activation and user approval are required."
        case .activationRequested:
            return "Activation Requested — Waiting for macOS to process the request."
        case .awaitingUserApproval:
            return "Awaiting User Approval — Allow the extension in System Settings."
        case .active:
            return "Active — The network extension is enabled."
        case .uninstalling:
            return "Uninstalling — The network extension cannot be used."
        case .restartRequired:
            return "Restart Required — Restart macOS to finish activation."
        case .failed(let message):
            return "Unavailable — \(message)"
        }
    }

    var isActive: Bool {
        self == .active
    }

    var isTransitioning: Bool {
        switch self {
        case .checking, .activationRequested:
            return true
        case .unknown, .inactive, .awaitingUserApproval, .active,
             .uninstalling, .restartRequired, .failed:
            return false
        }
    }

    var canRequestActivation: Bool {
        switch self {
        case .unknown, .inactive, .failed:
            return true
        case .checking, .activationRequested, .awaitingUserApproval, .active,
             .uninstalling, .restartRequired:
            return false
        }
    }
}
