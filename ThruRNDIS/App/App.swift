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
        tunnelController: HostWireGuardTunnelController(
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
    private var pendingTerminationApplication: NSApplication?
    private var pendingResetTerminationApplication: NSApplication?
    private var didPrepareForTermination = false
    private var storeTerminationTask: Task<Void, Never>?
    private var eventLogTerminationTask: Task<Void, Never>?
    private var resetAndRestartTask: Task<Void, Never>?
    private let applicationRelaunchService = ApplicationRelaunchService()
    private var isPreparedForResetRelaunchTermination = false
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
                guard self.pendingTerminationApplication == nil else {
                    self.finishPendingTerminationIfPossible()
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
        guard !isPreparedForResetRelaunchTermination else {
            return .terminateNow
        }

        if resetAndRestartTask != nil {
            guard pendingResetTerminationApplication == nil else {
                return .terminateLater
            }
            pendingResetTerminationApplication = sender
            eventLog.append(
                "Application termination will wait for the settings reset workflow.",
                level: .debug,
                category: .application
            )
            return .terminateLater
        }

        guard pendingTerminationApplication == nil else {
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

        pendingTerminationApplication = sender
        prepareForTerminationIfNeeded()
        finishPendingTerminationIfPossible()
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appPreferences.refreshLaunchAtLoginStatus()
        store.refreshWireGuardSystemExtensionStatus()
        store.dummyEthernet.refresh()
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
        let helper = store.dummyEthernet.helper
        helper.refresh()
        guard helper.registrationStatus == .updateRequired else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
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
        guard resetAndRestartTask == nil,
              pendingTerminationApplication == nil,
              pendingResetTerminationApplication == nil,
              !didPrepareForTermination else {
            return
        }

        resetAndRestartTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard await self.store.resetAppSettings() else {
                self.resetAndRestartTask = nil
                self.cancelPendingTerminationDuringReset()
                self.presentResetFailure()
                return
            }
            self.assetWorkflowCoordinator.clearSelection()

            do {
                try self.applicationRelaunchService.scheduleRelaunch(
                    applicationURL: Bundle.main.bundleURL
                )
            } catch {
                self.eventLog.append(
                    "App settings reset completed, but scheduling application relaunch failed: " +
                        EventLogErrorFormatter.description(for: error),
                    level: .error,
                    category: .application
                )
                self.resetAndRestartTask = nil
                self.cancelPendingTerminationDuringReset()
                self.presentRestartFailure(error)
                return
            }
            self.eventLog.append(
                "Scheduled application relaunch after settings reset.",
                level: .debug,
                category: .application
            )

            self.assetWorkflowCoordinator.prepareForApplicationTermination()
            await self.store.prepareForApplicationTermination(
                disconnectWireGuard: false
            )
            await self.eventLog.prepareForApplicationTermination()
            self.didPrepareForTermination = true
            self.isPreparedForResetRelaunchTermination = true
            self.resetAndRestartTask = nil
            if let application = self.pendingResetTerminationApplication {
                self.pendingResetTerminationApplication = nil
                application.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func cancelPendingTerminationDuringReset() {
        guard let application = pendingResetTerminationApplication else {
            return
        }
        pendingResetTerminationApplication = nil
        application.reply(toApplicationShouldTerminate: false)
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

    private func prepareForTerminationIfNeeded() {
        guard !didPrepareForTermination else {
            return
        }
        didPrepareForTermination = true
        eventLog.append(
            "Preparing application services for termination.",
            level: .debug,
            category: .application
        )
        assetWorkflowCoordinator.prepareForApplicationTermination()
        storeTerminationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.store.prepareForApplicationTermination()
            self.storeTerminationTask = nil
            self.finishPendingTerminationIfPossible()
        }
    }

    private func finishPendingTerminationIfPossible() {
        guard let application = pendingTerminationApplication,
              !assetWorkflowCoordinator.isBusy,
              storeTerminationTask == nil else {
            return
        }
        guard eventLogTerminationTask == nil else {
            return
        }

        eventLogTerminationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.eventLog.prepareForApplicationTermination()
            guard self.pendingTerminationApplication === application else {
                self.eventLogTerminationTask = nil
                return
            }
            self.eventLogTerminationTask = nil
            self.pendingTerminationApplication = nil
            application.reply(toApplicationShouldTerminate: true)
        }
    }
}
