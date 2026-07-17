/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Combine

private enum AppExecutionEnvironment {
    static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

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
    lazy var eventLog = EventLogStore()
    lazy var store = TetheringStore(
        assetProvider: assetWorkflowCoordinator,
        vmCoordinator: VMCoordinator(),
        usbCoordinator: USBAccessoryCoordinator(monitor: USBAccessoryMonitor()),
        wireGuardConfStore: WireGuardConfStore(),
        wireGuardConfBuilder: WireGuardConfBuilder(elements: .defaults),
        eventLog: eventLog,
        consoleSession: ConsoleSessionStore(),
        usbSession: USBSessionStore(),
        vmConfiguration: VMConfigurationStore(),
        hostWireGuardTunnelController: HostWireGuardTunnelController(
            systemExtensionActivator: WireGuardSystemExtensionActivator()
        )
    )

    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var consoleWindowController: ConsoleWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingTerminationApplication: NSApplication?
    private var didPrepareForTermination = false
    private var storeTerminationTask: Task<Void, Never>?
    private var resetAndRestartTask: Task<Void, Never>?
    private let isRunningUnderXCTest: Bool

    override init() {
        self.isRunningUnderXCTest = AppExecutionEnvironment.isRunningUnderXCTest
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnderXCTest else {
            return
        }

        NSApp.setActivationPolicy(.accessory)

        assetWorkflowCoordinator.onEventLog = { [weak self] message in
            self?.eventLog.append(message, source: .vmAssets)
        }
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
                        self?.store.resolveUSBAttachmentPrompt(accepted: accepted)
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

        if store.shouldPresentOnboardingOnLaunch || !assetWorkflowCoordinator.hasConfiguredAssets {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWindow()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningUnderXCTest else {
            return .terminateNow
        }

        pendingTerminationApplication = sender
        prepareForTerminationIfNeeded()
        finishPendingTerminationIfPossible()
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isRunningUnderXCTest else {
            return
        }
        store.refreshLaunchAtLoginStatus()
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

    private func resetAppSettingsAndRestart() {
        guard resetAndRestartTask == nil else {
            return
        }

        resetAndRestartTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard await self.store.resetAppSettings() else {
                self.resetAndRestartTask = nil
                self.presentResetFailure()
                return
            }
            self.assetWorkflowCoordinator.clearSelection()

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true

            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration
            ) { [weak self] application, error in
                DispatchQueue.main.async { [weak self] in
                    self?.resetAndRestartTask = nil
                    guard application != nil, error == nil else {
                        self?.presentRestartFailure(error)
                        return
                    }

                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func presentResetFailure() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "ThruRNDIS Could Not Reset Settings")
        alert.informativeText = store.preferencesStatusMessage
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
            onboardingWindowController?.close()
            onboardingWindowController = OnboardingWindowController(
                store: store,
                assetWorkflowCoordinator: assetWorkflowCoordinator,
                onFinish: { [weak self] in
                    self?.onboardingWindowController?.close()
                }
            )
        }

        onboardingWindowController?.show()
    }

    private func prepareForTerminationIfNeeded() {
        guard !didPrepareForTermination else {
            return
        }
        didPrepareForTermination = true
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
        pendingTerminationApplication = nil
        application.reply(toApplicationShouldTerminate: true)
    }
}
