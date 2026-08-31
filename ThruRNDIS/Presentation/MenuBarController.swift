/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let statusBarImage: NSImage? = {
        guard let imageURL = Bundle.main.url(
            forResource: "ThruRNDISMenuBarIcon",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: imageURL) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private let store: TetheringStore
    private let networkRoute: NetworkRouteStore
    private let assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var combinedStatusItem: NSMenuItem?
    private var vmStatusItem: NSMenuItem?
    private var usbStatusItem: NSMenuItem?
    private var networkStatusItem: NSMenuItem?
    private var vmActionItem: NSMenuItem?
    private var stopVMItem: NSMenuItem?
    private var attachSubmenu: NSMenu?
    private var detachItem: NSMenuItem?
    private var networkActionItem: NSMenuItem?
    private var stopNetworkItem: NSMenuItem?
    private var isMenuOpen = false
    private var isPresentationRefreshScheduled = false
    private var isPresentingPrompt = false
    private var presentedPromptAlert: NSAlert?

    init(
        store: TetheringStore,
        assetWorkflowCoordinator: VMAssetWorkflowCoordinator,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        networkRoute = store.networkRoute
        self.assetWorkflowCoordinator = assetWorkflowCoordinator
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()

        Publishers.MergeMany([
            store.objectWillChange.eraseToAnyPublisher(),
            store.appPreferences.objectWillChange.eraseToAnyPublisher(),
            store.usbSession.objectWillChange.eraseToAnyPublisher(),
            networkRoute.objectWillChange.eraseToAnyPublisher(),
            networkRoute.helper.objectWillChange.eraseToAnyPublisher(),
            assetWorkflowCoordinator.objectWillChange.eraseToAnyPublisher(),
        ])
        .sink { [weak self] in
            self?.schedulePresentationRefresh()
        }
        .store(in: &cancellables)

        networkRoute.refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        networkRoute.refresh()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        refreshPresentation()
    }

    func present(
        prompt: USBAttachmentPrompt,
        completion: @escaping (Bool) -> Void
    ) {
        guard !isPresentingPrompt else { return }
        isPresentingPrompt = true
        menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: prompt.primaryButtonTitle)
        alert.addButton(withTitle: String(localized: "Not Now"))
        presentedPromptAlert = alert
        let response = alert.runModal()
        presentedPromptAlert = nil
        isPresentingPrompt = false
        completion(response == .alertFirstButtonReturn)
    }

    func dismissPresentedPrompt() {
        guard isPresentingPrompt, let presentedPromptAlert else { return }
        NSApp.abortModal()
        presentedPromptAlert.window.orderOut(nil)
    }

    private func rebuildMenu() {
        let status = combinedStatus
        menu.removeAllItems()
        clearMenuReferences()

        let guidance = configurationGuidanceTitles
        guidance.forEach { menu.addItem(informationalItem(title: $0)) }
        let displaysOperations = guidance.isEmpty
            || store.appPreferences.isDebugModeEnabled
        if displaysOperations {
            if !guidance.isEmpty { menu.addItem(.separator()) }
            addStatusSection(status: status)
            if store.appPreferences.isDebugModeEnabled {
                menu.addItem(.separator())
                addVMControlsSection()
            }
            menu.addItem(.separator())
            addUSBControlsSection()
            if store.appPreferences.isDebugModeEnabled {
                menu.addItem(.separator())
                addNetworkControlsSection()
            }
        }
        addSettingsAndQuitItems()
        refreshPresentation(with: status)
    }

    private func addStatusSection(status: MenuBarCombinedStatus) {
        if store.appPreferences.isDebugModeEnabled {
            vmStatusItem = statusItemLine(
                title: vmStatusTitle,
                dotColor: vmStatusColor
            )
            usbStatusItem = statusItemLine(
                title: usbStatusTitle,
                dotColor: usbStatusColor
            )
            networkStatusItem = statusItemLine(
                title: networkStatusTitle,
                dotColor: networkStatusColor
            )
            menu.addItem(vmStatusItem!)
            menu.addItem(usbStatusItem!)
            menu.addItem(networkStatusItem!)
        } else {
            combinedStatusItem = statusItemLine(
                title: status.title,
                dotColor: combinedStatusColor(status)
            )
            menu.addItem(combinedStatusItem!)
        }
    }

    private func addVMControlsSection() {
        vmActionItem = actionItem(title: "", action: #selector(startOrRestartVM))
        stopVMItem = actionItem(
            title: String(localized: "Stop VM"),
            action: #selector(stopVM)
        )
        menu.addItem(vmActionItem!)
        menu.addItem(stopVMItem!)
    }

    private func addUSBControlsSection() {
        let attachItem = attachMenuItem()
        attachSubmenu = attachItem.submenu
        menu.addItem(attachItem)
        detachItem = actionItem(
            title: String(localized: "Detach USB"),
            action: #selector(detachUSB)
        )
        menu.addItem(detachItem!)
    }

    private func addNetworkControlsSection() {
        networkActionItem = actionItem(
            title: "",
            action: #selector(startOrRestartNetworkRouting)
        )
        stopNetworkItem = actionItem(
            title: String(localized: "Stop Network Routing"),
            action: #selector(stopNetworkRouting)
        )
        menu.addItem(networkActionItem!)
        menu.addItem(stopNetworkItem!)
    }

    private func addSettingsAndQuitItems() {
        menu.addItem(.separator())
        let settings = actionItem(
            title: String(localized: "Settings…"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(
            actionItem(
                title: String(localized: "Quit ThruRNDIS"),
                action: #selector(quit),
                keyEquivalent: "q"
            )
        )
    }

    private func schedulePresentationRefresh() {
        guard !isPresentationRefreshScheduled else { return }
        isPresentationRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPresentationRefreshScheduled = false
            if self.isMenuOpen {
                self.refreshPresentation()
            } else {
                self.rebuildMenu()
            }
        }
    }

    private func refreshPresentation() {
        refreshPresentation(with: combinedStatus)
    }

    private func refreshPresentation(with status: MenuBarCombinedStatus) {
        updateStatusButton(status: status)
        updateStatusItem(
            combinedStatusItem,
            title: status.title,
            dotColor: combinedStatusColor(status)
        )
        updateStatusItem(
            vmStatusItem,
            title: vmStatusTitle,
            dotColor: vmStatusColor
        )
        updateStatusItem(
            usbStatusItem,
            title: usbStatusTitle,
            dotColor: usbStatusColor
        )
        updateStatusItem(
            networkStatusItem,
            title: networkStatusTitle,
            dotColor: networkStatusColor
        )

        if store.runtimeState == .running {
            vmActionItem?.title = String(localized: "Restart VM")
            vmActionItem?.isEnabled = store.canRestartVirtualMachine
        } else {
            vmActionItem?.title = String(localized: "Start VM")
            vmActionItem?.isEnabled = store.canStartVirtualMachine
        }
        stopVMItem?.isEnabled = store.canStopVirtualMachine
        refreshAttachSubmenu()
        detachItem?.isEnabled = store.canDetachAccessory
        if networkRoute.snapshot?.state == .active {
            networkActionItem?.title = String(
                localized: "Restart Network Routing"
            )
            networkActionItem?.isEnabled = networkRoute.canRestart
        } else {
            networkActionItem?.title = String(
                localized: "Start Network Routing"
            )
            networkActionItem?.isEnabled = networkRoute.canStart
        }
        stopNetworkItem?.isEnabled = networkRoute.canStop
    }

    private func updateStatusButton(status: MenuBarCombinedStatus) {
        guard let button = statusItem.button else { return }
        button.image = Self.statusBarImage
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.attributedTitle = Self.statusDotTitle(
            color: combinedStatusColor(status)
        )
        button.setAccessibilityLabel(String(localized: "ThruRNDIS status"))
        button.setAccessibilityValue(status.title)
        if configurationGuidanceTitles.isEmpty {
            button.toolTip = "ThruRNDIS — \(status.title)"
        } else {
            button.toolTip = configurationGuidanceTitles.joined(separator: "\n")
        }
    }

    private static func statusDotTitle(color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 6, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

    private var configurationGuidanceTitles: [String] {
        [
            assetWorkflowCoordinator.hasConfiguredAssets
                ? nil : String(localized: "Configure VM Assets in Settings"),
            networkRoute.helper.registrationStatus == .enabled
                ? nil : String(localized: "Configure Network Routing in Settings"),
        ].compactMap { $0 }
    }

    private var combinedStatus: MenuBarCombinedStatus {
        MenuBarCombinedStatus(
            vmRuntimeState: store.runtimeState,
            isUSBAttached: store.usbSession.attachedAccessoryID != nil,
            guestIPv4Address: networkRoute.guestIPv4Address,
            vznatGatewayIPv4Address:
                networkRoute.vznatGatewayIPv4Address,
            isRNDISRouteReady: networkRoute.isRNDISRouteReady,
            isNetworkRouteTransitioning: networkRoute.operation != nil,
            networkRouteSnapshot: networkRoute.snapshot
        )
    }

    private var vmStatusTitle: String {
        String(localized: "VM: \(store.vmDisplayState.localizedName)")
    }

    private var usbStatusTitle: String {
        guard let attachedAccessoryID = store.usbSession.attachedAccessoryID else {
            return String(localized: "USB: Not attached")
        }
        let deviceName = store.usbSession.accessories.first {
            $0.id == attachedAccessoryID
        }?.deviceName ?? String(localized: "USB Device")
        return String(localized: "USB: \(deviceName)")
    }

    private var networkStatusTitle: String {
        let title: String
        if let operation = networkRoute.operation {
            title = operation.title
        } else if let error = networkRoute.lastErrorMessage, !error.isEmpty {
            title = String(localized: "Needs Attention")
        } else {
            switch networkRoute.snapshot?.state {
            case .active:
                title = String(localized: "Active")
            case .degraded:
                title = String(localized: "Needs Attention")
            case .inactive:
                title = String(localized: "Stopped")
            case nil:
                title = networkRoute.helper.isAvailable
                    ? String(localized: "Waiting")
                    : String(localized: "Helper Problem")
            }
        }
        return String(localized: "Network Routing: \(title)")
    }

    private var vmStatusColor: NSColor {
        switch store.vmDisplayState {
        case .running:
            .systemGreen
        case .restarting:
            .systemYellow
        case .stopped:
            .systemRed
        }
    }

    private var usbStatusColor: NSColor {
        if store.usbSession.attachedAccessoryID != nil {
            return .systemGreen
        }
        return store.usbSession.accessories.isEmpty ? .systemRed : .systemYellow
    }

    private var networkStatusColor: NSColor {
        guard networkRoute.helper.isAvailable else { return .systemRed }
        if networkRoute.operation != nil { return .systemYellow }
        if networkRoute.lastErrorMessage != nil { return .systemRed }
        switch networkRoute.snapshot?.state {
        case .active:
            return .systemGreen
        case .degraded:
            return .systemRed
        case .inactive:
            return .systemRed
        case nil:
            return .systemGray
        }
    }

    private func combinedStatusColor(_ status: MenuBarCombinedStatus) -> NSColor {
        switch status.activity {
        case .inactive:
            .systemRed
        case .partiallyActive:
            .systemOrange
        case .active:
            .systemGreen
        }
    }

    private func refreshAttachSubmenu() {
        guard let attachSubmenu else { return }
        attachSubmenu.removeAllItems()
        guard !store.usbSession.accessories.isEmpty else {
            let empty = NSMenuItem(
                title: String(localized: "No USB devices"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            attachSubmenu.addItem(empty)
            return
        }
        for accessory in store.usbSession.accessories {
            let item = actionItem(
                title: Self.shortDeviceTitle(accessory),
                action: #selector(attachUSB(_:))
            )
            item.representedObject = NSNumber(value: accessory.id)
            item.state = accessory.id == store.usbSession.attachedAccessoryID
                ? .on : .off
            item.isEnabled = store.canChooseAccessoryForAttachment(accessory.id)
            attachSubmenu.addItem(item)
        }
    }

    private func attachMenuItem() -> NSMenuItem {
        let title = String(localized: "Attach USB")
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        parent.submenu = submenu
        return parent
    }

    private func statusItemLine(title: String, dotColor: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = MenuBarStatusDotImageFactory.makeImage(color: dotColor)
        item.preferredImageVisibility = .visible
        item.isEnabled = false
        return item
    }

    private func informationalItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func updateStatusItem(
        _ item: NSMenuItem?,
        title: String,
        dotColor: NSColor
    ) {
        item?.title = title
        item?.image = MenuBarStatusDotImageFactory.makeImage(color: dotColor)
    }

    private func actionItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = self
        return item
    }

    private func clearMenuReferences() {
        combinedStatusItem = nil
        vmStatusItem = nil
        usbStatusItem = nil
        networkStatusItem = nil
        vmActionItem = nil
        stopVMItem = nil
        attachSubmenu = nil
        detachItem = nil
        networkActionItem = nil
        stopNetworkItem = nil
    }

    @objc private func startOrRestartVM() {
        if store.runtimeState == .running {
            store.restartVirtualMachine()
        } else {
            store.startVirtualMachine()
        }
    }

    @objc private func stopVM() { store.stopVirtualMachine() }

    @objc private func attachUSB(_ sender: NSMenuItem) {
        guard let accessoryID = (sender.representedObject as? NSNumber)?.uint64Value
        else { return }
        store.requestAttachAccessory(id: accessoryID)
    }

    @objc private func detachUSB() { store.detachAccessory() }

    @objc private func startOrRestartNetworkRouting() {
        if networkRoute.snapshot?.state == .active {
            networkRoute.restartManually()
        } else {
            networkRoute.startManually()
        }
    }

    @objc private func stopNetworkRouting() { networkRoute.stopManually() }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private static func shortDeviceTitle(_ accessory: USBAccessoryRecord) -> String {
        "\(accessory.usbIDText) ⋅ \(accessory.deviceName)"
    }
}
