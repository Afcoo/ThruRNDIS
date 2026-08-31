/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum ThruRNDISNetworkRoute {
    static let helperExecutableName = "ThruRNDISPrivilegedHelper"
    static let helperLaunchDaemonPlistName =
        "ThruRNDISPrivilegedHelper.plist"
    static let helperBundleIdentifierSuffix = ".privileged-helper"

    static let hostIPv4Address = "192.168.100.2"
    static let routerIPv4Address = "192.168.100.1"
    static let subnetMask = "255.255.255.0"
    static let memberInterfaceName = "feth0"
    static let peerInterfaceName = "feth1"
    static let bondHardwarePortName = "ThruRNDIS Network Bond"
    static let networkServiceName = "ThruRNDIS Network"
    static let systemConfigurationMetadataKey =
        "ThruRNDIS.NetworkRoute.Configuration"

    static func helperBundleIdentifier(
        derivedFrom applicationBundleIdentifier: String
    ) -> String {
        applicationBundleIdentifier + helperBundleIdentifierSuffix
    }

    static func applicationBundleIdentifier(
        derivedFromHelperBundleIdentifier helperBundleIdentifier: String
    ) -> String? {
        guard helperBundleIdentifier.hasSuffix(helperBundleIdentifierSuffix)
        else {
            return nil
        }

        let applicationIdentifier = helperBundleIdentifier.dropLast(
            helperBundleIdentifierSuffix.count
        )
        return applicationIdentifier.isEmpty ? nil : String(applicationIdentifier)
    }
}
