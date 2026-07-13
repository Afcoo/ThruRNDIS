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
    init(title: String, dotColor: NSColor) {
        let font = NSFont.menuFont(ofSize: 0)
        let titleSize = (title as NSString).size(withAttributes: [.font: font])
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: ceil(titleSize.width) + 43,
            height: 22
        ))

        let dotView = StatusDotView(color: dotColor)
        dotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor

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
    private let store: TetheringStore
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellable: AnyCancellable?
    private var isPresentingPrompt = false

    init(
        store: TetheringStore,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateStatusButton()
        rebuildMenu()

        cancellable = Publishers.CombineLatest4(
            store.$runtimeState,
            store.$isRestartingVirtualMachine,
            store.$attachedAccessoryID,
            store.$accessories
        )
        .map { runtimeState, isRestartingVirtualMachine, attachedAccessoryID, accessories in
            let attachedDescription = accessories
                .first(where: { $0.id == attachedAccessoryID })?
                .usbIDText ?? "none"
            return "\(runtimeState.rawValue)|\(isRestartingVirtualMachine)|\(attachedAccessoryID ?? 0)|\(attachedDescription)"
        }
        .removeDuplicates()
        .sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusButton()
            }
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
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        isPresentingPrompt = false
        completion(response == .alertFirstButtonReturn)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        let symbolName: String
        switch store.vmDisplayState {
        case .running:
            symbolName = store.attachedAccessoryID == nil ? "server.rack" : "cable.connector"
        case .restarting:
            symbolName = "arrow.trianglehead.2.clockwise.rotate.90"
        case .stopped:
            symbolName = "server.rack"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "ThruRNDIS status"
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = "ThruRNDIS — VM \(store.vmDisplayState.rawValue), \(usbStatusTitle)"
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if store.hasConfiguredVMAssets {
            menu.addItem(statusItemLine(
                title: "VM: \(store.vmDisplayState.rawValue)",
                dotColor: vmStatusColor
            ))
            menu.addItem(statusItemLine(
                title: usbStatusTitle,
                dotColor: usbStatusColor
            ))
        } else {
            menu.addItem(statusItemLine(
                title: "Set Up VM Assets First",
                systemImage: "exclamationmark.triangle"
            ))
        }

        menu.addItem(.separator())

        let vmActionItem: NSMenuItem
        if store.runtimeState == .running {
            vmActionItem = actionItem(title: "Restart VM", action: #selector(startOrRestartVM))
            vmActionItem.isEnabled = store.canRestartVirtualMachine
        } else {
            vmActionItem = actionItem(title: "Start VM", action: #selector(startOrRestartVM))
            vmActionItem.isEnabled = store.canStartVirtualMachine
        }
        menu.addItem(vmActionItem)

        let stopItem = actionItem(title: "Stop VM", action: #selector(stopVM))
        stopItem.isEnabled = store.canStopVirtualMachine
        menu.addItem(stopItem)

        menu.addItem(.separator())
        menu.addItem(attachMenuItem())

        let detachItem = actionItem(title: "Detach USB", action: #selector(detachUSB))
        detachItem.isEnabled = store.canDetachAccessory
        menu.addItem(detachItem)

        menu.addItem(.separator())

        let settingsItem = actionItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit ThruRNDIS", action: #selector(quit), keyEquivalent: "q"))
    }

    private var usbStatusTitle: String {
        guard let attachedAccessoryID = store.attachedAccessoryID else {
            return "USB: Not attached"
        }

        let usbID = store.accessories.first { $0.id == attachedAccessoryID }?.usbIDText
            ?? Self.registryIDText(attachedAccessoryID)
        return "USB: \(usbID)"
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
        if store.attachedAccessoryID != nil {
            return .systemGreen
        }
        return store.accessories.isEmpty ? .systemRed : .systemYellow
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
        let parent = NSMenuItem(title: "Attach USB", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Attach USB")
        submenu.autoenablesItems = false

        if store.accessories.isEmpty {
            let emptyItem = NSMenuItem(title: "No USB devices", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for accessory in store.accessories {
                let item = actionItem(
                    title: Self.shortDeviceTitle(accessory),
                    action: #selector(attachUSB(_:))
                )
                item.representedObject = NSNumber(value: accessory.id)
                item.state = accessory.id == store.attachedAccessoryID ? .on : .off
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
        "\(accessory.usbIDText) · \(accessory.registryIDText)"
    }

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }
}
