/*
Copyright (C) 2026 Afcoo.
*/

import AppKit

@MainActor
enum NetworkExtensionSettingsOpener {
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ExtensionsPreferences" +
            "?extensionPointIdentifier=com.apple.system_extension.network_extension.extension-point"
    )!

    static func open() -> Bool {
        NSWorkspace.shared.open(settingsURL)
    }
}
