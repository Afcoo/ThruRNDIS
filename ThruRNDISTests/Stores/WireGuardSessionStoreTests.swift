/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import XCTest
@testable import ThruRNDIS

@MainActor
final class WireGuardSessionStoreTests: XCTestCase {
    func testConnectionInputsUseDefaultsPersistOverridesAndRenderConfiguration() throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = WireGuardSessionStoreTestConfigurationStore()
        let store = makeStore(
            configurationStore: configurationStore,
            defaults: defaults
        )

        XCTAssertEqual(store.dnsServersText, "")
        XCTAssertEqual(store.endpointText, "")
        XCTAssertEqual(store.allowedIPsText, "")
        XCTAssertEqual(store.resolvedEndpoint, nil)
        XCTAssertEqual(store.resolvedAllowedIPs, "0.0.0.0/0")
        XCTAssertEqual(
            store.resolvedDNSServers,
            ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
        )
        XCTAssertFalse(store.canExportConfiguration)

        store.endpointText = " vpn.example.com:12345 "
        store.allowedIPsText = " 10.0.0.0/8 "
        store.dnsServersText = "9.9.9.9\n149.112.112.112"

        XCTAssertEqual(store.resolvedEndpoint, "vpn.example.com:12345")
        XCTAssertEqual(store.resolvedAllowedIPs, "10.0.0.0/8")
        XCTAssertEqual(
            store.resolvedDNSServers,
            ["9.9.9.9", "149.112.112.112"]
        )
        XCTAssertEqual(store.invalidConnectionFields, [])
        XCTAssertTrue(store.canExportConfiguration)
        XCTAssertTrue(
            store.clientConfiguration.contains(
                "PrivateKey = wireguard-session-client-private-a"
            )
        )
        XCTAssertTrue(
            store.clientConfiguration.contains(
                "Endpoint = vpn.example.com:12345"
            )
        )
        XCTAssertTrue(
            store.clientConfiguration.contains("AllowedIPs = 10.0.0.0/8")
        )
        XCTAssertTrue(
            store.clientConfiguration.contains(
                "DNS = 9.9.9.9, 149.112.112.112"
            )
        )

