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

    @Published var suppressesADBWarnings: Bool {
        didSet {
            guard !isResettingPersistedValues else { return }
            defaults.set(suppressesADBWarnings, forKey: DefaultsKey.suppressesADBWarnings)
        }
    }

    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var usbAutoConnectIdentities:
        Set<USBAccessoryReconnectIdentity>
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
        self.suppressesADBWarnings = defaults.bool(forKey: DefaultsKey.suppressesADBWarnings)
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
        self.usbAutoConnectIdentities = Self.restoredUSBAutoConnectIdentities(
            defaults: defaults
        )
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

    func isUSBAutoConnectEnabled(
        for identity: USBAccessoryReconnectIdentity
    ) -> Bool {
        usbAutoConnectIdentities.contains(identity)
    }

    @discardableResult
    func setUSBAutoConnectEnabled(
        _ isEnabled: Bool,
        for identity: USBAccessoryReconnectIdentity
    ) -> Bool {
        var identities = usbAutoConnectIdentities
        if isEnabled {
            identities.insert(identity)
        } else {
            identities.remove(identity)
        }

        guard !identities.isEmpty else {
            defaults.removeObject(forKey: DefaultsKey.usbAutoConnectIdentities)
            usbAutoConnectIdentities = []
            return true
        }
        guard let data = try? JSONEncoder().encode(identities) else {
            return false
        }
        defaults.set(data, forKey: DefaultsKey.usbAutoConnectIdentities)
        usbAutoConnectIdentities = identities
        return true
    }

    // System registrations must be removed successfully by the reset workflow
    // before clearing local preferences.
    func resetPersistedValues() {
        defaults.removeObject(forKey: DefaultsKey.onboardingVersion)
        defaults.removeObject(forKey: DefaultsKey.isDebugModeEnabled)
        defaults.removeObject(forKey: DefaultsKey.shouldAskToAttachDetectedUSBDevices)
        defaults.removeObject(forKey: DefaultsKey.usbAutoConnectIdentities)
        for key in Self.obsoletePreferenceKeys {
            defaults.removeObject(forKey: key)
        }

        defaults.removeObject(forKey: DefaultsKey.suppressesADBWarnings)

        isResettingPersistedValues = true
        suppressesADBWarnings = false
        isDebugModeEnabled = false
        shouldAskToAttachDetectedUSBDevices = true
        usbAutoConnectIdentities = []
        hasCompletedOnboarding = false
        isResettingPersistedValues = false
    }

    // Removed UI inputs from 0.3. Helper ownership and migration records are
    // deliberately left to the services that validate their cleanup.
    private static let obsoletePreferenceKeys = [
        "DummyEthernet.hostIPv4Address",
        "DummyEthernet.memberInterfaceName",
        "DummyEthernet.peerInterfaceName",
    ]

    private enum DefaultsKey {
        static let onboardingVersion = "Onboarding.completedVersion"
        static let isDebugModeEnabled = "Application.debugModeEnabled"
        static let shouldAskToAttachDetectedUSBDevices = "USB.askToAttachDetectedDevices"
        static let usbAutoConnectIdentities = "USB.autoConnectIdentities.v1"
        static let suppressesADBWarnings = "USB.suppressesADBWarnings"
    }

    private static func restoredUSBAutoConnectIdentities(
        defaults: UserDefaults
    ) -> Set<USBAccessoryReconnectIdentity> {
        guard let data = defaults.data(
            forKey: DefaultsKey.usbAutoConnectIdentities
        ) else {
            return []
        }
        guard let identities = try? JSONDecoder().decode(
            Set<USBAccessoryReconnectIdentity>.self,
            from: data
        ) else {
            defaults.removeObject(forKey: DefaultsKey.usbAutoConnectIdentities)
            return []
        }
        return identities
    }
}
