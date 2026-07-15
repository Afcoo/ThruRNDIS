/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct WireGuardConfElements: Equatable {
    var serverAddress: String
    var clientAddress: String
    var serverPeerAllowedIPs: String
    var clientAllowedIPs: String
    var listenPort: Int
    var serverMTU: Int
    var clientMTU: Int
    var dnsServers: [String]
    var persistentKeepalive: Int
    var endpointPlaceholder: String

    static let defaults = WireGuardConfElements(
        serverAddress: "10.100.0.1/24",
        clientAddress: "10.100.0.2/24",
        serverPeerAllowedIPs: "10.100.0.2/32",
        clientAllowedIPs: "10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1",
        listenPort: 51820,
        serverMTU: 1420,
        clientMTU: 1420,
        dnsServers: [],
        persistentKeepalive: 25,
        endpointPlaceholder: "<THRURNDIS_WG_ENDPOINT>"
    )
}

struct WireGuardKeyMaterial: Equatable {
    let serverPrivateKey: String
    let serverPublicKey: String
    let clientPrivateKey: String
    let clientPublicKey: String
}

struct WireGuardConfBuilder {
    let elements: WireGuardConfElements

    init(elements: WireGuardConfElements = .defaults) {
        self.elements = elements
    }

    func validate() throws {
        try requireValue(elements.serverAddress, field: "server Address")
        try requireValue(elements.clientAddress, field: "client Address")
        try requireValue(elements.serverPeerAllowedIPs, field: "server peer AllowedIPs")
        try requireValue(elements.clientAllowedIPs, field: "client peer AllowedIPs")
        try requireValue(elements.endpointPlaceholder, field: "client Endpoint placeholder")

        guard (1...65_535).contains(elements.listenPort) else {
            throw WireGuardConfBuilderError.invalidInteger(
                field: "ListenPort",
                value: elements.listenPort
            )
        }
        guard elements.serverMTU > 0 else {
            throw WireGuardConfBuilderError.invalidInteger(
                field: "server MTU",
                value: elements.serverMTU
            )
        }
        guard elements.clientMTU > 0 else {
            throw WireGuardConfBuilderError.invalidInteger(
                field: "client MTU",
                value: elements.clientMTU
            )
        }
        guard (0...65_535).contains(elements.persistentKeepalive) else {
            throw WireGuardConfBuilderError.invalidInteger(
                field: "PersistentKeepalive",
                value: elements.persistentKeepalive
            )
        }
    }

    func serverConfiguration(keyMaterial: WireGuardKeyMaterial) -> String {
        """
        [Interface]
        PrivateKey = \(keyMaterial.serverPrivateKey)
        Address = \(elements.serverAddress)
        ListenPort = \(elements.listenPort)
        MTU = \(elements.serverMTU)

        [Peer]
        PublicKey = \(keyMaterial.clientPublicKey)
        AllowedIPs = \(elements.serverPeerAllowedIPs)
        PersistentKeepalive = \(elements.persistentKeepalive)

        """
    }

    func clientConfiguration(
        keyMaterial: WireGuardKeyMaterial,
        endpoint: String?
    ) -> String {
        let dnsLine = elements.dnsServers.isEmpty
            ? ""
            : "DNS = \(elements.dnsServers.joined(separator: ", "))\n"
        let resolvedEndpoint = endpoint ?? elements.endpointPlaceholder

        return """
        [Interface]
        PrivateKey = \(keyMaterial.clientPrivateKey)
        Address = \(elements.clientAddress)
        MTU = \(elements.clientMTU)
        \(dnsLine)
        [Peer]
        PublicKey = \(keyMaterial.serverPublicKey)
        AllowedIPs = \(elements.clientAllowedIPs)
        Endpoint = \(resolvedEndpoint)
        PersistentKeepalive = \(elements.persistentKeepalive)
        """
    }

    func settings(
        keyMaterial: WireGuardKeyMaterial? = nil,
        endpoint: String? = nil
    ) -> WireGuardSettings {
        WireGuardSettings(
            serverPrivateKey: keyMaterial?.serverPrivateKey ?? "",
            serverPublicKey: keyMaterial?.serverPublicKey ?? "",
            clientPrivateKey: keyMaterial?.clientPrivateKey ?? "",
            clientPublicKey: keyMaterial?.clientPublicKey ?? "",
            endpoint: endpoint,
            serverAddress: elements.serverAddress,
            hostTunnelAddress: elements.clientAddress,
            hostPeerAllowedIP: elements.serverPeerAllowedIPs,
            listenPort: elements.listenPort,
            mtu: elements.clientMTU,
            dnsServers: elements.dnsServers,
            persistentKeepalive: elements.persistentKeepalive,
            allowedIPs: elements.clientAllowedIPs
        )
    }

    private func requireValue(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WireGuardConfBuilderError.missingValue(field)
        }
    }
}

enum WireGuardConfBuilderError: LocalizedError {
    case missingValue(String)
    case invalidInteger(field: String, value: Int)

    var errorDescription: String? {
        switch self {
        case .missingValue(let field):
            return String(localized: "Missing WireGuard configuration value: \(field).")
        case .invalidInteger(let field, let value):
            return String(localized: "Invalid WireGuard configuration integer for \(field): \(value).")
        }
    }
}
