/*
Copyright (C) 2026 Afcoo.
*/

import AppKit

@MainActor
enum NetworkExtensionSettingsOpener {
    static func open() -> Bool {
        NSWorkspace.shared.open(ThruRNDISTunnel.systemExtensionsSettingsURL)
    }
}
