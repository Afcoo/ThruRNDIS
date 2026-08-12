/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct WgQuickConfigurationRenderer {
    func render(_ configuration: WireGuardConnectionConfiguration) -> String {
        """
        [Interface]
        PrivateKey = \(configuration.privateKey.base64EncodedString())
        Address = \(configuration.interfaceAddress)
        MTU = \(configuration.mtu)
        DNS = \(configuration.dnsServers.joined(separator: ", "))

        [Peer]
        PublicKey = \(configuration.peerPublicKey.base64EncodedString())
        AllowedIPs = \(configuration.allowedIPs.joined(separator: ", "))
        Endpoint = \(configuration.endpoint)
        PersistentKeepalive = \(configuration.persistentKeepalive)

        """
    }

    func renderServer(
        keyMaterial: WireGuardKeyMaterial,
        elements: WireGuardConfigurationElements
    ) -> String {
        """
        [Interface]
        PrivateKey = \(keyMaterial.serverPrivateKey.base64EncodedString())
        Address = \(elements.serverAddress)
        ListenPort = \(elements.listenPort)
        MTU = \(elements.serverMTU)

        [Peer]
        PublicKey = \(keyMaterial.clientPublicKey.base64EncodedString())
        AllowedIPs = \(elements.serverPeerAllowedIPs.joined(separator: ", "))
        PersistentKeepalive = \(elements.persistentKeepalive)

        """
    }
}
