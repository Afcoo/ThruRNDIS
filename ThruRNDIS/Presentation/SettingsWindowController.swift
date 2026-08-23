/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        store: TetheringStore,
        assetWorkflowCoordinator: VMAssetWorkflowCoordinator,
        openConsole: @escaping () -> Void,
        resetAndQuit: @escaping () -> Void
    ) {
        let rootView = SettingsView(
            openConsole: openConsole,
            resetAndQuit: resetAndQuit
        )
            .environmentObject(store)
            .environmentObject(store.eventLog)
            .environmentObject(store.usbSession)
            .environmentObject(store.vmConfiguration)
            .environmentObject(store.appPreferences)
            .environmentObject(store.networkRoute)
            .environmentObject(store.networkRoute.helper)
            .environmentObject(assetWorkflowCoordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String(localized: "ThruRNDIS Settings")
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 760, height: 480))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
