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
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var assetController = VMAssetController()
    lazy var store = TetheringStore(assetProvider: assetController)

    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var consoleWindowController: ConsoleWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingTerminationApplication: NSApplication?
    private var didPrepareForTermination = false
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

        assetController.onEvent = { [weak self] message in
            self?.store.recordVMAssetEvent(message)
        }

        menuBarController = MenuBarController(
            store: store,
            assetController: assetController,
            openSettings: { [weak self] in self?.showSettingsWindow() }
        )

        store.$usbAttachmentPrompt
            .compactMap { $0 }
            .sink { [weak self] prompt in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.store.usbAttachmentPrompt?.id == prompt.id else {
                        return
                    }

                    self.menuBarController?.present(prompt: prompt) { [weak self] accepted in
                        self?.store.resolveUSBAttachmentPrompt(accepted: accepted)
                    }
                }
            }
            .store(in: &cancellables)

        assetController.$installState
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

        if store.shouldPresentOnboardingOnLaunch || !assetController.hasConfiguredAssets {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWindow()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningUnderXCTest else {
            return .terminateNow
        }

        prepareStoreForTerminationIfNeeded()

        guard assetController.isBusy else {
            assetController.prepareForApplicationTermination()
            return .terminateNow
        }

        pendingTerminationApplication = sender
        assetController.prepareForApplicationTermination()
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
                assetController: assetController,
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
        guard store.resetAppSettings() else {
            return
        }
        assetController.clearSelection()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] application, error in
            DispatchQueue.main.async { [weak self] in
                guard application != nil, error == nil else {
                    self?.presentRestartFailure(error)
                    return
                }

                NSApp.terminate(nil)
            }
        }
    }

    private func presentRestartFailure(_ error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "ThruRNDIS Could Not Restart"
        alert.informativeText = error?.localizedDescription
            ?? "Settings were reset, but a new ThruRNDIS instance could not be opened."
        alert.addButton(withTitle: "OK")

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
                assetController: assetController,
                onFinish: { [weak self] in
                    self?.onboardingWindowController?.close()
                }
            )
        }

        onboardingWindowController?.show()
    }

    private func prepareStoreForTerminationIfNeeded() {
        guard !didPrepareForTermination else {
            return
        }
        didPrepareForTermination = true
        store.prepareForApplicationTermination()
    }

    private func finishPendingTerminationIfPossible() {
        guard let application = pendingTerminationApplication,
              !assetController.isBusy else {
            return
        }
        pendingTerminationApplication = nil
        application.reply(toApplicationShouldTerminate: true)
    }
}
