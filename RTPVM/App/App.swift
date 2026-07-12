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
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TetheringStore()

    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var consoleWindowController: ConsoleWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menuBarController = MenuBarController(
            store: store,
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

        store.$onboardingPresentationRequest
            .dropFirst()
            .sink { [weak self] request in
                DispatchQueue.main.async { [weak self] in
                    self?.showOnboardingWindow(restart: request.restart)
                }
            }
            .store(in: &cancellables)

        store.startAccessoryMonitoringOnLaunch()

        if store.shouldPresentOnboardingOnLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWindow()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.prepareForApplicationTermination()
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.refreshLaunchAtLoginStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: store,
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
        alert.messageText = "RTPVM Could Not Restart"
        alert.informativeText = error?.localizedDescription
            ?? "Settings were reset, but a new RTPVM instance could not be opened."
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
                onFinish: { [weak self] in
                    self?.onboardingWindowController?.close()
                }
            )
        }

        onboardingWindowController?.show()
    }
}
