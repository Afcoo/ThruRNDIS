/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Combine

@main
enum App {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()

        application.delegate = appDelegate
        application.mainMenu = makeMainMenu(for: application)
        application.run()
    }

    private static func makeMainMenu(for application: NSApplication) -> NSMenu {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem(
            title: "ThruRNDIS",
            action: nil,
            keyEquivalent: ""
        )
        let applicationMenu = NSMenu(title: "ThruRNDIS")
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let quitItem = NSMenuItem(
            title: String(localized: "Quit ThruRNDIS"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = application
        applicationMenu.addItem(quitItem)

        let fileTitle = String(localized: "File")
        let fileMenuItem = NSMenuItem(
            title: fileTitle,
            action: nil,
            keyEquivalent: ""
        )
        let fileMenu = NSMenu(title: fileTitle)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let closeWindowItem = NSMenuItem(
            title: String(localized: "Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeWindowItem.keyEquivalentModifierMask = [.command]
        closeWindowItem.target = nil
        fileMenu.addItem(closeWindowItem)

        return mainMenu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var assetWorkflowCoordinator = VMAssetWorkflowCoordinator()
    lazy var eventLog = EventLogStore(
        filePersistence: EventLogFileStore()
    )
    lazy var consoleSession = ConsoleSessionStore()
    lazy var usbSession = USBSessionStore()
    lazy var vmConfiguration = VMConfigurationStore()
    lazy var wireGuardSession = WireGuardSessionStore(
        configurationStore: WireGuardConfigurationStore(),
        configurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
        tunnelController: WireGuardTunnelController(
            systemExtensionActivator: WireGuardSystemExtensionActivator()
        ),
        eventLog: eventLog
    )
    lazy var appPreferences = AppPreferencesStore()
    lazy var store: TetheringStore = {
        let dummyEthernet = DummyEthernetStore(eventLog: eventLog)
        return TetheringStore(
            assetProvider: assetWorkflowCoordinator,
            vmCoordinator: VMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(
                monitor: USBAccessoryMonitor()
            ),
            eventLog: eventLog,
            consoleSession: consoleSession,
            usbSession: usbSession,
            vmConfiguration: vmConfiguration,
            wireGuardSession: wireGuardSession,
            appPreferences: appPreferences,
            dummyEthernet: dummyEthernet
        )
    }()

    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var consoleWindowController: ConsoleWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var onboardingPresentationID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var isTerminating = false
    private var isRelaunching = false
    private let applicationRelaunchService = ApplicationRelaunchService()
    private var isPreparedForRelaunchTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        assetWorkflowCoordinator.onEventLog = { [weak self] message, level in
            self?.eventLog.append(message, level: level, category: .vmAsset)
        }
        eventLog.append(
            "Application finished launching.",
            level: .debug,
            category: .application
        )
        assetWorkflowCoordinator.reportCurrentStateToEventLog()

        menuBarController = MenuBarController(
            store: store,
            assetWorkflowCoordinator: assetWorkflowCoordinator,
            openSettings: { [weak self] in self?.showSettingsWindow() }
        )

        store.usbSession.$attachmentPrompt
            .compactMap { $0 }
            .sink { [weak self] prompt in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.store.usbSession.attachmentPrompt?.id == prompt.id else {
                        return
                    }

                    self.menuBarController?.present(prompt: prompt) { [weak self] accepted in
                        guard let self else {
                            return
                        }

                        self.store.resolveUSBAttachmentPrompt(accepted: accepted)
                        if accepted, case .assetsRequired = prompt.kind {
                            self.showSettingsWindow()
                        }
                    }
                }
            }
            .store(in: &cancellables)

        store.wireGuardSession.$wireGuardConnectionPrompt
            .sink { [weak self] prompt in
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    guard let prompt else {
                        guard self.store.wireGuardConnectionPrompt == nil else {
                            return
                        }
                        self.menuBarController?.dismissWireGuardConnectionPrompt()
                        return
                    }

                    guard self.store.wireGuardConnectionPrompt?.id == prompt.id else {
                        return
                    }
                    self.menuBarController?.present(prompt: prompt) {
                        [weak self] accepted, shouldAutomaticallyConnectNextTime in
                        self?.store.resolveWireGuardConnectionPrompt(
                            id: prompt.id,
                            accepted: accepted,
                            shouldAutomaticallyConnectNextTime: shouldAutomaticallyConnectNextTime
                        )
                    }
                }
            }
            .store(in: &cancellables)

        assetWorkflowCoordinator.$installState
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                guard !self.isTerminating else {
                    return
                }
                self.store.assetAvailabilityDidChange()
            }
            .store(in: &cancellables)

        store.$onboardingPresentationRequest
            .dropFirst()
            .sink { [weak self] request in
                DispatchQueue.main.async { [weak self] in
                    self?.showOnboardingWindow(restart: request.restart)
                }
            }
            .store(in: &cancellables)

        store.startAccessoryMonitoringOnLaunch()
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.presentDummyEthernetHelperUpdateIfNeeded()
            if self.store.shouldPresentOnboardingOnLaunch
                || !self.assetWorkflowCoordinator.hasConfiguredAssets {
                self.showOnboardingWindow()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparedForRelaunchTermination else {
            return .terminateNow
        }

        if isRelaunching {
            guard !isTerminating else {
                return .terminateLater
            }
            isTerminating = true
            eventLog.append(
                "Application termination will wait for the relaunch workflow.",
                level: .debug,
                category: .application
            )
            return .terminateLater
        }

        guard !isTerminating else {
            return .terminateLater
        }

        guard confirmApplicationTerminationIfNeeded() else {
            eventLog.append(
                "Application termination cancelled by the user.",
                level: .debug,
                category: .application
            )
            return .terminateCancel
        }

        isTerminating = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareApplicationServicesForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appPreferences.refreshLaunchAtLoginStatus()
        store.refreshWireGuardSystemExtensionStatus()
        if !appPreferences.isWireGuardManualConfigurationModeEnabled {
            store.dummyEthernet.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: store,
                assetWorkflowCoordinator: assetWorkflowCoordinator,
                openConsole: { [weak self] in
                    self?.showConsoleWindow()
                },
                resetAndRestart: { [weak self] in
                    self?.resetAppSettingsAndRestart()
                },
                restartWithWireGuardManualConfigurationMode: {
                    [weak self] isEnabled in
                    self?.confirmWireGuardManualConfigurationModeChange(
                        isEnabled
                    )
                }
            )
        }

        settingsWindowController?.show()
    }

    @objc func showConsoleWindow() {
        if consoleWindowController == nil {
            consoleWindowController = ConsoleWindowController(store: store)
        }

        consoleWindowController?.show()
    }

    private func presentDummyEthernetHelperUpdateIfNeeded() {
        guard !appPreferences.isWireGuardManualConfigurationModeEnabled else {
            return
        }
        let helper = store.dummyEthernet.helper
        helper.refresh()
        guard helper.registrationStatus == .updateRequired else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Dummy Ethernet Helper Update Required"
        )
        alert.informativeText = String(
            localized: "The Dummy Ethernet helper must be updated to use ThruRNDIS.\nYou can update it manually later in Settings."
        )
        alert.addButton(withTitle: String(localized: "Update"))
        alert.addButton(withTitle: String(localized: "Not Now"))

        RunLoop.main.perform(inModes: [.modalPanel]) {
            NSApp.activate(ignoringOtherApps: true)
        }
        guard alert.runModal() == .alertFirstButtonReturn else {
            eventLog.append(
                "Dummy Ethernet helper update deferred at app launch.",
                level: .debug,
                category: .application
            )
            return
        }

        store.dummyEthernet.reinstallHelper()
    }

    private func resetAppSettingsAndRestart() {
        relaunchApplication(
            reason: "app settings reset",
            prepare: { [weak self] in
                guard let self else {
                    return false
                }
                guard await self.store.resetAppSettings() else {
                    return false
                }
                self.assetWorkflowCoordinator.clearSelection()
                return true
            },
            onPreparationFailure: { [weak self] in
                self?.presentResetFailure()
            }
        )
    }

    private func relaunchApplication(
        reason: String,
        prepare: @escaping @MainActor () async -> Bool = { true },
        onPreparationFailure: @escaping @MainActor () -> Void = {},
        afterTerminationPreparation: @escaping @MainActor () -> Void = {}
    ) {
        guard !isRelaunching,
              !isTerminating else {
            return
        }

        isRelaunching = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard await prepare() else {
                self.finishFailedRelaunch()
                onPreparationFailure()
                return
            }

            do {
                try self.applicationRelaunchService.scheduleRelaunch(
                    applicationURL: Bundle.main.bundleURL
                )
            } catch {
                self.eventLog.append(
                    "Could not schedule application relaunch after \(reason): " +
                        EventLogErrorFormatter.description(for: error),
                    level: .error,
                    category: .application
                )
                self.finishFailedRelaunch()
                self.presentRestartFailure(error)
                return
            }
            self.eventLog.append(
                "Scheduled application relaunch after \(reason).",
                level: .debug,
                category: .application
            )

            await self.prepareApplicationServicesForTermination()
            afterTerminationPreparation()
            self.isPreparedForRelaunchTermination = true
            self.isRelaunching = false
            if self.isTerminating {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func confirmWireGuardManualConfigurationModeChange(
        _ isEnabled: Bool
    ) {
        guard appPreferences.isWireGuardManualConfigurationModeEnabled
                != isEnabled,
              !isRelaunching,
              !isTerminating else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "ThruRNDIS Will Restart")
        alert.informativeText = String(
            localized: "Manual Configuration Mode will change after ThruRNDIS restarts."
        )
        alert.addButton(withTitle: String(localized: "Restart"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        relaunchApplication(
            reason: "WireGuard manual configuration mode change",
            afterTerminationPreparation: { [weak self] in
                self?.appPreferences
                    .setWireGuardManualConfigurationModeEnabledForNextLaunch(
                        isEnabled
                    )
            }
        )
    }

    private func finishFailedRelaunch() {
        isRelaunching = false
        guard isTerminating else { return }
        isTerminating = false
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    private func presentResetFailure(_ message: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "ThruRNDIS Could Not Reset Settings")
        alert.informativeText = message ?? store.resetStatusMessage
        alert.addButton(withTitle: String(localized: "OK"))

        if let window = settingsWindowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentRestartFailure(_ error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "ThruRNDIS Could Not Restart")
        alert.informativeText = error?.localizedDescription
            ?? String(localized: "Settings were reset, but a new ThruRNDIS instance could not be opened.")
        alert.addButton(withTitle: String(localized: "OK"))

        if let window = settingsWindowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showOnboardingWindow(restart: Bool = false) {
        if restart || onboardingWindowController?.window?.isVisible != true {
            let presentationID = UUID()
            onboardingPresentationID = presentationID
            onboardingWindowController?.close()
            onboardingWindowController = OnboardingWindowController(
                store: store,
                assetWorkflowCoordinator: assetWorkflowCoordinator,
                onFinish: { [weak self] in
                    self?.closeOnboardingWindow(presentationID: presentationID)
                },
                onClose: { [weak self] in
                    self?.onboardingWindowDidClose(presentationID: presentationID)
                }
            )
        }

        store.onboardingPresentationDidBegin()
        onboardingWindowController?.show()
    }

    private func closeOnboardingWindow(presentationID: UUID) {
        guard onboardingPresentationID == presentationID else {
            return
        }
        onboardingWindowController?.close()
    }

    private func onboardingWindowDidClose(presentationID: UUID) {
        guard onboardingPresentationID == presentationID else {
            return
        }
        onboardingPresentationID = nil
        onboardingWindowController = nil
        store.onboardingPresentationDidEnd()
    }

    private func confirmApplicationTerminationIfNeeded() -> Bool {
        guard store.shouldConfirmApplicationTermination else {
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "USB and WireGuard will disconnect. Quit anyway?"
        )
        alert.addButton(withTitle: String(localized: "Quit ThruRNDIS"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func prepareApplicationServicesForTermination() async {
        eventLog.append(
            "Preparing application services for termination.",
            level: .debug,
            category: .application
        )
        async let assetTermination: Void = assetWorkflowCoordinator
            .prepareForApplicationTermination()
        await store.prepareForApplicationTermination()
        await assetTermination
        await eventLog.prepareForApplicationTermination()
    }
}
