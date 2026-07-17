/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import NetworkExtension
import WireGuardKit

extension NETunnelProviderProtocol {
    convenience init?(thruRNDISConfiguration: TunnelConfiguration) {
        self.init()

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return nil
        }

        providerBundleIdentifier = ThruRNDISTunnel.providerBundleIdentifier(
            derivedFrom: bundleIdentifier
        )
        providerConfiguration = ["ConfigurationVersion": 1]

        let endpoints = thruRNDISConfiguration.peers.compactMap(\.endpoint)
        if endpoints.count == 1 {
            serverAddress = endpoints[0].stringRepresentation
        } else if endpoints.isEmpty {
            serverAddress = "Unspecified"
        } else {
            serverAddress = "Multiple endpoints"
        }
    }
}
