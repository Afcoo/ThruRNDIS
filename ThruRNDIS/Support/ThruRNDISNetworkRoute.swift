/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum ThruRNDISNetworkRoute {
    static let helperExecutableName = "ThruRNDISPrivilegedHelper"
    static let helperLaunchDaemonPlistName =
        "ThruRNDISPrivilegedHelper.plist"
    static let helperBundleIdentifierSuffix = ".privileged-helper"

    static let managedIPv4Prefixes = [
        "0.0.0.0/1",
        "128.0.0.0/1",
    ]

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