        let restoredStore = makeStore(
            configurationStore: WireGuardSessionStoreTestConfigurationStore(),
            defaults: defaults
        )
        XCTAssertEqual(restoredStore.endpointText, " vpn.example.com:12345 ")
        XCTAssertEqual(restoredStore.allowedIPsText, " 10.0.0.0/8 ")
        XCTAssertEqual(
            restoredStore.dnsServersText,
            "9.9.9.9\n149.112.112.112"
        )
        XCTAssertEqual(restoredStore.invalidConnectionFields, [])
    }

    func testConnectionInputsAreValidatedLiveAndValidatedAgainBeforeConnect() throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(defaults: defaults)
        var readinessChangeCount = 0
        store.onReadinessChange = {
            readinessChangeCount += 1
        }

        store.endpointText = "1:51820"
        store.allowedIPsText = "1"
        store.dnsServersText = "1"

        XCTAssertTrue(store.hasEndpointValidationError)
        XCTAssertTrue(store.hasAllowedIPsValidationError)
        XCTAssertTrue(store.hasDNSServersValidationError)
        XCTAssertEqual(
            store.invalidConnectionFields,
            [.endpoint, .allowedIPs, .dnsServers]
        )
        XCTAssertEqual(readinessChangeCount, 3)

        store.endpointText = "192.168.64.2:51820"
        store.allowedIPsText = "0.0.0.0/0"
        store.dnsServersText = "1.1.1.1, 8.8.8.8"

        XCTAssertTrue(store.invalidConnectionFields.isEmpty)
        XCTAssertTrue(store.validateConnectionInputs())

        store.endpointText = ""

        XCTAssertFalse(store.hasEndpointValidationError)
        XCTAssertFalse(store.validateConnectionInputs())
        XCTAssertTrue(store.hasEndpointValidationError)
    }

    func testPersistedInvalidConnectionInputsAreValidatedOnInitialization() throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("vpn.example.com", forKey: "WireGuard.endpointOverride")
        defaults.set("10.100.0.2/33", forKey: "WireGuard.allowedIPs")
        defaults.set("1.1.1.1,", forKey: "WireGuard.dnsServers")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(
            store.invalidConnectionFields,
            Set(WireGuardConnectionField.allCases)
        )
    }

    func testDiscoveredEndpointUpdateAndClearNotifyReadinessAndStopActiveTunnel() async throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = WireGuardSessionStoreTestTunnelController()
        let eventLog = EventLogStore()
        let store = makeStore(
            tunnelController: tunnelController,
            eventLog: eventLog,
            defaults: defaults
        )
        var readinessChangeCount = 0
        store.onReadinessChange = {
            readinessChangeCount += 1
        }

        store.updateDiscoveredEndpoint("192.168.64.2:51820")

        XCTAssertEqual(store.discoveredEndpoint, "192.168.64.2:51820")
        XCTAssertEqual(store.resolvedEndpoint, "192.168.64.2:51820")
        XCTAssertEqual(readinessChangeCount, 1)

        store.updateDiscoveredEndpoint("192.168.64.2:51820")

        XCTAssertEqual(readinessChangeCount, 1)

        store.updateHostTunnelStatus(.connected)
        readinessChangeCount = 0
        store.clearDiscoveredEndpoint(
            reason: "test VM stop",
            alwaysDisconnectTunnel: false
        )
        await waitUntil {
            tunnelController.disconnectWaitUntilStoppedValues == [false]
        }

        XCTAssertNil(store.discoveredEndpoint)
        XCTAssertNil(store.resolvedEndpoint)
        XCTAssertEqual(readinessChangeCount, 1)
        XCTAssertTrue(
            eventLog.text.contains(
                "WireGuard endpoint cleared: test VM stop."
            )
        )
    }

    func testConfigurationReloadFailureRecoveryRemovalAndReset() throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = WireGuardSessionStoreTestConfigurationStore()
        let store = makeStore(
            configurationStore: configurationStore,
            defaults: defaults
        )
        var readinessChangeCount = 0
        store.onReadinessChange = {
            readinessChangeCount += 1
        }

        XCTAssertTrue(store.hasKeyMaterial)
        XCTAssertEqual(configurationStore.prepareCallCount, 1)

        configurationStore.requireError = WireGuardSessionStoreTestError.rejected
        XCTAssertFalse(
            store.reloadConfiguration(
                reason: "expected test failure",
                requireExisting: true
            )
        )
        XCTAssertFalse(store.hasKeyMaterial)
        XCTAssertEqual(configurationStore.requireCallCount, 1)
        XCTAssertEqual(readinessChangeCount, 1)

        configurationStore.requireError = nil
        configurationStore.keyMaterial = .wireGuardSessionStoreTestB
        XCTAssertTrue(
            store.reloadConfiguration(
                reason: "test recovery",
                requireExisting: false
            )
        )
        XCTAssertTrue(store.hasKeyMaterial)
        XCTAssertEqual(configurationStore.prepareCallCount, 2)
        XCTAssertTrue(
            store.clientConfiguration.contains(
                "PrivateKey = wireguard-session-client-private-b"
            )
        )

        XCTAssertNoThrow(try store.removeConfigurationDirectory())
        XCTAssertEqual(configurationStore.removeCallCount, 1)

        store.endpointText = "vpn.example.com:51820"
        store.allowedIPsText = "10.0.0.0/8"
        store.dnsServersText = "9.9.9.9"
        store.updateDiscoveredEndpoint("192.168.64.2:51820")
        readinessChangeCount = 0

        store.resetPersistedValues()

        XCTAssertEqual(store.endpointText, "")
        XCTAssertEqual(store.allowedIPsText, "")
        XCTAssertEqual(store.dnsServersText, "")
        XCTAssertFalse(store.hasKeyMaterial)
        XCTAssertNil(store.discoveredEndpoint)
        XCTAssertTrue(store.invalidConnectionFields.isEmpty)
        XCTAssertEqual(readinessChangeCount, 1)
        XCTAssertNil(defaults.object(forKey: "WireGuard.endpointOverride"))
        XCTAssertNil(defaults.object(forKey: "WireGuard.allowedIPs"))
        XCTAssertNil(defaults.object(forKey: "WireGuard.dnsServers"))
    }

    func testControllerCallbacksPublishStatusesNotifyReadinessAndGateRefresh() async throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = WireGuardSessionStoreTestTunnelController()
        let store = makeStore(
            tunnelController: tunnelController,
            defaults: defaults
        )
        await waitUntil {
            tunnelController.hostStatusRefreshCallCount == 1
                && tunnelController.systemExtensionStatusRefreshCallCount == 1
        }
        var readinessChangeCount = 0
        store.onReadinessChange = {
            readinessChangeCount += 1
        }

        tunnelController.onStatusChange?(.connected)
        tunnelController.onSystemExtensionStatusChange?(.active)

        XCTAssertEqual(store.hostTunnelStatus, .connected)
        XCTAssertEqual(store.systemExtensionStatus, .active)
        XCTAssertEqual(readinessChangeCount, 2)
        XCTAssertFalse(store.canRequestSystemExtensionActivation)

        store.refreshHostTunnelStatus()
        store.refreshSystemExtensionStatus()
        await waitUntil {
            tunnelController.hostStatusRefreshCallCount == 2
                && tunnelController.systemExtensionStatusRefreshCallCount == 2
        }

        tunnelController.onStatusChange?(.connecting)
        let refreshCount = tunnelController.hostStatusRefreshCallCount
        store.refreshHostTunnelStatus()
        await Task.yield()

        XCTAssertEqual(
            tunnelController.hostStatusRefreshCallCount,
            refreshCount
        )
    }

    func testSystemExtensionActivationAndSettingsAreIndependentActions() async throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = WireGuardSessionStoreTestTunnelController()
        var settingsOpenCount = 0
        let store = WireGuardSessionStore(
            configurationStore: WireGuardSessionStoreTestConfigurationStore(),
            configurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            tunnelController: tunnelController,
            eventLog: EventLogStore(),
            systemExtensionSettingsOpener: {
                settingsOpenCount += 1
                return true
            },
            defaults: defaults
        )

        XCTAssertTrue(store.requestSystemExtensionActivation())
        XCTAssertFalse(store.requestSystemExtensionActivation())
        await waitUntil {
            tunnelController.systemExtensionActivationCallCount == 1
                && !store.isSystemExtensionActivationInProgress
        }

        XCTAssertEqual(settingsOpenCount, 0)

        tunnelController.onSystemExtensionStatusChange?(.awaitingUserApproval)
        store.openSystemExtensionSettings()

        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(tunnelController.systemExtensionActivationCallCount, 1)
    }

    func testConnectDisconnectAndSavedTunnelRemovalDelegateToController() async throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = WireGuardSessionStoreTestTunnelController()
        let store = makeStore(
            tunnelController: tunnelController,
            defaults: defaults
        )

        tunnelController.onSystemExtensionStatusChange?(.active)
        store.endpointText = "vpn.example.com:51820"

        XCTAssertTrue(store.connect())
        await waitUntil {
            tunnelController.connectConfigurations.count == 1
        }
        XCTAssertTrue(
            tunnelController.connectConfigurations[0].contains(
                "Endpoint = vpn.example.com:51820"
            )
        )

        store.disconnect()
        await waitUntil {
            tunnelController.disconnectWaitUntilStoppedValues == [false]
        }
        let didDisconnect = await store.disconnectAndWait()
        XCTAssertTrue(didDisconnect)
        XCTAssertEqual(
            tunnelController.disconnectWaitUntilStoppedValues,
            [false, true]
        )

        let didRemoveSavedTunnel = await store.removeSavedTunnelIfNeeded()
        XCTAssertTrue(didRemoveSavedTunnel)
        XCTAssertEqual(tunnelController.removeSavedTunnelCallCount, 1)
    }

    func testTerminationCancelsActivationInvalidatesControllerAndRejectsLateSystemCallbacks() async throws {
        let suiteName = "WireGuardSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = WireGuardSessionStoreTestTunnelController()
        tunnelController.shouldSuspendSystemExtensionActivation = true
        let eventLog = EventLogStore()
        var settingsOpenCount = 0
        let store = WireGuardSessionStore(
            configurationStore: WireGuardSessionStoreTestConfigurationStore(),
            configurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            tunnelController: tunnelController,
            eventLog: eventLog,
            systemExtensionSettingsOpener: {
                settingsOpenCount += 1
                return true
            },
            defaults: defaults
        )
        await waitUntil {
            tunnelController.systemExtensionStatusRefreshCallCount == 1
        }

        XCTAssertTrue(store.requestSystemExtensionActivation())
        await waitUntil {
            tunnelController.systemExtensionActivationCallCount == 1
        }

        await store.prepareForApplicationTermination(disconnectTunnel: true)

        XCTAssertEqual(tunnelController.invalidateCallCount, 1)
        XCTAssertEqual(
            tunnelController.disconnectWaitUntilStoppedValues,
            [true]
        )
        XCTAssertFalse(store.isSystemExtensionActivationInProgress)
        XCTAssertFalse(store.canRequestSystemExtensionActivation)

        let statusAtTermination = store.systemExtensionStatus
        let eventLogAtTermination = eventLog.text
        let refreshCountAtTermination =
            tunnelController.systemExtensionStatusRefreshCallCount

        tunnelController.onSystemExtensionStatusChange?(.awaitingUserApproval)
        tunnelController.onEventLog?("Late test callback")
        store.refreshSystemExtensionStatus()
        store.openSystemExtensionSettings()
        XCTAssertFalse(store.requestSystemExtensionActivation())
        await Task.yield()

        XCTAssertEqual(store.systemExtensionStatus, statusAtTermination)
        XCTAssertEqual(eventLog.text, eventLogAtTermination)
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertEqual(
            tunnelController.systemExtensionStatusRefreshCallCount,
            refreshCountAtTermination
        )
    }

    private func makeStore(
        configurationStore: WireGuardSessionStoreTestConfigurationStore =
            WireGuardSessionStoreTestConfigurationStore(),
        tunnelController: WireGuardSessionStoreTestTunnelController? = nil,
        eventLog: EventLogStore? = nil,
        defaults: UserDefaults
    ) -> WireGuardSessionStore {
        WireGuardSessionStore(
            configurationStore: configurationStore,
            configurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            tunnelController: tunnelController
                ?? WireGuardSessionStoreTestTunnelController(),
            eventLog: eventLog ?? EventLogStore(),
            systemExtensionSettingsOpener: { true },
            defaults: defaults
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous store work.", file: file, line: line)
    }
}

