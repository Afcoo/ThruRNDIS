/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum ThruRNDISTunnel {
    static let displayName = "ThruRNDIS"
    static let wireGuardConfigurationOptionKey = "ThruRNDISWireGuardConfiguration"
    static let systemExtensionsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ExtensionsPreferences" +
            "?extensionPointIdentifier=com.apple.system_extension.network_extension.extension-point"
    )!

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
