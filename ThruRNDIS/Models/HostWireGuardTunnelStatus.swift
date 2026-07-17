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
            return "Activating System Extension — Waiting for macOS to activate the WireGuard system extension."
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