private enum WireGuardSessionStoreTestError: Error {
    case rejected
}

private final class WireGuardSessionStoreTestConfigurationStore:
    WireGuardConfigurationStoring {
    let files: WireGuardConfigurationFiles
    var keyMaterial: WireGuardKeyMaterial = .wireGuardSessionStoreTestA
    var prepareError: Error?
    var requireError: Error?
    var removeError: Error?
    private(set) var prepareCallCount = 0
    private(set) var requireCallCount = 0
    private(set) var removeCallCount = 0

    var sharedDirectoryURL: URL {
        files.sharedDirectoryURL
    }

    init() {
        let root = URL(
            fileURLWithPath: "/tmp/WireGuardSessionStoreTests-\(UUID().uuidString)"
        )
        files = WireGuardConfigurationFiles(
            wireGuardDirectoryURL: root,
            sharedDirectoryURL: root.appendingPathComponent("Shared"),
            serverConfigurationURL: root.appendingPathComponent("Shared/wg0.conf"),
            serverKeyURL: root.appendingPathComponent("wg-server.key"),
            clientKeyURL: root.appendingPathComponent("wg-client.key")
        )
    }

    func prepareConfigurationIfNeeded(
        builder: WireGuardConfigurationBuilder
    ) throws -> PreparedWireGuardConfiguration {
        prepareCallCount += 1
        if let prepareError {
            throw prepareError
        }
        return preparedConfiguration()
    }

    func requireExistingConfiguration(
        builder: WireGuardConfigurationBuilder
    ) throws -> PreparedWireGuardConfiguration {
        requireCallCount += 1
        if let requireError {
            throw requireError
        }
        return preparedConfiguration()
    }

    func removeConfigurationDirectory() throws {
        removeCallCount += 1
        if let removeError {
            throw removeError
        }
    }

    private func preparedConfiguration() -> PreparedWireGuardConfiguration {
        PreparedWireGuardConfiguration(
            files: files,
            keyMaterial: keyMaterial
        )
    }
}

