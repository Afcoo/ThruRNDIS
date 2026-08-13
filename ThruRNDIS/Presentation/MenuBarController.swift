/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Combine

private struct MenuBarPresentationMode: Equatable {
    let isDebugModeEnabled: Bool
    let isWireGuardManualConfigurationModeEnabled: Bool

    var displaysIndividualStatusItems: Bool {
        isDebugModeEnabled
    }

    var displaysVMControls: Bool {
        isDebugModeEnabled
    }

    var displaysWireGuard: Bool {
        !isWireGuardManualConfigurationModeEnabled
    }

    var displaysDummyEthernetControls: Bool {
        isDebugModeEnabled && !isWireGuardManualConfigurationModeEnabled
    }
}

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
    private let dummyEthernet: DummyEthernetStore
    private let dummyEthernetHelper: DummyEthernetHelperStore
    private let assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var combinedStatusItem: NSMenuItem?
    private var vmStatusItem: NSMenuItem?
    private var usbStatusItem: NSMenuItem?
    private var dummyEthernetStatusItem: NSMenuItem?
    private var wireGuardStatusItem: NSMenuItem?
    private var vmActionItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var dummyEthernetControlsSeparator: NSMenuItem?
    private var dummyEthernetPrimaryActionItem: NSMenuItem?
    private var stopDummyEthernetItem: NSMenuItem?
    private var wireGuardItem: NSMenuItem?
    private var attachSubmenu: NSMenu?
    private var detachItem: NSMenuItem?
    private var menuConfigurationGuidanceTitles: [String]?
    private var menuPresentationMode: MenuBarPresentationMode?
    private var isMenuOpen = false
    private var isPresentationRefreshScheduled = false
    private var isPresentingPrompt = false
    private var activeWireGuardPromptPresentation: (id: UUID, alert: NSAlert)?

    init(
        store: TetheringStore,
        assetWorkflowCoordinator: VMAssetWorkflowCoordinator,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.dummyEthernet = store.dummyEthernet
        self.dummyEthernetHelper = store.dummyEthernet.helper
        self.assetWorkflowCoordinator = assetWorkflowCoordinator
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        self.statusItem.menu = menu
        updateStatusButton()
        rebuildMenu()

        Publishers.Merge5(
            store.objectWillChange,
            store.appPreferences.objectWillChange,
            store.usbSession.objectWillChange,
            store.wireGuardSession.objectWillChange,
            assetWorkflowCoordinator.objectWillChange
        )
        .sink { [weak self] in
            self?.schedulePresentationRefresh()
        }
        .store(in: &cancellables)

        dummyEthernet.objectWillChange
            .sink { [weak self] in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)

        dummyEthernetHelper.objectWillChange
            .sink { [weak self] in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)

        if !store.appPreferences.isWireGuardManualConfigurationModeEnabled {
            dummyEthernet.refresh()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        if !store.appPreferences.isWireGuardManualConfigurationModeEnabled {
            dummyEthernet.refresh()
        }
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        refreshMenuPresentation()
    }

    private func schedulePresentationRefresh() {
        guard !isPresentationRefreshScheduled else {
            return
        }

        isPresentationRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isPresentationRefreshScheduled = false
            self.refreshMenuPresentation()
        }
    }

    func present(prompt: USBAttachmentPrompt, completion: @escaping (Bool) -> Void) {
        guard !isPresentingPrompt else {
            return
        }

        isPresentingPrompt = true
        menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: prompt.primaryButtonTitle)
        alert.addButton(withTitle: String(localized: "Not Now"))

        let response = alert.runModal()
        isPresentingPrompt = false
        completion(response == .alertFirstButtonReturn)
    }

    func present(
        prompt: WireGuardConnectionPrompt,
        completion: @escaping (_ accepted: Bool, _ shouldAutomaticallyConnectNextTime: Bool) -> Void
    ) {
        guard !isPresentingPrompt else {
            return
        }

        isPresentingPrompt = true
        menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Not Now"))

        let automaticConnectionCheckbox = NSButton(
            checkboxWithTitle: String(localized: "Connect Automatically Next Time"),
            target: nil,
            action: nil
        )
        alert.accessoryView = automaticConnectionCheckbox

        activeWireGuardPromptPresentation = (prompt.id, alert)
        let response = alert.runModal()
        isPresentingPrompt = false

        guard activeWireGuardPromptPresentation?.id == prompt.id else {
            return
        }

        activeWireGuardPromptPresentation = nil
        completion(
            response == .alertFirstButtonReturn,
            automaticConnectionCheckbox.state == .on
        )
    }

    func dismissWireGuardConnectionPrompt() {
        guard let presentation = activeWireGuardPromptPresentation else {
            return
        }

        activeWireGuardPromptPresentation = nil
        guard NSApp.modalWindow === presentation.alert.window else {
            return
        }

        NSApp.abortModal()
        presentation.alert.window.orderOut(nil)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.image = Self.statusBarImage
        button.setAccessibilityLabel(String(localized: "ThruRNDIS status"))
        let guidanceTitles = currentConfigurationGuidanceTitles
        if !guidanceTitles.isEmpty {
            button.toolTip = guidanceTitles.joined(separator: "\n")
        } else if store.appPreferences.isWireGuardManualConfigurationModeEnabled {
            button.toolTip = "ThruRNDIS — VM \(store.vmDisplayState.localizedName), \(usbStatusTitle)"
        } else {
            button.toolTip = String(
                localized: "ThruRNDIS — VM \(store.vmDisplayState.localizedName), \(usbStatusTitle), \(wireGuardStatusTitle), \(dummyEthernetStatusTitle)"
            )
        }
    }

    private func rebuildMenu() {
        clearDynamicMenuReferences()
        menu.removeAllItems()
        let configurationGuidanceTitles = currentConfigurationGuidanceTitles
        let presentationMode = currentPresentationMode
        menuConfigurationGuidanceTitles = configurationGuidanceTitles
        menuPresentationMode = presentationMode

        for guidanceTitle in configurationGuidanceTitles {
            menu.addItem(informationalItem(title: guidanceTitle))
        }

        let displaysOperationalSections = configurationGuidanceTitles.isEmpty
            || presentationMode.isDebugModeEnabled
        if displaysOperationalSections {
            if !configurationGuidanceTitles.isEmpty {
                menu.addItem(.separator())
            }
            addStatusSection(presentationMode: presentationMode)

            if presentationMode.displaysVMControls {
                menu.addItem(.separator())
                addVMControlsSection()
            }

            menu.addItem(.separator())
            addUSBControlsSection()
            if presentationMode.displaysWireGuard {
                menu.addItem(.separator())
                addWireGuardControlsSection()
            }
            if presentationMode.displaysDummyEthernetControls {
                addDummyEthernetControlsSection()
            }
        }

        addSettingsAndQuitItems()

        guard displaysOperationalSections else {
            return
        }

        if !presentationMode.isWireGuardManualConfigurationModeEnabled {
            refreshDummyEthernetPresentation()
        }
        refreshOperationalMenuPresentation()
    }

    private func addStatusSection(presentationMode: MenuBarPresentationMode) {
        if presentationMode.displaysIndividualStatusItems {
            let vmStatusItem = statusItemLine(
                title: String(localized: "VM: \(store.vmDisplayState.localizedName)"),
                dotColor: vmStatusColor
            )
            self.vmStatusItem = vmStatusItem
            menu.addItem(vmStatusItem)

            let usbStatusItem = statusItemLine(
                title: usbStatusTitle,
                dotColor: usbStatusColor
            )
            self.usbStatusItem = usbStatusItem
            menu.addItem(usbStatusItem)

            if presentationMode.displaysWireGuard {
                let wireGuardStatusItem = statusItemLine(
                    title: wireGuardStatusTitle,
                    dotColor: wireGuardStatusColor
                )
                self.wireGuardStatusItem = wireGuardStatusItem
                menu.addItem(wireGuardStatusItem)
            }

            if !presentationMode.isWireGuardManualConfigurationModeEnabled {
                addDummyEthernetStatusItem()
            }
        } else {
            addCombinedStatusItem()
        }
    }

    private func addVMControlsSection() {
        let vmActionItem = actionItem(title: "", action: #selector(startOrRestartVM))
        self.vmActionItem = vmActionItem
        menu.addItem(vmActionItem)

        let stopItem = actionItem(
            title: String(localized: "Stop VM"),
            action: #selector(stopVM)
        )
        self.stopItem = stopItem
        menu.addItem(stopItem)
    }

    private func addUSBControlsSection() {
        let attachMenuItem = attachMenuItem()
        attachSubmenu = attachMenuItem.submenu
        menu.addItem(attachMenuItem)

        let detachItem = actionItem(
            title: String(localized: "Detach USB"),
            action: #selector(detachUSB)
        )
        self.detachItem = detachItem
        menu.addItem(detachItem)
    }

    private func addWireGuardControlsSection() {
        let wireGuardItem = actionItem(title: "", action: #selector(connectWireGuard))
        self.wireGuardItem = wireGuardItem
        menu.addItem(wireGuardItem)
    }

    private func addDummyEthernetControlsSection() {
        let separator = NSMenuItem.separator()
        dummyEthernetControlsSeparator = separator
        menu.addItem(separator)

        let primaryActionItem = actionItem(
            title: "",
            action: #selector(startDummyEthernet)
        )
        dummyEthernetPrimaryActionItem = primaryActionItem
        menu.addItem(primaryActionItem)

        let stopItem = actionItem(
            title: String(localized: "Stop Dummy Ethernet"),
            action: #selector(stopDummyEthernet)
        )
        stopDummyEthernetItem = stopItem
        menu.addItem(stopItem)
    }

    private func clearDynamicMenuReferences() {
        combinedStatusItem = nil
        vmStatusItem = nil
        usbStatusItem = nil
        dummyEthernetStatusItem = nil
        wireGuardStatusItem = nil
        vmActionItem = nil
        stopItem = nil
        dummyEthernetControlsSeparator = nil
        dummyEthernetPrimaryActionItem = nil
        stopDummyEthernetItem = nil
        wireGuardItem = nil
        attachSubmenu = nil
        detachItem = nil
    }

    private func refreshMenuPresentation() {
        updateStatusButton()

        let configurationGuidanceTitles = currentConfigurationGuidanceTitles
        let presentationMode = currentPresentationMode
        guard menuConfigurationGuidanceTitles == configurationGuidanceTitles,
              menuPresentationMode == presentationMode else {
            if !isMenuOpen {
                rebuildMenu()
            }
            return
        }

        if !presentationMode.isWireGuardManualConfigurationModeEnabled {
            refreshDummyEthernetPresentation()
        }
        refreshCombinedStatusItem()

        guard configurationGuidanceTitles.isEmpty
                || presentationMode.isDebugModeEnabled else {
            return
        }

        refreshOperationalMenuPresentation()
    }

    private func refreshOperationalMenuPresentation() {
        updateStatusItem(
            vmStatusItem,
            title: String(localized: "VM: \(store.vmDisplayState.localizedName)"),
            dotColor: vmStatusColor
        )
        updateStatusItem(usbStatusItem, title: usbStatusTitle, dotColor: usbStatusColor)
        updateStatusItem(
            wireGuardStatusItem,
            title: wireGuardStatusTitle,
            dotColor: wireGuardStatusColor
        )

        if store.runtimeState == .running {
            vmActionItem?.title = String(localized: "Restart VM")
            vmActionItem?.isEnabled = store.canRestartVirtualMachine
        } else {
            vmActionItem?.title = String(localized: "Start VM")
            vmActionItem?.isEnabled = store.canStartVirtualMachine
        }

        stopItem?.isEnabled = store.canStopVirtualMachine

        if store.wireGuardSession.canDisconnectTunnel {
            wireGuardItem?.title = String(localized: "Disconnect WireGuard")
            wireGuardItem?.action = #selector(disconnectWireGuard)
            wireGuardItem?.isEnabled = store.canDisconnectWireGuardTunnel
        } else {
            wireGuardItem?.title = String(localized: "Connect WireGuard")
            wireGuardItem?.action = #selector(connectWireGuard)
            wireGuardItem?.isEnabled = store.canConnectWireGuardTunnel
        }

        refreshAttachSubmenu()
        detachItem?.isEnabled = store.canDetachAccessory
    }

    private func addDummyEthernetStatusItem() {
        let item = statusItemLine(
            title: dummyEthernetStatusTitle,
            dotColor: dummyEthernetStatusColor
        )
        dummyEthernetStatusItem = item
        menu.addItem(item)
    }

    private func refreshDummyEthernetPresentation() {
        updateStatusItem(
            dummyEthernetStatusItem,
            title: dummyEthernetStatusTitle,
            dotColor: dummyEthernetStatusColor
        )

        let displaysNetworkControls = canPresentDummyEthernetNetworkStatus
            && currentPresentationMode.displaysDummyEthernetControls
        dummyEthernetControlsSeparator?.isHidden = !displaysNetworkControls
        dummyEthernetPrimaryActionItem?.isHidden = !displaysNetworkControls
        stopDummyEthernetItem?.isHidden = !displaysNetworkControls

        if displaysNetworkControls {
            if dummyEthernet.isRestartActionPresented {
                dummyEthernetPrimaryActionItem?.title = String(
                    localized: "Restart Dummy Ethernet"
                )
                dummyEthernetPrimaryActionItem?.action =
                    #selector(restartDummyEthernet)
                dummyEthernetPrimaryActionItem?.isEnabled =
                    dummyEthernet.canRestart
            } else {
                dummyEthernetPrimaryActionItem?.title = String(
                    localized: "Start Dummy Ethernet"
                )
                dummyEthernetPrimaryActionItem?.action =
                    #selector(startDummyEthernet)
                dummyEthernetPrimaryActionItem?.isEnabled =
                    dummyEthernet.canStart
            }

            stopDummyEthernetItem?.isEnabled = dummyEthernet.canStop
        }
    }

    private func addCombinedStatusItem() {
        let combinedStatus = currentCombinedStatus
        let combinedStatusItem = statusItemLine(
            title: combinedStatus.title,
            dotColor: combinedStatusColor(for: combinedStatus)
        )
        self.combinedStatusItem = combinedStatusItem
        menu.addItem(combinedStatusItem)
    }

    private func refreshCombinedStatusItem() {
        let combinedStatus = currentCombinedStatus
        updateStatusItem(
            combinedStatusItem,
            title: combinedStatus.title,
            dotColor: combinedStatusColor(for: combinedStatus)
        )
    }

    private func updateStatusItem(
        _ item: NSMenuItem?,
        title: String,
        dotColor: NSColor
    ) {
        item?.title = title
        item?.image = MenuBarStatusDotImageFactory.makeImage(color: dotColor)
    }

    private func refreshAttachSubmenu() {
        guard let attachSubmenu else {
            return
        }

        let accessories = store.usbSession.accessories
        guard !accessories.isEmpty else {
            let noDevicesTitle = String(localized: "No USB devices")
            if attachSubmenu.items.count == 1,
               let item = attachSubmenu.items.first,
               item.representedObject == nil {
                item.title = noDevicesTitle
                item.isEnabled = false
            } else {
                attachSubmenu.removeAllItems()
                let item = NSMenuItem(title: noDevicesTitle, action: nil, keyEquivalent: "")
                item.isEnabled = false
                attachSubmenu.addItem(item)
            }
            return
        }

        let accessoryIDs = Set(accessories.map(\.id))
        for item in attachSubmenu.items.reversed() {
            guard let itemID = Self.accessoryID(for: item),
                  accessoryIDs.contains(itemID) else {
                attachSubmenu.removeItem(item)
                continue
            }
        }

        for (index, accessory) in accessories.enumerated() {
            let item: NSMenuItem
            if let existingItem = attachSubmenu.items.first(where: {
                Self.accessoryID(for: $0) == accessory.id
            }) {
                item = existingItem
            } else {
                item = actionItem(
                    title: Self.shortDeviceTitle(accessory),
                    action: #selector(attachUSB(_:))
                )
                item.representedObject = NSNumber(value: accessory.id)
                attachSubmenu.insertItem(item, at: min(index, attachSubmenu.items.count))
            }

            item.title = Self.shortDeviceTitle(accessory)
            item.state = accessory.id == store.usbSession.attachedAccessoryID ? .on : .off
            item.isEnabled = store.canChooseAccessoryForAttachment(accessory.id)

            let currentIndex = attachSubmenu.index(of: item)
            if currentIndex != index {
                attachSubmenu.removeItem(item)
                attachSubmenu.insertItem(item, at: index)
            }
        }
    }

    private func addSettingsAndQuitItems() {
        menu.addItem(.separator())

        let settingsItem = actionItem(
            title: String(localized: "Settings…"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: String(localized: "Quit ThruRNDIS"),
            action: #selector(quit),
            keyEquivalent: "q"
        ))
    }

    private var usbStatusTitle: String {
        guard let attachedAccessoryID = store.usbSession.attachedAccessoryID else {
            return String(localized: "USB: Not attached")
        }

        let deviceName = store.usbSession.accessories.first { $0.id == attachedAccessoryID }?.deviceName
            ?? String(localized: "USB Device")
        return String(localized: "USB: \(deviceName)")
    }

    private var wireGuardStatusTitle: String {
        let title = store.wireGuardSession.tunnelFailure == nil
            ? store.wireGuardSession.tunnelStatus.title
            : String(localized: "Failed")
        return String(localized: "WireGuard: \(title)")
    }

    private var dummyEthernetStatusTitle: String {
        guard canPresentDummyEthernetNetworkStatus else {
            return String(localized: "Dummy Ethernet helper problem")
        }

        let title: String
        if let operation = dummyEthernet.operation {
            title = operation.title
        } else {
            switch dummyEthernet.runtimeState {
            case nil:
                title = String(localized: "Not Checked")
            case .inactive:
                title = String(localized: "Stopped")
            case .active:
                title = String(localized: "Active")
            case .degraded:
                title = String(localized: "Needs Attention")
            }
        }
        return String(localized: "Dummy Ethernet: \(title)")
    }

    private var canPresentDummyEthernetNetworkStatus: Bool {
        dummyEthernetHelper.registrationStatus == .enabled
            && dummyEthernetHelper.operation == nil
    }

    private var currentPresentationMode: MenuBarPresentationMode {
        MenuBarPresentationMode(
            isDebugModeEnabled: store.appPreferences.isDebugModeEnabled,
            isWireGuardManualConfigurationModeEnabled:
                store.appPreferences.isWireGuardManualConfigurationModeEnabled
        )
    }

    private var currentConfigurationGuidanceTitles: [String] {
        var titles = [
            assetWorkflowCoordinator.hasConfiguredAssets
                ? nil : String(localized: "Configure VM Assets in Settings"),
        ].compactMap { $0 }

        guard !store.appPreferences.isWireGuardManualConfigurationModeEnabled else {
            return titles
        }

        titles.append(contentsOf: [
            store.wireGuardSession.systemExtensionStatus.isActive
                ? nil : String(localized: "Configure Network Extension in Settings"),
            dummyEthernetHelper.registrationStatus == .enabled
                ? nil : String(localized: "Configure Dummy Ethernet helper in Settings"),
        ].compactMap { $0 })
        return titles
    }

    private var currentCombinedStatus: MenuBarCombinedStatus {
        MenuBarCombinedStatus(
            vmRuntimeState: store.runtimeState,
            isUSBAttached: store.usbSession.attachedAccessoryID != nil,
            wireGuardTunnelStatus: store.appPreferences
                .isWireGuardManualConfigurationModeEnabled
                ? nil : store.wireGuardSession.tunnelStatus,
            hasWireGuardFailure: !store.appPreferences
                .isWireGuardManualConfigurationModeEnabled
                && store.wireGuardSession.tunnelFailure != nil
        )
    }

    private func combinedStatusColor(
        for combinedStatus: MenuBarCombinedStatus
    ) -> NSColor {
        switch combinedStatus.activity {
        case .inactive:
            return .systemRed
        case .partiallyActive:
            return .systemOrange
        case .active:
            return .systemGreen
        }
    }

    private var vmStatusColor: NSColor {
        switch store.vmDisplayState {
        case .running:
            return .systemGreen
        case .restarting:
            return .systemYellow
        case .stopped:
            return .systemRed
        }
    }

    private var usbStatusColor: NSColor {
        if store.usbSession.attachedAccessoryID != nil {
            return .systemGreen
        }
        return store.usbSession.accessories.isEmpty ? .systemRed : .systemYellow
    }

    private var wireGuardStatusColor: NSColor {
        if store.wireGuardSession.tunnelFailure != nil {
            return .systemRed
        }
        switch store.wireGuardSession.tunnelStatus {
        case .connected:
            return .systemGreen
        case .connecting, .disconnecting:
            return .systemYellow
        case .unconfigured, .disconnected:
            return .systemRed
        }
    }

    private var dummyEthernetStatusColor: NSColor {
        guard canPresentDummyEthernetNetworkStatus else {
            return .systemRed
        }

        if dummyEthernet.operation != nil {
            return .systemYellow
        }

        switch dummyEthernet.runtimeState {
        case nil:
            return .systemGray
        case .inactive:
            return .systemRed
        case .active:
            return .systemGreen
        case .degraded:
            return .systemOrange
        }
    }

    private func statusItemLine(
        title: String,
        dotColor: NSColor
    ) -> NSMenuItem {
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

    private func attachMenuItem() -> NSMenuItem {
        let attachUSBTitle = String(localized: "Attach USB")
        let parent = NSMenuItem(title: attachUSBTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: attachUSBTitle)
        submenu.autoenablesItems = false

        if store.usbSession.accessories.isEmpty {
            let emptyItem = NSMenuItem(
                title: String(localized: "No USB devices"),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for accessory in store.usbSession.accessories {
                let item = actionItem(
                    title: Self.shortDeviceTitle(accessory),
                    action: #selector(attachUSB(_:))
                )
                item.representedObject = NSNumber(value: accessory.id)
                item.state = accessory.id == store.usbSession.attachedAccessoryID ? .on : .off
                item.isEnabled = store.canChooseAccessoryForAttachment(accessory.id)
                submenu.addItem(item)
            }
        }

        parent.submenu = submenu
        return parent
    }

    private func actionItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func startOrRestartVM() {
        if store.runtimeState == .running {
            store.restartVirtualMachine()
        } else {
            store.startVirtualMachine()
        }
    }

    @objc private func stopVM() {
        store.stopVirtualMachine()
    }

    @objc private func connectWireGuard() {
        if !currentPresentationMode.isDebugModeEnabled {
            store.connectWireGuardTunnelWithAutomaticDummyEthernet()
        } else {
            store.connectWireGuardTunnel()
        }
    }

    @objc private func disconnectWireGuard() {
        store.disconnectWireGuardTunnel()
    }

    @objc private func startDummyEthernet() {
        dummyEthernet.start()
    }

    @objc private func restartDummyEthernet() {
        dummyEthernet.restart()
    }

    @objc private func stopDummyEthernet() {
        dummyEthernet.stop()
    }

    @objc private func attachUSB(_ sender: NSMenuItem) {
        guard let accessoryID = (sender.representedObject as? NSNumber)?.uint64Value else {
            return
        }
        store.requestAttachAccessory(id: accessoryID)
    }

    @objc private func detachUSB() {
        store.detachAccessory()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func shortDeviceTitle(_ accessory: USBAccessoryRecord) -> String {
        "\(accessory.usbIDText) ⋅ \(accessory.deviceName)"
    }

    private static func accessoryID(for item: NSMenuItem) -> UInt64? {
        (item.representedObject as? NSNumber)?.uint64Value
    }
}
