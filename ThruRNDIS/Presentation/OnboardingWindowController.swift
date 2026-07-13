/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftUI

private enum OnboardingWindowLayout {
    static let width: CGFloat = 640
    static let compactHeight: CGFloat = 360
    static let expandedHeight: CGFloat = 600
    static let minimumHeight: CGFloat = 240
    static let screenMargin: CGFloat = 32
    static let resizeAnimationDuration: TimeInterval = 0.25
}

@MainActor
private final class OnboardingWindowResizeBridge {
    weak var window: NSWindow?

    func update(for step: Int) {
        guard let window else {
            return
        }

        let preferredHeight = step == 2
            ? OnboardingWindowLayout.expandedHeight
            : OnboardingWindowLayout.compactHeight
        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        let preferredContentSize = NSSize(
            width: OnboardingWindowLayout.width,
            height: preferredHeight
        )
        let titleBarHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: preferredContentSize)
        ).height - preferredContentSize.height
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: OnboardingWindowLayout.width, height: 800)
        let safeFrame = visibleFrame.insetBy(
            dx: OnboardingWindowLayout.screenMargin / 2,
            dy: OnboardingWindowLayout.screenMargin / 2
        )
        let currentFrame = window.frame
        let anchoredTop = min(
            max(currentFrame.maxY, safeFrame.minY),
            safeFrame.maxY
        )
        let availableFrameHeight = max(0, anchoredTop - safeFrame.minY)
        let availableContentHeight = max(0, availableFrameHeight - titleBarHeight)
        let minimumContentHeight = min(
            OnboardingWindowLayout.minimumHeight,
            availableContentHeight
        )
        let targetContentHeight = max(
            minimumContentHeight,
            min(preferredHeight, availableContentHeight)
        )
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(width: currentContentSize.width, height: targetContentHeight)
            )
        ).size

        let targetWidth = min(targetFrameSize.width, safeFrame.width)
        let targetX = min(
            max(currentFrame.minX, safeFrame.minX),
            safeFrame.maxX - targetWidth
        )
        let targetFrame = NSRect(
            x: targetX,
            y: anchoredTop - targetFrameSize.height,
            width: targetWidth,
            height: targetFrameSize.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = OnboardingWindowLayout.resizeAnimationDuration
            context.allowsImplicitAnimation = true
            window.animator().setFrame(targetFrame, display: true)
        }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(
        store: TetheringStore,
        assetWorkflowCoordinator: VMAssetWorkflowCoordinator,
        onFinish: @escaping () -> Void
    ) {
        let resizeBridge = OnboardingWindowResizeBridge()
        let rootView = OnboardingView(
            onFinish: onFinish,
            onStepChange: { step in
                resizeBridge.update(for: step)
            }
        )
            .environmentObject(store)
            .environmentObject(assetWorkflowCoordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "Welcome to ThruRNDIS"
        window.styleMask = [.titled, .closable, .miniaturizable]
        let preferredContentSize = NSSize(
            width: OnboardingWindowLayout.width,
            height: OnboardingWindowLayout.compactHeight
        )
        let titleBarHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: preferredContentSize)
        ).height - preferredContentSize.height
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let availableContentHeight = visibleHeight
            - titleBarHeight
            - OnboardingWindowLayout.screenMargin

        window.setContentSize(
            NSSize(
                width: preferredContentSize.width,
                height: min(
                    preferredContentSize.height,
                    max(OnboardingWindowLayout.minimumHeight, availableContentHeight)
                )
            )
        )
        resizeBridge.window = window
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