@MainActor
private final class WireGuardSessionStoreTestTunnelController:
    HostWireGuardTunnelControlling {
    var onStatusChange: ((HostWireGuardTunnelStatus) -> Void)?
    var onSystemExtensionStatusChange: ((WireGuardSystemExtensionStatus) -> Void)?
    var onEventLog: ((String) -> Void)?
    var shouldSuspendSystemExtensionActivation = false
    var disconnectResult = true
    var removeSavedTunnelResult = true
    private(set) var hostStatusRefreshCallCount = 0
    private(set) var systemExtensionStatusRefreshCallCount = 0
    private(set) var systemExtensionActivationCallCount = 0
    private(set) var invalidateCallCount = 0
    private(set) var connectConfigurations: [String] = []
    private(set) var disconnectWaitUntilStoppedValues: [Bool] = []
    private(set) var removeSavedTunnelCallCount = 0

    func refreshStatus() async {
        hostStatusRefreshCallCount += 1
    }

    func refreshSystemExtensionStatus() async {
        systemExtensionStatusRefreshCallCount += 1
    }

    func activateSystemExtension() async {
        systemExtensionActivationCallCount += 1
        guard shouldSuspendSystemExtensionActivation else {
            return
        }
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func invalidateSystemExtensionOperations() {
        invalidateCallCount += 1
    }

    func connect(wgQuickConfiguration: String) async {
        connectConfigurations.append(wgQuickConfiguration)
    }

    @discardableResult
    func disconnect(waitUntilStopped: Bool) async -> Bool {
        disconnectWaitUntilStoppedValues.append(waitUntilStopped)
        return disconnectResult
    }

    @discardableResult
    func removeSavedTunnelIfNeeded() async -> Bool {
        removeSavedTunnelCallCount += 1
        return removeSavedTunnelResult
    }
}

private extension WireGuardKeyMaterial {
    static let wireGuardSessionStoreTestA = WireGuardKeyMaterial(
        serverPrivateKey: "wireguard-session-server-private-a",
        serverPublicKey: "wireguard-session-server-public-a",
        clientPrivateKey: "wireguard-session-client-private-a",
        clientPublicKey: "wireguard-session-client-public-a"
    )

    static let wireGuardSessionStoreTestB = WireGuardKeyMaterial(
        serverPrivateKey: "wireguard-session-server-private-b",
        serverPublicKey: "wireguard-session-server-public-b",
        clientPrivateKey: "wireguard-session-client-private-b",
        clientPublicKey: "wireguard-session-client-public-b"
    )
}
