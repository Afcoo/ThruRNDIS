/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftUI

@MainActor
final class ConsoleWindowController: NSWindowController {
    init(store: TetheringStore) {
        let rootView = ConsoleView()
            .environmentObject(store)
            .environmentObject(store.consoleSession)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String(localized: "VM Console")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 600))
        window.minSize = NSSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setFrameAutosaveName("ThruRNDISVMConsoleWindow")
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
