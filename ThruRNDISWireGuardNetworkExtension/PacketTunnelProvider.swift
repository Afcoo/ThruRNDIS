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
            WireGuardTunnelContract.tunnelConfigurationOptionKey
        ] as? Data else {
            completionHandler(PacketTunnelProviderError.missingConfiguration)
            return
        }
        guard let connectionConfiguration = try? PropertyListDecoder().decode(
            WireGuardConnectionConfiguration.self,
            from: configurationData
        ),
              let tunnelConfiguration = connectionConfiguration
                .makeWireGuardKitConfiguration() else {
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

private extension WireGuardConnectionConfiguration {
    func makeWireGuardKitConfiguration() -> TunnelConfiguration? {
        guard let privateKey = PrivateKey(rawValue: self.privateKey),
              let interfaceAddress = IPAddressRange(from: self.interfaceAddress),
              let peerPublicKey = PublicKey(rawValue: self.peerPublicKey),
              let endpoint = Endpoint(from: self.endpoint) else {
            return nil
        }

        let dnsServers = self.dnsServers.compactMap(DNSServer.init(from:))
        let allowedIPs = self.allowedIPs.compactMap(IPAddressRange.init(from:))
        guard dnsServers.count == self.dnsServers.count,
              !allowedIPs.isEmpty,
              allowedIPs.count == self.allowedIPs.count else {
            return nil
        }

        var interfaceConfiguration = InterfaceConfiguration(privateKey: privateKey)
        interfaceConfiguration.addresses = [interfaceAddress]
        interfaceConfiguration.mtu = mtu
        interfaceConfiguration.dns = dnsServers

        var peerConfiguration = PeerConfiguration(publicKey: peerPublicKey)
        peerConfiguration.allowedIPs = allowedIPs
        peerConfiguration.endpoint = endpoint
        peerConfiguration.persistentKeepAlive = persistentKeepalive

        return TunnelConfiguration(
            name: WireGuardTunnelContract.displayName,
            interface: interfaceConfiguration,
            peers: [peerConfiguration]
        )
    }
}

private enum PacketTunnelProviderError: LocalizedError {
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
