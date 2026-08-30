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
    // Reserve the final second of the ten-second termination budget for logs.
    private static let terminationCleanupTimeout = Duration.seconds(9)
    private static let terminationLogFlushTimeout = Duration.seconds(1)

    lazy var assetWorkflowCoordinator = VMAssetWorkflowCoordinator()
    lazy var eventLog = EventLogStore(
        filePersistence: EventLogFileStore()
    )
    lazy var consoleSession = ConsoleSessionStore()
    lazy var usbSession = USBSessionStore()
    lazy var vmConfiguration = VMConfigurationStore()
    lazy var appPreferences = AppPreferencesStore()
    lazy var networkRoute = NetworkRouteStore(eventLog: eventLog)
    lazy var portForwarding = PortForwardingStore(eventLog: eventLog)
    lazy var store: TetheringStore = {
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
            appPreferences: appPreferences,
            networkRoute: networkRoute,
            portForwarding: portForwarding
        )
    }()

    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var consoleWindowController: ConsoleWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var onboardingPresentationID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var isTerminating = false
    private var isQuittingAfterSettingsChange = false
    private var isPreparedToQuitAfterSettingsChange = false
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
            .sink { [weak self] prompt in
                guard let prompt else {
                    self?.menuBarController?.dismissPresentedPrompt()
                    return
                }
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

        startServicesAfterLegacyNetworkHelperMigration { [self] in // Remove this wrapper after legacy migration support ends.
            updateNetworkHelperIfNeeded()
            networkRoute.refresh()
            store.startAccessoryMonitoringOnLaunch()
        } // Remove this wrapper after legacy migration support ends.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            if self.store.shouldPresentOnboardingOnLaunch
                || !self.assetWorkflowCoordinator.hasConfiguredAssets {
                self.showOnboardingWindow()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparedToQuitAfterSettingsChange else {
            return .terminateNow
        }

        if isQuittingAfterSettingsChange {
            guard !isTerminating else {
                return .terminateLater
            }
            isTerminating = true
            eventLog.append(
                "Application termination will wait for the settings change workflow.",
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
        store.networkRoute.refresh()
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
                resetAndQuit: { [weak self] in
                    self?.resetAppSettingsAndQuit()
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

    private func updateNetworkHelperIfNeeded() {
        let helper = store.networkRoute.helper
        helper.refresh()
        guard helper.needsAutomaticUpdate else {
            return
        }

        eventLog.append(
            "Automatically updating the Network Helper for the current app build.",
            level: .info,
            category: .application
        )
        helper.reinstall()
    }

    private func resetAppSettingsAndQuit() {
        quitApplication(
            reason: "app settings reset",
            prepare: { [weak self] in
                guard let self else { return }
                guard await self.store.resetAppSettings() else {
                    self.eventLog.append(
                        "Application termination will continue after the app settings reset failed.",
                        level: .error,
                        category: .application
                    )
                    return
                }
                self.assetWorkflowCoordinator.clearSelection()
            }
        )
    }

    private func quitApplication(
        reason: String,
        prepare: @escaping @MainActor () async -> Void = {},
        afterTerminationPreparation: @escaping @MainActor () -> Void = {}
    ) {
        guard !isQuittingAfterSettingsChange,
              !isTerminating else {
            return
        }

        isQuittingAfterSettingsChange = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.eventLog.append(
                "Application will quit after \(reason).",
                level: .debug,
                category: .application
            )

            await self.prepareApplicationServicesForTermination(
                prepare: prepare
            )
            afterTerminationPreparation()
            self.isPreparedToQuitAfterSettingsChange = true
            self.isQuittingAfterSettingsChange = false
            if self.isTerminating {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.terminate(nil)
            }
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
                onUserCloseRequest: {
                    NSApp.terminate(nil)
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
            localized: "USB will disconnect and Network Routing will stop. Quit anyway?"
        )
        alert.addButton(withTitle: String(localized: "Quit ThruRNDIS"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func prepareApplicationServicesForTermination(
        prepare: @escaping @MainActor () async -> Void = {}
    ) async {
        eventLog.append(
            "Preparing application services for termination.",
            level: .debug,
            category: .application
        )

        let didFinishCleanup = await performTerminationOperation(
            timeout: Self.terminationCleanupTimeout
        ) { [weak self] in
            guard let self else {
                return
            }
            await prepare()
            async let assetTermination: Void = assetWorkflowCoordinator
                .prepareForApplicationTermination()
            await store.prepareForApplicationTermination()
            await assetTermination
            await eventLog.prepareForApplicationTermination()
        }

        guard !didFinishCleanup else { return }

        eventLog.append(
            "Application termination cleanup timed out; termination will continue.",
            level: .error,
            category: .application
        )
        _ = await performTerminationOperation(
            timeout: Self.terminationLogFlushTimeout
        ) { [weak self] in
            await self?.eventLog.flushFilePersistence()
        }
    }

    private func performTerminationOperation(
        timeout: Duration,
        operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let (results, resultContinuation) = AsyncStream<Bool>.makeStream()
        let operationTask = Task { @MainActor in
            await operation()
            resultContinuation.yield(true)
        }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            resultContinuation.yield(false)
        }
        var iterator = results.makeAsyncIterator()
        let didFinishOperation = await iterator.next() ?? false
        resultContinuation.finish()
        timeoutTask.cancel()
        if !didFinishOperation {
            operationTask.cancel()
        }
        return didFinishOperation
    }
}

// MARK: - Legacy Network Helper Migration

private extension AppDelegate { // Remove this extension after legacy migration support ends.
    func startServicesAfterLegacyNetworkHelperMigration(
        _ startServices: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let migration = LegacyNetworkRouteHelperMigrationService()
            do {
                if try await migration.migrateIfNeeded() {
                    eventLog.append(
                        "Migrated the legacy Network Helper registration.",
                        level: .info,
                        category: .application
                    )
                }
                startServices()
            } catch {
                eventLog.append(
                    "Could not migrate the legacy Network Helper registration: \(error.localizedDescription)",
                    level: .error,
                    category: .application
                )
                networkRoute.refresh()
            }
        }
    }
}
