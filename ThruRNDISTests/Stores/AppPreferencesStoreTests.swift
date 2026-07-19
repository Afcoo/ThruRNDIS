/*
Copyright (C) 2026 Afcoo.
*/

import XCTest
@testable import ThruRNDIS

@MainActor
final class AppPreferencesStoreTests: XCTestCase {
    func testPreferencesUseDefaultsAndPersistChanges() throws {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let launchAtLoginService = AppPreferencesTestLaunchAtLoginService()

        let store = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )

        XCTAssertTrue(store.shouldAskToAttachDetectedUSBDevices)
        XCTAssertFalse(store.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches)

        store.shouldAskToAttachDetectedUSBDevices = false
        store.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches = true

        let restoredStore = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        XCTAssertFalse(restoredStore.shouldAskToAttachDetectedUSBDevices)
        XCTAssertTrue(restoredStore.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches)
    }

    func testOnboardingRestoresCurrentOrNewerVersionAndCompletesAtCurrentVersion() throws {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let launchAtLoginService = AppPreferencesTestLaunchAtLoginService()
        defaults.set(2, forKey: "Onboarding.completedVersion")

        let store = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        XCTAssertFalse(store.hasCompletedOnboarding)

        store.completeOnboarding()

        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertEqual(
            defaults.integer(forKey: "Onboarding.completedVersion"),
            AppPreferencesStore.currentOnboardingVersion
        )

        defaults.set(4, forKey: "Onboarding.completedVersion")
        let restoredStore = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        XCTAssertTrue(restoredStore.hasCompletedOnboarding)
    }

    func testLaunchAtLoginCanBeSetAndRefreshed() throws {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let launchAtLoginService = AppPreferencesTestLaunchAtLoginService()
        let store = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )

        try store.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(launchAtLoginService.setEnabledValues, [true])
        XCTAssertTrue(store.launchAtLoginSnapshot.isEnabled)
        XCTAssertEqual(store.launchAtLoginStatusMessage, "enabled")

        launchAtLoginService.currentSnapshot = LaunchAtLoginSnapshot(
            isEnabled: false,
            requiresApproval: true,
            statusText: "approval required"
        )
        store.refreshLaunchAtLoginStatus()

        XCTAssertFalse(store.launchAtLoginSnapshot.isEnabled)
        XCTAssertTrue(store.launchAtLoginSnapshot.requiresApproval)
        XCTAssertEqual(store.launchAtLoginStatusMessage, "")
    }

    func testResetClearsPreferencesAndDisablesLaunchAtLogin() throws {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let launchAtLoginService = AppPreferencesTestLaunchAtLoginService()
        let store = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        store.shouldAskToAttachDetectedUSBDevices = false
        store.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches = true
        store.completeOnboarding()

        try store.resetPersistedValues()

        XCTAssertTrue(store.shouldAskToAttachDetectedUSBDevices)
        XCTAssertFalse(store.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches)
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertEqual(launchAtLoginService.setEnabledValues, [false])
        XCTAssertNil(defaults.object(forKey: "Onboarding.completedVersion"))
        XCTAssertNil(defaults.object(forKey: "USB.askToAttachDetectedDevices"))
        XCTAssertNil(
            defaults.object(
                forKey: "WireGuard.connectAutomaticallyWhenUSBDeviceAttaches"
            )
        )
    }

    func testResetKeepsLocalDefaultsClearedWhenLaunchAtLoginFails() throws {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let launchAtLoginService = AppPreferencesTestLaunchAtLoginService()
        let store = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        store.shouldAskToAttachDetectedUSBDevices = false
        store.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches = true
        store.completeOnboarding()
        launchAtLoginService.setEnabledError = AppPreferencesTestError.rejected

        XCTAssertThrowsError(try store.resetPersistedValues()) { error in
            XCTAssertEqual(error as? AppPreferencesTestError, .rejected)
        }

        XCTAssertTrue(store.shouldAskToAttachDetectedUSBDevices)
        XCTAssertFalse(store.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches)
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertEqual(launchAtLoginService.setEnabledValues, [false])
        XCTAssertNil(defaults.object(forKey: "Onboarding.completedVersion"))
        XCTAssertNil(defaults.object(forKey: "USB.askToAttachDetectedDevices"))
        XCTAssertNil(
            defaults.object(
                forKey: "WireGuard.connectAutomaticallyWhenUSBDeviceAttaches"
            )
        )
        XCTAssertFalse(store.launchAtLoginStatusMessage.isEmpty)
    }
}

private enum AppPreferencesTestError: Error, Equatable {
    case rejected
}

@MainActor
private final class AppPreferencesTestLaunchAtLoginService: LaunchAtLoginManaging {
    var currentSnapshot = LaunchAtLoginSnapshot(
        isEnabled: false,
        requiresApproval: false,
        statusText: "disabled"
    )
    var setEnabledError: Error?
    private(set) var setEnabledValues: [Bool] = []

    func snapshot() -> LaunchAtLoginSnapshot {
        currentSnapshot
    }

    func setEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginSnapshot {
        setEnabledValues.append(isEnabled)
        if let setEnabledError {
            throw setEnabledError
        }

        currentSnapshot = LaunchAtLoginSnapshot(
            isEnabled: isEnabled,
            requiresApproval: false,
            statusText: isEnabled ? "enabled" : "disabled"
        )
        return currentSnapshot
    }
}
