/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Combine

private final class StatusDotView: NSView {
    private let dotColor: NSColor

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

    init(title: String, dotColor: NSColor) {
        let font = NSFont.menuFont(ofSize: 0)
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.width,
            height: 22
        ))
        autoresizingMask = [.width]

        let dotView = StatusDotView(color: dotColor)
        dotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
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
    private var cancellable: AnyCancellable?
    private var assetCancellable: AnyCancellable?
    private var wireGuardCancellable: AnyCancellable?
    private var isPresentingPrompt = false

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
        statusItem.menu = menu
        updateStatusButton()
        rebuildMenu()

        cancellable = Publishers.CombineLatest3(
            store.$runtimeState,
            store.$isRestartingVirtualMachine,
            store.usbSession.$snapshot
        )
        .map { runtimeState, isRestartingVirtualMachine, usbSnapshot in
            let attachedDescription = usbSnapshot.accessories
                .first(where: { $0.id == usbSnapshot.attachedAccessoryID })?
                .deviceName ?? "none"
            return "\(runtimeState.rawValue)|\(isRestartingVirtualMachine)|\(usbSnapshot.attachedAccessoryID ?? 0)|\(attachedDescription)"
        }
        .removeDuplicates()
        .sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusButton()
            }
        }

        assetCancellable = Publishers.CombineLatest(
            assetWorkflowCoordinator.$currentSelection,
            assetWorkflowCoordinator.$installState
        )
        .sink { [weak self] _ in
            self?.updateStatusButton()
        }

        wireGuardCancellable = store.$hostWireGuardTunnelStatus
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
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
        alert.alertStyle = isReplacementPrompt(prompt) ? .warning : .informational
        alert.addButton(withTitle: prompt.primaryButtonTitle)
        alert.addButton(withTitle: String(localized: "Not Now"))

        let response = alert.runModal()
        isPresentingPrompt = false
        completion(response == .alertFirstButtonReturn)
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
        menu.removeAllItems()

        guard assetWorkflowCoordinator.hasConfiguredAssets else {
            menu.addItem(statusItemLine(
                title: String(localized: "Configure VM Assets in Settings"),
                systemImage: "exclamationmark.triangle"
            ))
            addSettingsAndQuitItems()
            return
        }

        menu.addItem(statusItemLine(
            title: String(localized: "VM: \(store.vmDisplayState.localizedName)"),
            dotColor: vmStatusColor
        ))
        menu.addItem(statusItemLine(
            title: usbStatusTitle,
            dotColor: usbStatusColor
        ))
        menu.addItem(statusItemLine(
            title: wireGuardStatusTitle,
            dotColor: wireGuardStatusColor
        ))

        menu.addItem(.separator())

        let vmActionItem: NSMenuItem
        if store.runtimeState == .running {
            vmActionItem = actionItem(
                title: String(localized: "Restart VM"),
                action: #selector(startOrRestartVM)
            )
            vmActionItem.isEnabled = store.canRestartVirtualMachine
        } else {
            vmActionItem = actionItem(
                title: String(localized: "Start VM"),
                action: #selector(startOrRestartVM)
            )
            vmActionItem.isEnabled = store.canStartVirtualMachine
        }
        menu.addItem(vmActionItem)

        let stopItem = actionItem(title: String(localized: "Stop VM"), action: #selector(stopVM))
        stopItem.isEnabled = store.canStopVirtualMachine
        menu.addItem(stopItem)

        let wireGuardItem: NSMenuItem
        if store.canDisconnectHostWireGuardTunnel {
            wireGuardItem = actionItem(
                title: String(localized: "Disconnect WireGuard"),
                action: #selector(disconnectWireGuard)
            )
            wireGuardItem.isEnabled = store.canDisconnectHostWireGuardTunnel
        } else {
            wireGuardItem = actionItem(
                title: String(localized: "Connect WireGuard"),
                action: #selector(connectWireGuard)
            )
            wireGuardItem.isEnabled = store.canConnectHostWireGuardTunnel
        }
        menu.addItem(wireGuardItem)

        menu.addItem(.separator())
        menu.addItem(attachMenuItem())

        let detachItem = actionItem(title: String(localized: "Detach USB"), action: #selector(detachUSB))
        detachItem.isEnabled = store.canDetachAccessory
        menu.addItem(detachItem)

        addSettingsAndQuitItems()
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
        String(localized: "WireGuard: \(store.hostWireGuardTunnelStatus.title)")
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
        switch store.hostWireGuardTunnelStatus {
        case .connected:
            return .systemGreen
        case .activatingSystemExtension, .connecting, .disconnecting, .reasserting:
            return .systemYellow
        case .unconfigured, .disconnected, .failed:
            return .systemRed
        }
    }

    private func statusItemLine(title: String, dotColor: NSColor) -> NSMenuItem {
        let item = NSMenuItem()
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

    private func isReplacementPrompt(_ prompt: USBAttachmentPrompt) -> Bool {
        if case .replace = prompt.kind {
            return true
        }
        return false
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
}
