/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Combine

private final class StatusDotView: NSView {
    private var dotColor: NSColor

    init(color: NSColor) {
        self.dotColor = color
        super.init(frame: .zero)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let color = dotColor.usingColorSpace(.deviceRGB) ?? dotColor
        let colors = [
            color.withAlphaComponent(0.64).cgColor,
            color.withAlphaComponent(0.28).cgColor,
            color.withAlphaComponent(0).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 0.5, 1]

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else {
            return
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: 9,
            options: []
        )
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - 4,
            y: center.y - 4,
            width: 8,
            height: 8
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(color: NSColor) {
        dotColor = color
        needsDisplay = true
    }
}

private final class StatusMenuItemView: NSView {
    private static let width: CGFloat = {
        let font = NSFont.menuFont(ofSize: 0)
        let referenceUSBID = "FFFF:FFFF"
        let referenceTitles = [
            String(localized: "USB: \(referenceUSBID)"),
            String(localized: "USB: Not attached"),
            String(localized: "WireGuard: Provider connected"),
            String(localized: "Configure VM Assets in Settings"),
        ]
        let titleWidth = referenceTitles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(titleWidth + 43)
    }()

    private let dotView: StatusDotView
    private let titleLabel: NSTextField

    init(title: String, dotColor: NSColor) {
        let font = NSFont.menuFont(ofSize: 0)
        self.dotView = StatusDotView(color: dotColor)
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.width,
            height: 22
        ))
        autoresizingMask = [.width]

        dotView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        addSubview(dotView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 18),
            dotView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, dotColor: NSColor) {
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
        }
        dotView.update(color: dotColor)
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
    private let assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var vmStatusItem: NSMenuItem?
    private var usbStatusItem: NSMenuItem?
    private var wireGuardStatusItem: NSMenuItem?
    private var vmActionItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var wireGuardItem: NSMenuItem?
    private var attachSubmenu: NSMenu?
    private var detachItem: NSMenuItem?
    private var menuHasConfiguredAssets: Bool?
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
        self.assetWorkflowCoordinator = assetWorkflowCoordinator
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        self.statusItem.menu = menu
        updateStatusButton()
        rebuildMenu()

        Publishers.Merge4(
            store.objectWillChange,
            store.usbSession.objectWillChange,
            store.wireGuardSession.objectWillChange,
            assetWorkflowCoordinator.objectWillChange
        )
        .sink { [weak self] in
            self?.schedulePresentationRefresh()
        }
        .store(in: &cancellables)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
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
        button.toolTip = String(
            localized: "ThruRNDIS — VM \(store.vmDisplayState.localizedName), \(usbStatusTitle), \(wireGuardStatusTitle)"
        )
    }

    private func rebuildMenu() {
        clearDynamicMenuReferences()
        menu.removeAllItems()
        let hasConfiguredAssets = assetWorkflowCoordinator.hasConfiguredAssets
        menuHasConfiguredAssets = hasConfiguredAssets

        guard hasConfiguredAssets else {
            menu.addItem(statusItemLine(
                title: String(localized: "Configure VM Assets in Settings"),
                systemImage: "exclamationmark.triangle"
            ))
            addSettingsAndQuitItems()
            return
        }

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

        let wireGuardStatusItem = statusItemLine(
            title: wireGuardStatusTitle,
            dotColor: wireGuardStatusColor
        )
        self.wireGuardStatusItem = wireGuardStatusItem
        menu.addItem(wireGuardStatusItem)

        menu.addItem(.separator())

        let vmActionItem = actionItem(title: "", action: #selector(startOrRestartVM))
        self.vmActionItem = vmActionItem
        menu.addItem(vmActionItem)

        let stopItem = actionItem(title: String(localized: "Stop VM"), action: #selector(stopVM))
        self.stopItem = stopItem
        menu.addItem(stopItem)

        let wireGuardItem = actionItem(title: "", action: #selector(connectWireGuard))
        self.wireGuardItem = wireGuardItem
        menu.addItem(wireGuardItem)

        menu.addItem(.separator())
        let attachMenuItem = attachMenuItem()
        attachSubmenu = attachMenuItem.submenu
        menu.addItem(attachMenuItem)

        let detachItem = actionItem(title: String(localized: "Detach USB"), action: #selector(detachUSB))
        self.detachItem = detachItem
        menu.addItem(detachItem)

        addSettingsAndQuitItems()
        refreshConfiguredMenuPresentation()
    }

    private func clearDynamicMenuReferences() {
        vmStatusItem = nil
        usbStatusItem = nil
        wireGuardStatusItem = nil
        vmActionItem = nil
        stopItem = nil
        wireGuardItem = nil
        attachSubmenu = nil
        detachItem = nil
    }

    private func refreshMenuPresentation() {
        updateStatusButton()

        let hasConfiguredAssets = assetWorkflowCoordinator.hasConfiguredAssets
        guard menuHasConfiguredAssets == hasConfiguredAssets else {
            if !isMenuOpen {
                rebuildMenu()
            }
            return
        }

        guard hasConfiguredAssets else {
            return
        }

        refreshConfiguredMenuPresentation()
    }

    private func refreshConfiguredMenuPresentation() {
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
            wireGuardItem?.isEnabled = true
        } else {
            wireGuardItem?.title = String(localized: "Connect WireGuard")
            wireGuardItem?.action = #selector(connectWireGuard)
            wireGuardItem?.isEnabled = store.canConnectHostWireGuardTunnel
        }

        refreshAttachSubmenu()
        detachItem?.isEnabled = store.canDetachAccessory
    }

    private func updateStatusItem(
        _ item: NSMenuItem?,
        title: String,
        dotColor: NSColor
    ) {
        item?.title = title
        (item?.view as? StatusMenuItemView)?.update(title: title, dotColor: dotColor)
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
        String(localized: "WireGuard: \(store.wireGuardSession.hostTunnelStatus.title)")
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
        switch store.wireGuardSession.hostTunnelStatus {
        case .connected:
            return .systemGreen
        case .activatingSystemExtension, .connecting, .disconnecting, .reasserting:
            return .systemYellow
        case .unconfigured, .disconnected, .failed:
            return .systemRed
        }
    }

    private func statusItemLine(title: String, dotColor: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = StatusMenuItemView(title: title, dotColor: dotColor)
        return item
    }

    private func statusItemLine(title: String, systemImage: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        item.image?.isTemplate = true
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
        store.connectHostWireGuardTunnel()
    }

    @objc private func disconnectWireGuard() {
        store.disconnectHostWireGuardTunnel()
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
