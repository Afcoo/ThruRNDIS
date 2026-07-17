/*
Copyright (C) 2026 Afcoo.
*/

enum ThruRNDISTunnel {
    static let displayName = "ThruRNDIS"
    static let wireGuardConfigurationOptionKey = "ThruRNDISWireGuardConfiguration"

    private static let providerBundleIdentifierSuffix = ".wireguard-network-extension"

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
