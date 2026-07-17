/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum PacketTunnelProviderError: LocalizedError {
    case missingConfiguration
    case invalidConfiguration
    case dnsResolutionFailed
    case backendStartFailed
    case tunnelFileDescriptorUnavailable
    case networkSettingsRejected

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "ThruRNDIS must start this tunnel because no WireGuard configuration was provided."
        case .invalidConfiguration:
            return "The WireGuard configuration passed to the packet tunnel is invalid."
        case .dnsResolutionFailed:
            return "The WireGuard endpoint could not be resolved."
        case .backendStartFailed:
            return "The WireGuard backend could not be started."
        case .tunnelFileDescriptorUnavailable:
            return "The packet tunnel file descriptor could not be located."
        case .networkSettingsRejected:
            return "macOS rejected the WireGuard packet tunnel network settings."
        }
    }
}
