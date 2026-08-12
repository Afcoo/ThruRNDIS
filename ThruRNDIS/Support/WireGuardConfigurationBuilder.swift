/*
Copyright (C) 2026 Afcoo.
*/

struct WireGuardConfigurationElements: Equatable {
    var serverAddress: String
    var clientAddress: String
    var serverPeerAllowedIPs: [String]
    var clientAllowedIPs: [String]
    var listenPort: UInt16
    var serverMTU: UInt16
    var clientMTU: UInt16
    var dnsServers: [String]
    var persistentKeepalive: UInt16

    static let defaults = WireGuardConfigurationElements(
        serverAddress: "10.100.0.1/24",
        clientAddress: "10.100.0.2/24",
        serverPeerAllowedIPs: ["10.100.0.2/32"],
        clientAllowedIPs: ["0.0.0.0/0"],
        listenPort: 51820,
        serverMTU: 1420,
        clientMTU: 1420,
        dnsServers: ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"],
        persistentKeepalive: 25
    )
}

struct WireGuardConfigurationBuilder {
    let elements: WireGuardConfigurationElements

    init(elements: WireGuardConfigurationElements = .defaults) {
        self.elements = elements
    }

    func connectionConfiguration(
        keyMaterial: WireGuardKeyMaterial,
        endpoint: String,
        dnsServers: [String],
        allowedIPs: [String]
    ) -> WireGuardConnectionConfiguration {
        WireGuardConnectionConfiguration(
            privateKey: keyMaterial.clientPrivateKey,
            interfaceAddress: elements.clientAddress,
            mtu: elements.clientMTU,
            dnsServers: dnsServers,
            peerPublicKey: keyMaterial.serverPublicKey,
            allowedIPs: allowedIPs,
            endpoint: endpoint,
            persistentKeepalive: elements.persistentKeepalive
        )
    }
}
