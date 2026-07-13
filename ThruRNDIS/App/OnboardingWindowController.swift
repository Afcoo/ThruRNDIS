/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(
        store: TetheringStore,
        assetController: VMAssetController,
        onFinish: @escaping () -> Void
    ) {
        let rootView = OnboardingView(onFinish: onFinish)
            .environmentObject(store)
            .environmentObject(assetController)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "Welcome to ThruRNDIS"
        window.styleMask = [.titled, .closable, .miniaturizable]
        let preferredContentSize = NSSize(width: 576, height: 360)
        let titleBarHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: preferredContentSize)
        ).height - preferredContentSize.height
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let availableContentHeight = visibleHeight - titleBarHeight - 32

        window.setContentSize(
            NSSize(
                width: preferredContentSize.width,
                height: min(preferredContentSize.height, max(240, availableContentHeight))
            )
        )
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
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
