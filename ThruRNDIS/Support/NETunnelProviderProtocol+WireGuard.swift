/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import NetworkExtension

extension NETunnelProviderProtocol {
    convenience init?(wireGuardConfiguration: WireGuardConnectionConfiguration) {
        self.init()

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return nil
        }

        providerBundleIdentifier = WireGuardTunnelContract.providerBundleIdentifier(
            derivedFrom: bundleIdentifier
        )
        providerConfiguration = ["ConfigurationVersion": 2]

        serverAddress = wireGuardConfiguration.endpoint
    }
}
