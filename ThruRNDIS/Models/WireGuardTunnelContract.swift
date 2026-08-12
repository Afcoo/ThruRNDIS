/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct WireGuardConnectionConfiguration: Codable, Equatable, Sendable {
    let privateKey: Data
    let interfaceAddress: String
    let mtu: UInt16
    let dnsServers: [String]
    let peerPublicKey: Data
    let allowedIPs: [String]
    let endpoint: String
    let persistentKeepalive: UInt16
}

enum WireGuardTunnelContract {
    static let displayName = "ThruRNDIS"
    static let tunnelConfigurationOptionKey = "ThruRNDISWireGuardConnectionConfiguration"

    private static let providerBundleIdentifierSuffix = ".network-extension"

    static func providerBundleIdentifier(derivedFrom bundleIdentifier: String) -> String {
        "\(appBundleIdentifier(derivedFrom: bundleIdentifier))\(providerBundleIdentifierSuffix)"
    }

    private static func appBundleIdentifier(derivedFrom bundleIdentifier: String) -> String {
        guard bundleIdentifier.hasSuffix(providerBundleIdentifierSuffix) else {
            return bundleIdentifier
        }
        return String(bundleIdentifier.dropLast(providerBundleIdentifierSuffix.count))
    }
}
