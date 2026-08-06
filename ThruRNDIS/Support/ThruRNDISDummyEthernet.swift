/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum ThruRNDISDummyEthernet {
    static let defaultHostIPv4Address = "192.168.100.2"
    static let subnetMask = "255.255.255.0"
    static let defaultMemberInterfaceName = "feth0"
    static let defaultPeerInterfaceName = "feth1"
    static let maximumInterfaceNameUTF8ByteCount = 15
    static let bondHardwarePortName = "ThruRNDIS Dummy Bond"
    static let networkServiceName = "ThruRNDIS Dummy Ethernet"
    static let systemConfigurationMetadataKey =
        "ThruRNDIS.DummyEthernet.Configuration"
    static let helperExecutableName = "ThruRNDISPrivilegedHelper"
    static let helperLaunchDaemonPlistName = "ThruRNDISPrivilegedHelper.plist"

    private static let helperBundleIdentifierSuffix = ".privileged-helper"

    static func helperBundleIdentifier(
        derivedFrom applicationBundleIdentifier: String
    ) -> String {
        "\(applicationBundleIdentifier)\(helperBundleIdentifierSuffix)"
    }

    static func applicationBundleIdentifier(
        derivedFromHelperBundleIdentifier helperBundleIdentifier: String
    ) -> String? {
        guard helperBundleIdentifier.hasSuffix(helperBundleIdentifierSuffix),
              helperBundleIdentifier.count > helperBundleIdentifierSuffix.count else {
            return nil
        }
        return String(
            helperBundleIdentifier.dropLast(helperBundleIdentifierSuffix.count)
        )
    }
}
