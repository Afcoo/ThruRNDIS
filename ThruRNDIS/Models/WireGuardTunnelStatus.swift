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

enum WireGuardSystemExtensionInactiveReason: Equatable {
    case activationAvailable
    case awaitingUserApproval
    case restartRequired(WireGuardSystemExtensionRestartReason)
}

enum WireGuardSystemExtensionRestartReason: Equatable {
    case activation
    case removal
}

enum WireGuardSystemExtensionStatus: Equatable {
    case unknown(String?)
    case inactive(WireGuardSystemExtensionInactiveReason)
    case active

    static let notChecked = Self.unknown(nil)

    var title: String {
        switch self {
        case .unknown(nil):
            return String(localized: "Not Checked")
        case .unknown:
            return String(localized: "Unavailable")
        case .inactive:
            return String(localized: "Inactive")
        case .active:
            return String(localized: "Active")
        }
    }

    var eventLogDescription: String {
        switch self {
        case .unknown(nil):
            return "Not Checked — The network extension status is unknown."
        case .unknown(let message):
            let detail = message ?? "Unknown error."
            return "Unavailable — \(detail)"
        case .inactive(.activationAvailable):
            return "Inactive — Activation and user approval are required."
        case .inactive(.awaitingUserApproval):
            return "Awaiting User Approval — Allow the extension in System Settings."
        case .inactive(.restartRequired(.activation)):
            return "Restart Required — Restart macOS to finish activation."
        case .inactive(.restartRequired(.removal)):
            return "Restart Required — Restart macOS to finish removal."
        case .active:
            return "Active — The network extension is enabled."
        }
    }

    var isActive: Bool {
        self == .active
    }

    var canRequestActivation: Bool {
        switch self {
        case .unknown, .inactive(.activationAvailable):
            return true
        case .inactive(.awaitingUserApproval), .inactive(.restartRequired), .active:
            return false
        }
    }
}
