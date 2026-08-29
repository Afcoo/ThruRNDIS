/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

@MainActor
final class AppPreferencesStore: ObservableObject {
    static let currentOnboardingVersion = 5

    @Published var isDebugModeEnabled: Bool {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(
                isDebugModeEnabled,
                forKey: DefaultsKey.isDebugModeEnabled
            )
        }
    }

    @Published var shouldAskToAttachDetectedUSBDevices: Bool {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(
                shouldAskToAttachDetectedUSBDevices,
                forKey: DefaultsKey.shouldAskToAttachDetectedUSBDevices
            )
        }
    }

    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var launchAtLoginSnapshot: LaunchAtLoginSnapshot
    @Published private(set) var launchAtLoginStatusMessage = ""

    private let launchAtLoginService: LaunchAtLoginService
    private let defaults: UserDefaults
    private var isResettingPersistedValues = false

    init(
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        defaults: UserDefaults = .standard
    ) {
        self.launchAtLoginService = launchAtLoginService
        self.defaults = defaults
        self.isDebugModeEnabled = defaults.bool(
            forKey: DefaultsKey.isDebugModeEnabled
        )
        self.shouldAskToAttachDetectedUSBDevices = defaults.object(
            forKey: DefaultsKey.shouldAskToAttachDetectedUSBDevices
        ) == nil
            ? true
            : defaults.bool(forKey: DefaultsKey.shouldAskToAttachDetectedUSBDevices)
        self.hasCompletedOnboarding = defaults.integer(
            forKey: DefaultsKey.onboardingVersion
        ) >= Self.currentOnboardingVersion
        self.launchAtLoginSnapshot = launchAtLoginService.snapshot()
    }

    func completeOnboarding() {
        defaults.set(
            Self.currentOnboardingVersion,
            forKey: DefaultsKey.onboardingVersion
        )
        hasCompletedOnboarding = true
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) throws {
        do {
            launchAtLoginSnapshot = try launchAtLoginService.setEnabled(isEnabled)
            launchAtLoginStatusMessage = launchAtLoginSnapshot.statusText
        } catch {
            launchAtLoginSnapshot = launchAtLoginService.snapshot()
            launchAtLoginStatusMessage = String(
                localized: "Could not update Launch at Login: \(error.localizedDescription)"
            )
            throw error
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginSnapshot = launchAtLoginService.snapshot()
        launchAtLoginStatusMessage = ""
    }

    func resetPersistedValues() throws {
        defaults.removeObject(forKey: DefaultsKey.onboardingVersion)
        defaults.removeObject(forKey: DefaultsKey.isDebugModeEnabled)
        defaults.removeObject(forKey: DefaultsKey.shouldAskToAttachDetectedUSBDevices)

        isResettingPersistedValues = true
        isDebugModeEnabled = false
        shouldAskToAttachDetectedUSBDevices = true
        hasCompletedOnboarding = false
        isResettingPersistedValues = false

        do {
            launchAtLoginSnapshot = try launchAtLoginService.setEnabled(false)
            launchAtLoginStatusMessage = launchAtLoginSnapshot.statusText
        } catch {
            launchAtLoginSnapshot = launchAtLoginService.snapshot()
            launchAtLoginStatusMessage = String(
                localized: "Could not update Launch at Login: \(error.localizedDescription)"
            )
            throw error
        }
    }

    private enum DefaultsKey {
        static let onboardingVersion = "Onboarding.completedVersion"
        static let isDebugModeEnabled = "Application.debugModeEnabled"
        static let shouldAskToAttachDetectedUSBDevices = "USB.askToAttachDetectedDevices"
    }
}
