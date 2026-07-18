/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum HostWireGuardTunnelStatus: Equatable {
    case unconfigured
    case disconnected
    case activatingSystemExtension
    case connecting
    case connected
    case disconnecting
    case reasserting
    case failed(String)

    static let missingPacketTunnelEntitlement = Self.failed(
        "NetworkExtension packet tunnel entitlement is missing."
    )
    static let missingSystemExtensionInstallEntitlement = Self.failed(
        "System Extension installation entitlement is missing."
    )

    var title: String {
        switch self {
        case .unconfigured:
            return String(localized: "Not configured")
        case .disconnected:
            return String(localized: "Disconnected")
        case .activatingSystemExtension:
            return String(localized: "Activating System Extension")
        case .connecting:
            return String(localized: "Connecting")
        case .connected:
            return String(localized: "Provider connected")
        case .disconnecting:
            return String(localized: "Disconnecting")
        case .reasserting:
            return String(localized: "Reasserting")
        case .failed:
            return String(localized: "Failed")
        }
    }

    var eventLogDescription: String {
        switch self {
        case .unconfigured:
            return "Not configured — Start the VM and wait for its WireGuard endpoint."
        case .disconnected:
            return "Disconnected — Ready to connect macOS to the VM WireGuard peer."
        case .activatingSystemExtension:
            return "Activating System Extension — Waiting for macOS to activate the network extension."
        case .connecting:
            return "Connecting — Starting the WireGuard packet tunnel provider."
        case .connected:
            return "Provider connected — Verify the handshake separately through the VM console."
        case .disconnecting:
            return "Disconnecting — Stopping the WireGuard packet tunnel."
        case .reasserting:
            return "Reasserting — The WireGuard packet tunnel is reconnecting."
        case .failed(let message):
            return "Failed — \(message)"
        }
    }

    var isConnectingOrConnected: Bool {
        switch self {
        case .connected, .connecting, .reasserting:
            return true
        case .unconfigured, .disconnected, .activatingSystemExtension, .disconnecting, .failed:
            return false
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .activatingSystemExtension, .connecting, .disconnecting, .reasserting:
            return true
        case .unconfigured, .disconnected, .connected, .failed:
            return false
        }
    }

    var canRequestStop: Bool {
        switch self {
        case .activatingSystemExtension, .connecting, .connected, .reasserting, .failed:
            return true
        case .unconfigured, .disconnected, .disconnecting:
            return false
        }
    }
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
