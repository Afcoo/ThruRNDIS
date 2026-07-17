/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import NetworkExtension
import os
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var wireGuardAdapter = WireGuardAdapter(with: self) { logLevel, message in
        let osLogType: OSLogType = logLevel == .error ? .error : .debug
        os_log("%{public}@", type: osLogType, message)
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let configurationData = options?[
            ThruRNDISTunnel.wireGuardConfigurationOptionKey
        ] as? Data else {
            completionHandler(PacketTunnelProviderError.missingConfiguration)
            return
        }
        guard let configurationText = String(data: configurationData, encoding: .utf8),
              let tunnelConfiguration = try? TunnelConfiguration(
                fromWgQuickConfig: configurationText,
                called: ThruRNDISTunnel.displayName
              ) else {
            completionHandler(PacketTunnelProviderError.invalidConfiguration)
            return
        }

        wireGuardAdapter.start(tunnelConfiguration: tunnelConfiguration) { adapterError in
            guard let adapterError else {
                completionHandler(nil)
                return
            }

            switch adapterError {
            case .cannotLocateTunnelFileDescriptor:
                completionHandler(PacketTunnelProviderError.tunnelFileDescriptorUnavailable)
            case .dnsResolution:
                completionHandler(PacketTunnelProviderError.dnsResolutionFailed)
            case .setNetworkSettings:
                completionHandler(PacketTunnelProviderError.networkSettingsRejected)
            case .startWireGuardBackend:
                completionHandler(PacketTunnelProviderError.backendStartFailed)
            case .invalidState:
                completionHandler(PacketTunnelProviderError.backendStartFailed)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        wireGuardAdapter.stop { _ in
            completionHandler()
        }
    }
}
