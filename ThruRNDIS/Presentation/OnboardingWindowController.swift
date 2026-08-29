/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftUI

private enum OnboardingWindowLayout {
    static let width: CGFloat = 600
    static let minimumHeight: CGFloat = 240
    static let screenMargin: CGFloat = 32

    static func preferredContentSize<Content: View>(
        for hostingController: NSHostingController<Content>
    ) -> NSSize {
        let fittedSize = hostingController.sizeThatFits(
            in: NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        let fittedHeight = fittedSize.height.isFinite
            ? fittedSize.height.rounded(.up)
            : minimumHeight

        return NSSize(
            width: width,
            height: max(minimumHeight, fittedHeight)
        )
    }
}

@MainActor
private final class OnboardingWindowResizeBridge {
    weak var window: NSWindow?
    var preferredContentSizeProvider: (() -> NSSize)?
    private var updateSequence = 0

    func scheduleUpdate(for _: Int) {
        scheduleUpdate(animated: true)
    }

    func scheduleInitialUpdate() {
        scheduleUpdate(animated: false)
    }

    private func scheduleUpdate(animated: Bool) {
        updateSequence += 1
        let sequence = updateSequence

        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateSequence == sequence else {
                return
            }
            guard let preferredContentSize = self.preferredContentSizeProvider?() else {
                return
            }
            self.update(to: preferredContentSize, animated: animated)
        }
    }

    func update(to preferredContentSize: NSSize, animated: Bool) {
        guard let window else {
            return
        }

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
        let anchoredTop = currentFrame.maxY
        let safeAnchoredTop = min(
            max(currentFrame.maxY, safeFrame.minY),
            safeFrame.maxY
        )
        let availableFrameHeight = max(0, safeAnchoredTop - safeFrame.minY)
        let availableContentHeight = max(0, availableFrameHeight - titleBarHeight)
        let minimumContentHeight = min(
            OnboardingWindowLayout.minimumHeight,
            availableContentHeight
        )
        let targetContentHeight = max(
            minimumContentHeight,
            min(preferredContentSize.height, availableContentHeight)
        )
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: preferredContentSize.width,
                    height: targetContentHeight
                )
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

        if animated {
            window.setFrame(targetFrame, display: true, animate: true)
        } else {
            window.setFrame(targetFrame, display: false)
        }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onUserCloseRequest: () -> Void
    private let onClose: () -> Void
    private let resizeBridge: OnboardingWindowResizeBridge

    init(
        store: TetheringStore,
        assetWorkflowCoordinator: VMAssetWorkflowCoordinator,
        onFinish: @escaping () -> Void,
        onUserCloseRequest: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onUserCloseRequest = onUserCloseRequest
        self.onClose = onClose
        let resizeBridge = OnboardingWindowResizeBridge()
        self.resizeBridge = resizeBridge
        let rootView = OnboardingView(
            contentWidth: OnboardingWindowLayout.width,
            onFinish: onFinish,
            onStepChange: resizeBridge.scheduleUpdate
        )
            .environmentObject(store)
            .environmentObject(store.networkRoute)
            .environmentObject(store.networkRoute.helper)
            .environmentObject(assetWorkflowCoordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "ThruRNDIS"
        window.titleVisibility = .hidden
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .fullSizeContentView,
        ]
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        resizeBridge.window = window
        resizeBridge.preferredContentSizeProvider = { [weak hostingController] in
            guard let hostingController else {
                return NSSize(
                    width: OnboardingWindowLayout.width,
                    height: OnboardingWindowLayout.minimumHeight
                )
            }
            return OnboardingWindowLayout.preferredContentSize(
                for: hostingController
            )
        }
        let initialContentSize = OnboardingWindowLayout.preferredContentSize(
            for: hostingController
        )
        resizeBridge.update(to: initialContentSize, animated: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        resizeBridge.scheduleInitialUpdate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onUserCloseRequest()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
