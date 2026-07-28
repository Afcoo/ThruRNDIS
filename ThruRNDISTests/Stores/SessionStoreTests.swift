import AccessoryAccess
import Combine
import XCTest
@preconcurrency import Virtualization
@testable import ThruRNDIS

final class LocalizationResourceTests: XCTestCase {
    func testKoreanLocalizationIsBundled() throws {
        let localizationURL = try XCTUnwrap(
            Bundle.main.url(forResource: "ko", withExtension: "lproj")
        )
        let koreanBundle = try XCTUnwrap(Bundle(url: localizationURL))

        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        XCTAssertEqual(
            koreanBundle.localizedString(forKey: "Start VM", value: nil, table: nil),
            "VM 시작"
        )
        let wireGuardPromptFormat = koreanBundle.localizedString(
            forKey: "%@ is being connected. Connect to WireGuard when the connection is complete?",
            value: nil,
            table: nil
        )
        XCTAssertEqual(
            String(format: wireGuardPromptFormat, "Android USB"),
            "Android USB 기기를 연결하는 중입니다. 연결이 완료되면 WireGuard에 연결할까요?"
        )
    }
}

@MainActor
final class ConsoleSessionStoreTests: XCTestCase {
    func testEndpointAcrossChunksAndOutputState() {
        let model = ConsoleSessionStore(
            maximumOutputBytes: 128,
            maximumScanCharacters: 128
        )

        XCTAssertNil(model.append(Data("THRURNDIS_WG_END".utf8)))
        XCTAssertEqual(
            model.append(Data("POINT=192.168.64.2:51820\n".utf8)),
            "192.168.64.2:51820"
        )
        XCTAssertEqual(model.output.outputSequence, 2)
        XCTAssertEqual(
            String(data: model.output.data, encoding: .utf8),
            "THRURNDIS_WG_ENDPOINT=192.168.64.2:51820\n"
        )
    }

    func testTrimAndClearPreserveRendererResetContract() {
        let model = ConsoleSessionStore(
            maximumOutputBytes: 4,
            maximumScanCharacters: 16
        )

        _ = model.append(Data([1, 2, 3, 4, 5, 6]))

        XCTAssertEqual(model.output.data, Data([3, 4, 5, 6]))
        XCTAssertEqual(model.output.outputSequence, 1)
        XCTAssertEqual(model.output.resetSequence, 1)

        model.clear()

        XCTAssertTrue(model.output.data.isEmpty)
        XCTAssertEqual(model.output.outputSequence, 0)
        XCTAssertEqual(model.output.resetSequence, 2)
    }
}

@MainActor
final class EventLogStoreTests: XCTestCase {
    func testModeAndCategoryFiltersComposeWithoutMutatingRecords() {
        let store = EventLogStore()
        let date = Date(timeIntervalSince1970: 0)

        store.append("VM details", level: .debug, category: .vm, at: date)
        store.append("VM started", level: .info, category: .vm, at: date)
        store.append("USB retry", level: .warning, category: .usb, at: date)
        store.append("App failed", level: .error, category: .application, at: date)

        let normalText = store.text(isDebugModeEnabled: false)
        XCTAssertFalse(normalText.contains("VM details"))
        XCTAssertTrue(normalText.contains("VM started"))
        XCTAssertTrue(normalText.contains("USB retry"))
        XCTAssertTrue(normalText.contains("App failed"))

        let debugText = store.text(isDebugModeEnabled: true)
        XCTAssertTrue(debugText.contains("[DEBUG] [VM] VM details"))
        XCTAssertTrue(debugText.contains("[INFO] [VM] VM started"))
        XCTAssertTrue(debugText.contains("[WARNING] [USB] USB retry"))
        XCTAssertTrue(debugText.contains("[ERROR] [Application] App failed"))
        XCTAssertEqual(store.text, debugText)

        let normalVMText = store.text(
            isDebugModeEnabled: false,
            category: .vm
        )
        XCTAssertFalse(normalVMText.contains("VM details"))
        XCTAssertTrue(normalVMText.contains("[INFO] [VM] VM started"))
        XCTAssertFalse(normalVMText.contains("USB retry"))
        XCTAssertEqual(store.records.count, 4)

        store.clear()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.text(isDebugModeEnabled: true).isEmpty)
    }

    func testTrimEvictsOldestRecordRegardlessOfLevel() {
        let store = EventLogStore(maximumCharacters: 100)
        let date = Date(timeIntervalSince1970: 0)

        store.append(
            "important info",
            level: .info,
            category: .application,
            at: date
        )
        store.append(
            "debug one",
            level: .debug,
            category: .application,
            at: date
        )
        store.append(
            "debug two",
            level: .debug,
            category: .application,
            at: date
        )

        XCTAssertFalse(store.text.contains("important info"))
        XCTAssertTrue(store.text.contains("debug one"))
        XCTAssertTrue(store.text.contains("debug two"))
        XCTAssertLessThanOrEqual(store.text.count, 100)
    }

    func testPersistenceRetainsAllRecordsIndependentlyOfDisplayFilteringAndClear() async {
        let persistence = EventLogFilePersistenceSpy(hasLogFiles: true)
        let store = EventLogStore(
            maximumCharacters: 80,
            filePersistence: persistence
        )
        let date = Date(timeIntervalSince1970: 0)

        store.append(
            "hidden detail",
            level: .debug,
            category: .vm,
            at: date
        )
        store.append(
            "visible state",
            level: .info,
            category: .application,
            at: date
        )

        await store.flushFilePersistence()
        let appendedLines = await persistence.appendedLinesSnapshot()
        XCTAssertEqual(appendedLines.count, 2)
        XCTAssertTrue(
            appendedLines[0].hasPrefix(
                "[1970-01-01T00:00:00.000Z]"
            )
        )
        XCTAssertTrue(appendedLines[0].contains("[DEBUG] [VM] hidden detail"))
        XCTAssertTrue(appendedLines[1].contains("[INFO] [Application] visible state"))
        XCTAssertEqual(store.records.map(\.message), ["visible state"])
        XCTAssertFalse(
            store.text(isDebugModeEnabled: false).contains("hidden detail")
        )

        store.clear()

        XCTAssertTrue(store.records.isEmpty)
        let appendedLineCountAfterClear =
            await persistence.appendedLinesSnapshot().count
        XCTAssertEqual(appendedLineCountAfterClear, 2)
        XCTAssertTrue(store.hasPersistedLogFiles)
    }

    func testPersistenceFailureIsReportedOnceWithoutDroppingScreenRecords() async {
        let persistence = EventLogFilePersistenceSpy(
            appendError: EventLogFilePersistenceSpyError.writeFailed
        )
        let store = EventLogStore(filePersistence: persistence)

        store.append(
            "first event",
            level: .info,
            category: .application
        )
        store.append(
            "second event",
            level: .info,
            category: .application
        )

        await store.flushFilePersistence()
        XCTAssertEqual(
            store.records.filter {
                $0.message.hasPrefix("Event log file storage failed:")
            }.count,
            1
        )
        XCTAssertTrue(store.text.contains("first event"))
        XCTAssertTrue(store.text.contains("second event"))
        let appendedLineCount = await persistence.appendedLinesSnapshot().count
        XCTAssertEqual(appendedLineCount, 2)
    }

    func testPersistenceRunsOffMainActorAndPreservesRapidAppendOrder() async {
        let appendStarted = expectation(description: "background append started")
        let appendGate = DispatchSemaphore(value: 0)
        let persistence = EventLogFilePersistenceSpy(
            firstAppendStarted: appendStarted,
            firstAppendGate: appendGate
        )
        let store = EventLogStore(filePersistence: persistence)

        store.append(
            "first",
            level: .debug,
            category: .application,
            at: Date(timeIntervalSince1970: 1)
        )
        store.append(
            "second",
            level: .info,
            category: .vm,
            at: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(store.records.map(\.message), ["first", "second"])
        await fulfillment(of: [appendStarted], timeout: 1)
        appendGate.signal()
        await store.flushFilePersistence()

        let appendedLines = await persistence.appendedLinesSnapshot()
        XCTAssertEqual(appendedLines.count, 2)
        XCTAssertTrue(appendedLines[0].contains("[DEBUG] [Application] first"))
        XCTAssertTrue(appendedLines[1].contains("[INFO] [VM] second"))
    }

    func testInitialPersistedFileAvailabilityIsReflectedInCachedState() async {
        let persistence = EventLogFilePersistenceSpy(hasLogFiles: true)
        let store = EventLogStore(filePersistence: persistence)

        for _ in 0..<100 where !store.hasPersistedLogFiles {
            await Task.yield()
        }

        XCTAssertTrue(store.hasPersistedLogFiles)
    }

}

private actor EventLogFilePersistenceSpy: EventLogFilePersisting {
    private var hasLogFilesValue: Bool
    private var appendedLines: [String] = []
    private var appendError: Error?
    private let firstAppendStarted: XCTestExpectation?
    private var firstAppendGate: DispatchSemaphore?

    init(
        hasLogFiles: Bool = false,
        appendError: Error? = nil,
        firstAppendStarted: XCTestExpectation? = nil,
        firstAppendGate: DispatchSemaphore? = nil
    ) {
        hasLogFilesValue = hasLogFiles
        self.appendError = appendError
        self.firstAppendStarted = firstAppendStarted
        self.firstAppendGate = firstAppendGate
    }

    func hasLogFiles() -> Bool {
        hasLogFilesValue
    }

    func prepareLogsDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/persisted-logs")
    }

    func append(_ line: String) throws {
        if let firstAppendGate {
            self.firstAppendGate = nil
            firstAppendStarted?.fulfill()
            firstAppendGate.wait()
        }
        appendedLines.append(line)
        if let appendError {
            throw appendError
        }
        hasLogFilesValue = true
    }

    func flush() {}

    func performMaintenance() {}

    func appendedLinesSnapshot() -> [String] {
        appendedLines
    }

    func exportLogFiles(
        to destinationDirectoryURL: URL
    ) throws -> URL {
        hasLogFilesValue = true
        return destinationDirectoryURL.appendingPathComponent("exported-logs")
    }
}

private enum EventLogFilePersistenceSpyError: Error {
    case writeFailed
}

@MainActor
final class USBAccessoryCoordinatorTests: XCTestCase {
    func testAttachWithoutVirtualMachineFailsBeforePassthrough() {
        let coordinator = USBAccessoryCoordinator(
            monitor: ObservationTestUSBMonitor()
        )
        var statusMessages: [String] = []
        var results: [Bool] = []
        coordinator.onStatusMessage = { statusMessages.append($0) }

        coordinator.attachAccessory(id: 42, to: nil) {
            results.append($0)
        }

        XCTAssertEqual(results, [false])
        XCTAssertEqual(
            statusMessages,
            [String(localized: "Start the VM before attaching USB.")]
        )
    }

    func testStopCompletionWaitsForPendingRegistrationToSettle() async {
        let monitor = DeferredObservationTestUSBMonitor()
        let coordinator = USBAccessoryCoordinator(monitor: monitor)
        var didCompleteStop = false

        coordinator.startMonitoring(
            reason: "pending registration test"
        )
        coordinator.stopMonitoring(
            reason: "application termination"
        ) {
            didCompleteStop = true
        }

        XCTAssertFalse(didCompleteStop)
        XCTAssertEqual(monitor.stopCallCount, 0)

        monitor.completeStart(.success([]))
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(didCompleteStop)
        XCTAssertEqual(monitor.stopCallCount, 1)

        monitor.completeStop()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(didCompleteStop)
    }

    func testTerminationStopCancelsReloadBeforeCompletingItsWaiter() async {
        let monitor = DeferredObservationTestUSBMonitor()
        let coordinator = USBAccessoryCoordinator(monitor: monitor)
        var didCompleteTerminationStop = false

        coordinator.startMonitoring(
            reason: "initial registration"
        )
        monitor.completeStart(.success([]))
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(coordinator.isAccessoryMonitoring)
        XCTAssertEqual(monitor.startCallCount, 1)

        coordinator.reloadMonitoring(reason: "settings request")
        XCTAssertEqual(monitor.stopCallCount, 1)

        coordinator.stopMonitoring(
            reason: "application termination"
        ) {
            didCompleteTerminationStop = true
        }

        monitor.completeStop()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(didCompleteTerminationStop)
        XCTAssertFalse(coordinator.isAccessoryMonitoring)
        XCTAssertTrue(coordinator.canStartMonitoring)
        XCTAssertEqual(
            monitor.startCallCount,
            1,
            "A cancelled reload must not register the listener again."
        )
    }

    func testTerminationWaitsWhenReloadRegistrationAlreadyStarted() async {
        let monitor = DeferredObservationTestUSBMonitor()
        let coordinator = USBAccessoryCoordinator(monitor: monitor)
        var didCompleteTerminationStop = false

        coordinator.startMonitoring(
            reason: "initial registration"
        )
        monitor.completeStart(.success([]))
        await Task.yield()
        await Task.yield()

        coordinator.reloadMonitoring(reason: "settings request")
        monitor.completeStop()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(monitor.startCallCount, 2)

        coordinator.stopMonitoring(
            reason: "application termination"
        ) {
            didCompleteTerminationStop = true
        }
        monitor.completeStart(.success([]))
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(didCompleteTerminationStop)
        XCTAssertEqual(monitor.stopCallCount, 2)

        monitor.completeStop()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(didCompleteTerminationStop)
        XCTAssertFalse(coordinator.isAccessoryMonitoring)
        XCTAssertTrue(coordinator.canStartMonitoring)
    }
}

@MainActor
final class USBSessionStoreTests: XCTestCase {
    func testSnapshotIsAppliedAtomicallyAndDuplicatesAreIgnored() {
        let model = USBSessionStore()
        var receivedSnapshots: [USBSessionSnapshot] = []
        let cancellable = model.$snapshot
            .dropFirst()
            .sink { receivedSnapshots.append($0) }
        let snapshot = USBSessionSnapshot(
            accessories: [],
            isAccessoryMonitoring: true,
            selectedAccessoryID: 10,
            attachedAccessoryID: 11,
            vmSessionAccessoryID: 12
        )

        model.apply(snapshot)
        model.apply(snapshot)

        XCTAssertEqual(receivedSnapshots, [snapshot])
        withExtendedLifetime(cancellable) {}
    }
}

@MainActor
final class VMConfigurationStoreTests: XCTestCase {
    func testRestoreClampsValuesAndResetClearsPersistence() throws {
        let suiteName = "VMConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(12, forKey: "VM.cpuCount")
        defaults.set(1_300, forKey: "VM.memorySizeMiB")
        defaults.set("quiet root=/dev/vda custom=1", forKey: "VM.kernelCommandLine")
        defaults.set("/tmp/scratch.img", forKey: "VMAssets.diskImageURLPath")

        let store = VMConfigurationStore(defaults: defaults)

        XCTAssertEqual(store.cpuCount, 8)
        XCTAssertEqual(store.memorySizeMiB, 1_300)
        XCTAssertEqual(store.diskImageURL?.path, "/tmp/scratch.img")
        XCTAssertEqual(defaults.integer(forKey: "VM.cpuCount"), 8)
        XCTAssertEqual(defaults.integer(forKey: "VM.memorySizeMiB"), 1_300)
        let normalized = store.normalizedBootCommandLine()
        XCTAssertTrue(normalized.contains("console=hvc0"))
        XCTAssertTrue(normalized.contains("rdinit=/sbin/init"))
        XCTAssertTrue(normalized.contains("modules=virtio_pci,virtio_mmio,virtio_console"))
        XCTAssertTrue(normalized.contains("custom=1"))
        XCTAssertFalse(normalized.contains("quiet"))
        XCTAssertFalse(normalized.contains("root=/dev/vda"))

        store.reset()
        let restored = VMConfigurationStore(defaults: defaults)

        XCTAssertEqual(restored.cpuCount, 1)
        XCTAssertEqual(restored.memorySizeMiB, 1_024)
        XCTAssertNil(restored.diskImageURL)
    }

    func testRestoreRemovesRejectedScratchDiskPath() throws {
        let suiteName = "VMConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/tmp/installer.iso", forKey: "VMAssets.diskImageURLPath")

        let store = VMConfigurationStore(defaults: defaults)

        XCTAssertNil(store.diskImageURL)
        XCTAssertNil(defaults.object(forKey: "VMAssets.diskImageURLPath"))
    }
}

@MainActor
final class TetheringStoreTests: XCTestCase {
    func testSuccessfulSettingsResetAndTerminationDisconnectWireGuardOnlyOnce() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let vmCoordinator = ObservationTestVMCoordinator()
        let wireGuardStore = ObservationTestWireGuardStore()
        let launchAtLoginService = ObservationTestLaunchAtLoginService()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: wireGuardStore,
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        store.appPreferences.shouldAskToAttachDetectedUSBDevices = false
        store.wireGuardSession.endpointText = "vpn.example.com:51820"

        let didReset = await store.resetAppSettings()
        await store.prepareForApplicationTermination(disconnectWireGuard: false)

        XCTAssertTrue(didReset)
        XCTAssertTrue(store.appPreferences.shouldAskToAttachDetectedUSBDevices)
        XCTAssertEqual(store.wireGuardSession.endpointText, "")
        XCTAssertEqual(tunnelController.disconnectCallCount, 1)
        XCTAssertEqual(tunnelController.lastDisconnectWaitUntilStopped, true)
        XCTAssertEqual(tunnelController.removeSavedTunnelCallCount, 1)
        XCTAssertEqual(wireGuardStore.removeConfigurationDirectoryCallCount, 1)
        XCTAssertEqual(tunnelController.systemExtensionInvalidationCallCount, 1)
        XCTAssertEqual(vmCoordinator.invalidateCallCount, 1)
        XCTAssertEqual(launchAtLoginService.setEnabledValues, [false])
    }

    func testSettingsResetWhileVMIsActiveWaitsForStopBeforeRemovingConfiguration() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let vmCoordinator = ObservationTestVMCoordinator()
        let wireGuardStore = ObservationTestWireGuardStore()
        var operations: [String] = []
        tunnelController.onOperation = { operations.append($0) }
        vmCoordinator.onOperation = { operations.append($0) }
        wireGuardStore.onOperation = { operations.append($0) }
        vmCoordinator.hasVirtualMachine = true
        vmCoordinator.shouldSuspendStopAndWait = true
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: wireGuardStore,
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")

        XCTAssertTrue(store.canResetAppSettings)

        let resetTask = Task { @MainActor in
            await store.resetAppSettings()
        }
        await Task.yield()

        XCTAssertFalse(store.canResetAppSettings)
        XCTAssertEqual(operations, ["disconnectWireGuard", "stopVM"])
        XCTAssertEqual(wireGuardStore.removeConfigurationDirectoryCallCount, 0)

        vmCoordinator.completeStopAndWait(didStop: true)
        let didReset = await resetTask.value

        XCTAssertTrue(didReset)
        XCTAssertEqual(
            operations,
            ["disconnectWireGuard", "stopVM", "removeTunnelProfile", "removeWireGuardConfiguration"]
        )
        XCTAssertEqual(vmCoordinator.stopCallCount, 1)
        XCTAssertTrue(store.canResetAppSettings)
    }

    func testSettingsResetPreservesConfigurationWhenActiveVMDoesNotStop() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let vmCoordinator = ObservationTestVMCoordinator()
        let wireGuardStore = ObservationTestWireGuardStore()
        vmCoordinator.hasVirtualMachine = true
        vmCoordinator.stopAndWaitResult = false
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: wireGuardStore,
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")

        let didReset = await store.resetAppSettings()

        XCTAssertFalse(didReset)
        XCTAssertEqual(tunnelController.disconnectCallCount, 1)
        XCTAssertEqual(vmCoordinator.stopCallCount, 1)
        XCTAssertEqual(tunnelController.removeSavedTunnelCallCount, 0)
        XCTAssertEqual(wireGuardStore.removeConfigurationDirectoryCallCount, 0)
        XCTAssertEqual(
            store.resetStatusMessage,
            String(localized: "Could not stop the VM before resetting app settings.")
        )
        XCTAssertTrue(store.canResetAppSettings)
    }

    func testMissingEntitlementsBlockAffectedOperations() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = ObservationTestUSBMonitor()
        let vmCoordinator = ObservationTestVMCoordinator()
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: monitor),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: {
                RuntimeEntitlementSnapshot(
                    accessoryAccessUSB: false,
                    packetTunnelProvider: false,
                    systemExtensionInstall: false,
                    virtualization: false
                )
            },
            defaults: defaults
        )

        store.startAccessoryMonitoring()
        store.reloadAccessoryMonitoring()
        XCTAssertFalse(store.startVirtualMachine())
        XCTAssertFalse(store.requestWireGuardSystemExtensionActivation())
        store.refreshHostWireGuardTunnelStatus()

        XCTAssertEqual(monitor.startCallCount, 0)
        XCTAssertEqual(monitor.stopCallCount, 0)
        XCTAssertEqual(vmCoordinator.startCallCount, 0)
        XCTAssertEqual(
            store.wireGuardSession.systemExtensionStatus,
            .failed("System Extension installation entitlement is missing.")
        )
        XCTAssertEqual(
            store.wireGuardSession.hostTunnelStatus,
            .missingPacketTunnelEntitlement
        )
    }

    func testFirstRunAccessoryMonitoringWaitsUntilOnboardingEnds() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = ObservationTestUSBMonitor()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: monitor),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            runtimeEntitlementSnapshotProvider: {
                RuntimeEntitlementSnapshot(
                    accessoryAccessUSB: true,
                    packetTunnelProvider: false,
                    systemExtensionInstall: false,
                    virtualization: false
                )
            },
            defaults: defaults
        )

        store.onboardingPresentationDidBegin()
        store.startAccessoryMonitoring()

        XCTAssertTrue(store.isOnboardingPresented)
        XCTAssertFalse(store.canStartAccessoryMonitoring)
        XCTAssertFalse(store.isAccessoryMonitoring)
        XCTAssertEqual(monitor.startCallCount, 0)

        store.onboardingPresentationDidEnd()

        XCTAssertFalse(store.isOnboardingPresented)
        XCTAssertTrue(store.isAccessoryMonitoring)
        XCTAssertEqual(monitor.startCallCount, 1)
    }

    func testRestartedOnboardingRestoresOnlyAnActiveAccessoryListener() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = ObservationTestUSBMonitor()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: monitor),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            runtimeEntitlementSnapshotProvider: {
                RuntimeEntitlementSnapshot(
                    accessoryAccessUSB: true,
                    packetTunnelProvider: false,
                    systemExtensionInstall: false,
                    virtualization: false
                )
            },
            defaults: defaults
        )

        store.startAccessoryMonitoringOnLaunch()
        for _ in 0..<3 {
            await Task.yield()
        }
        store.onboardingPresentationDidBegin()

        XCTAssertFalse(store.isAccessoryMonitoring)
        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertEqual(monitor.stopCallCount, 1)

        store.onboardingPresentationDidEnd()
        for _ in 0..<3 {
            await Task.yield()
        }

        XCTAssertTrue(store.isAccessoryMonitoring)
        XCTAssertEqual(monitor.startCallCount, 2)

        store.stopAccessoryMonitoring()
        for _ in 0..<3 {
            await Task.yield()
        }
        store.onboardingPresentationDidBegin()
        store.onboardingPresentationDidEnd()
        for _ in 0..<3 {
            await Task.yield()
        }

        XCTAssertFalse(store.isAccessoryMonitoring)
        XCTAssertEqual(monitor.startCallCount, 2)
        XCTAssertEqual(monitor.stopCallCount, 2)
    }

    func testDetectedUSBPromptPreferenceControlsAutomaticOffer() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let usbCoordinator = USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor())
        let usbSession = USBSessionStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )
        let record = USBAccessoryRecord(
            id: 42,
            deviceName: "Test USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        usbSession.apply(
            USBSessionSnapshot(
                accessories: [record],
                selectedAccessoryID: record.id
            )
        )

        store.appPreferences.shouldAskToAttachDetectedUSBDevices = false
        usbCoordinator.onAccessoryAvailable?(record)

        XCTAssertNil(usbSession.attachmentPrompt)

        store.appPreferences.shouldAskToAttachDetectedUSBDevices = true
        usbCoordinator.onAccessoryAvailable?(record)

        XCTAssertEqual(usbSession.attachmentPrompt?.accessory.id, record.id)
    }

    func testManualUSBAttachmentEntryPointsPromptAndRequireAcceptanceForFutureAutomaticConnections() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = ObservationTestUSBCoordinator()
        let usbSession = USBSessionStore()
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            defaults: defaults
        )
        let accessory = USBAccessoryRecord(
            id: 42,
            deviceName: "Test USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        usbCoordinator.setAvailableAccessories(
            [accessory],
            selectedAccessoryID: accessory.id
        )
        vmCoordinator.onStateChange?(.starting, "VM starting")
        store.requestAttachSelectedAccessory()
        let declinedPrompt = try XCTUnwrap(store.wireGuardConnectionPrompt)
        XCTAssertEqual(declinedPrompt.accessory.id, accessory.id)
        store.resolveWireGuardConnectionPrompt(
            id: declinedPrompt.id,
            accepted: false,
            shouldAutomaticallyConnectNextTime: true
        )

        XCTAssertFalse(store.appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches)
        XCTAssertNil(
            defaults.object(forKey: "WireGuard.connectAutomaticallyWhenUSBDeviceAttaches")
        )

        vmCoordinator.onStateChange?(.failed, "VM failed")
        vmCoordinator.onStateChange?(.starting, "VM starting")
        store.requestAttachAccessory(id: accessory.id)
        let acceptedPrompt = try XCTUnwrap(store.wireGuardConnectionPrompt)
        XCTAssertEqual(acceptedPrompt.accessory.id, accessory.id)
        store.resolveWireGuardConnectionPrompt(
            id: acceptedPrompt.id,
            accepted: true,
            shouldAutomaticallyConnectNextTime: true
        )

        XCTAssertTrue(store.appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches)
        XCTAssertEqual(
            defaults.object(
                forKey: "WireGuard.connectAutomaticallyWhenUSBDeviceAttaches"
            ) as? Bool,
            true
        )

        vmCoordinator.onStateChange?(.failed, "VM failed")
        vmCoordinator.onStateChange?(.starting, "VM starting")
        store.requestAttachAccessory(id: accessory.id)

        XCTAssertNil(store.wireGuardConnectionPrompt)
    }

    func testDetectedUSBAttachmentApprovalPresentsWireGuardPrompt() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = ObservationTestUSBCoordinator()
        let usbSession = USBSessionStore()
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            defaults: defaults
        )
        let accessory = USBAccessoryRecord(
            id: 42,
            deviceName: "Test USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        vmCoordinator.onStateChange?(.starting, "VM starting")

        usbCoordinator.simulateAccessoryAvailable(accessory)
        XCTAssertEqual(usbSession.attachmentPrompt?.accessory.id, accessory.id)

        store.resolveUSBAttachmentPrompt(accepted: true)

        XCTAssertNil(usbSession.attachmentPrompt)
        XCTAssertEqual(store.wireGuardConnectionPrompt?.accessory.id, accessory.id)
    }

    func testWireGuardPromptBlocksNextQueuedUSBPromptDuringSelectionStateChange() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = ObservationTestUSBCoordinator()
        let usbSession = USBSessionStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )
        let firstAccessory = USBAccessoryRecord(
            id: 42,
            deviceName: "First USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        let secondAccessory = USBAccessoryRecord(
            id: 43,
            deviceName: "Second USB Device",
            deviceDescriptorData: Data(repeating: 1, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        vmCoordinator.onStateChange?(.starting, "VM starting")
        usbCoordinator.simulateAccessoryAvailable(firstAccessory)
        usbCoordinator.simulateAccessoryAvailable(secondAccessory)

        XCTAssertEqual(usbSession.attachmentPrompt?.accessory.id, firstAccessory.id)

        store.resolveUSBAttachmentPrompt(accepted: true)

        XCTAssertNil(usbSession.attachmentPrompt)
        XCTAssertEqual(
            store.wireGuardConnectionPrompt?.accessory.id,
            firstAccessory.id
        )
    }

    func testApprovedWireGuardConnectionSurvivesFreshVMStartForUSBAttachment() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = ObservationTestUSBCoordinator()
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            defaults: defaults
        )
        let accessory = USBAccessoryRecord(
            id: 42,
            deviceName: "Test USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        usbCoordinator.setAvailableAccessories(
            [accessory],
            selectedAccessoryID: accessory.id
        )
        tunnelController.onSystemExtensionStatusChange?(.active)
        vmCoordinator.onStateChange?(.stopping, "VM stopping")

        store.requestAttachAccessory(id: accessory.id)
        let prompt = try XCTUnwrap(store.wireGuardConnectionPrompt)
        store.resolveWireGuardConnectionPrompt(
            id: prompt.id,
            accepted: true,
            shouldAutomaticallyConnectNextTime: false
        )

        vmCoordinator.onStateChange?(.stopped, "VM stopped")
        vmCoordinator.onStopped?()

        XCTAssertEqual(vmCoordinator.startCallCount, 1)
        vmCoordinator.canSendConsoleInput = true
        vmCoordinator.onStateChange?(.running, "VM running")
        XCTAssertEqual(
            usbCoordinator.pendingAttachAccessoryID,
            accessory.id
        )
        usbCoordinator.completeAttachment(success: true)
        vmCoordinator.onConsoleOutput?(
            Data("THRURNDIS_WG_ENDPOINT=192.168.64.2:51820\n".utf8)
        )
        for _ in 0..<100 where tunnelController.connectCallCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(tunnelController.connectCallCount, 1)
    }

    func testVMFailureAndAccessoryLossClearWireGuardPrompt() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = ObservationTestUSBCoordinator()
        let usbSession = USBSessionStore()
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            defaults: defaults
        )
        let accessory = USBAccessoryRecord(
            id: 42,
            deviceName: "Test USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        usbCoordinator.setAvailableAccessories(
            [accessory],
            selectedAccessoryID: accessory.id
        )
        vmCoordinator.onStateChange?(.starting, "VM starting")
        store.requestAttachAccessory(id: accessory.id)
        XCTAssertEqual(store.wireGuardConnectionPrompt?.accessory.id, accessory.id)

        vmCoordinator.onStateChange?(.failed, "VM failed")
        XCTAssertNil(store.wireGuardConnectionPrompt)

        vmCoordinator.onStateChange?(.starting, "VM starting")
        store.requestAttachAccessory(id: accessory.id)
        XCTAssertEqual(store.wireGuardConnectionPrompt?.accessory.id, accessory.id)

        usbCoordinator.simulateAccessoryUnavailable(accessory.id)
        XCTAssertNil(store.wireGuardConnectionPrompt)
    }

    func testUSBAttachmentFailureDismissesWireGuardPrompt() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = ObservationTestUSBCoordinator()
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            defaults: defaults
        )
        let accessory = USBAccessoryRecord(
            id: 42,
            deviceName: "Test USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        usbCoordinator.setAvailableAccessories(
            [accessory],
            selectedAccessoryID: accessory.id
        )
        vmCoordinator.onStateChange?(.running, "VM running")

        store.requestAttachAccessory(id: accessory.id)
        XCTAssertEqual(store.wireGuardConnectionPrompt?.accessory.id, accessory.id)
        XCTAssertEqual(usbCoordinator.pendingAttachAccessoryID, accessory.id)

        usbCoordinator.completeAttachment(success: false)

        XCTAssertNil(store.wireGuardConnectionPrompt)
    }

    func testAutomaticWireGuardConnectionForUSBAttachmentWaitsForEndpointAndConnectsOnce() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        vmCoordinator.canSendConsoleInput = true
        let usbCoordinator = ObservationTestUSBCoordinator()
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let accessory = USBAccessoryRecord(
            id: 42,
            deviceName: "Test USB Device",
            deviceDescriptorData: Data(repeating: 0, count: 18),
            configurationDescriptorData: Data([9, 2, 9, 0, 0, 1, 0, 0x80, 50])
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            defaults: defaults
        )

        tunnelController.onSystemExtensionStatusChange?(.active)
        store.appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches = true
        usbCoordinator.setAvailableAccessories(
            [accessory],
            selectedAccessoryID: accessory.id
        )
        vmCoordinator.onStateChange?(.running, "VM running")
        store.requestAttachAccessory(id: accessory.id)

        XCTAssertNil(store.wireGuardConnectionPrompt)
        XCTAssertEqual(usbCoordinator.pendingAttachAccessoryID, accessory.id)

        usbCoordinator.completeAttachment(success: true)

        await Task.yield()
        XCTAssertEqual(tunnelController.connectCallCount, 0)

        vmCoordinator.onConsoleOutput?(
            Data("THRURNDIS_WG_ENDPOINT=192.168.64.2:51820\n".utf8)
        )
        await Task.yield()

        XCTAssertEqual(tunnelController.connectCallCount, 1)

        vmCoordinator.onConsoleOutput?(
            Data("THRURNDIS_WG_ENDPOINT=192.168.64.2:51820\n".utf8)
        )
        await Task.yield()

        XCTAssertEqual(tunnelController.connectCallCount, 1)
    }

    func testTerminationConfirmationRequiresAttachedUSBAndActiveWireGuard() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let usbSession = USBSessionStore()
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )

        XCTAssertFalse(store.shouldConfirmApplicationTermination)

        usbSession.apply(USBSessionSnapshot(attachedAccessoryID: 11))
        XCTAssertFalse(store.shouldConfirmApplicationTermination)

        tunnelController.onStatusChange?(.connecting)
        XCTAssertTrue(store.shouldConfirmApplicationTermination)

        tunnelController.onStatusChange?(.disconnecting)
        XCTAssertFalse(store.shouldConfirmApplicationTermination)

        tunnelController.onStatusChange?(.connected)
        usbSession.apply(USBSessionSnapshot())
        XCTAssertFalse(store.shouldConfirmApplicationTermination)
    }

    func testManualUSBDetachStopsVMWithoutRestarting() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbSession = USBSessionStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")
        usbSession.apply(USBSessionSnapshot(attachedAccessoryID: 11))

        store.detachAccessory()

        XCTAssertEqual(vmCoordinator.stopCallCount, 1)
        XCTAssertEqual(vmCoordinator.restartCallCount, 0)
        XCTAssertEqual(vmCoordinator.startCallCount, 0)
    }

    func testDifferentUSBRequiresDetachBeforeOrdinaryAttach() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbSession = USBSessionStore()
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")
        usbSession.apply(
            USBSessionSnapshot(attachedAccessoryID: 11, vmSessionAccessoryID: 11)
        )

        store.requestAttachAccessory(id: 22)

        XCTAssertEqual(
            store.statusMessage,
            String(localized: "Detach the current USB accessory before attaching another USB accessory.")
        )
        XCTAssertEqual(vmCoordinator.stopCallCount, 0)
        XCTAssertEqual(vmCoordinator.restartCallCount, 0)
        XCTAssertEqual(vmCoordinator.startCallCount, 0)
    }

    func testUSBDisconnectDuringManualRestartDoesNotStartVMWithoutTarget() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        vmCoordinator.canRestart = true
        let usbSession = USBSessionStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: usbSession,
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")
        usbSession.apply(
            USBSessionSnapshot(attachedAccessoryID: 11, vmSessionAccessoryID: 11)
        )

        store.restartVirtualMachine()
        vmCoordinator.onStateChange?(.stopping, "VM stopping")
        vmCoordinator.onStateChange?(.stopped, "VM stopped")
        vmCoordinator.onStopped?()
        vmCoordinator.completeRestart()

        XCTAssertEqual(vmCoordinator.restartCallCount, 1)
        XCTAssertEqual(vmCoordinator.startCallCount, 0)
        XCTAssertEqual(vmCoordinator.stopCallCount, 0)
        XCTAssertEqual(
            store.statusMessage,
            String(localized: "The USB accessory became unavailable before it could be attached.")
        )
    }

    func testUnexpectedUSBDetachStopsVMWithoutRestartOrAutomaticStart() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor())
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")

        usbCoordinator.onUnexpectedDetach?(11, "USB passthrough disconnected")
        vmCoordinator.onStateChange?(.stopping, "VM stopping")
        vmCoordinator.onStopped?()

        XCTAssertEqual(vmCoordinator.stopCallCount, 1)
        XCTAssertEqual(vmCoordinator.restartCallCount, 0)
        XCTAssertEqual(vmCoordinator.startCallCount, 0)
        withExtendedLifetime(store) {}
    }

    func testDuplicateUSBDetachWhileStoppingDoesNotRequestAnotherStop() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let usbCoordinator = USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor())
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")

        usbCoordinator.onUnexpectedDetach?(11, "AccessoryAccess disconnect")
        vmCoordinator.onStateChange?(.stopping, "VM stopping")
        usbCoordinator.onUnexpectedDetach?(11, "VZ disconnect")

        XCTAssertEqual(vmCoordinator.stopCallCount, 1)
        XCTAssertEqual(vmCoordinator.restartCallCount, 0)
        withExtendedLifetime(store) {}
    }

    func testVMStopCancelsPendingTunnelAndClearsDiscoveredEndpoint() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(
                monitor: ObservationTestUSBMonitor()
            ),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )

        vmCoordinator.onStateChange?(.running, "VM running")
        vmCoordinator.onConsoleOutput?(
            Data("THRURNDIS_WG_ENDPOINT=192.168.64.2:51820\n".utf8)
        )
        store.wireGuardSession.endpointText = "manual.example.com:51820"
        tunnelController.onStatusChange?(.connected)
        XCTAssertEqual(store.wireGuardSession.discoveredEndpoint, "192.168.64.2:51820")

        vmCoordinator.onStateChange?(.stopping, "VM stopping")
        vmCoordinator.onStopped?()
        await Task.yield()

        XCTAssertNil(store.wireGuardSession.discoveredEndpoint)
        XCTAssertEqual(store.wireGuardSession.resolvedEndpoint, "manual.example.com:51820")
        XCTAssertEqual(tunnelController.disconnectCallCount, 1)
        XCTAssertEqual(tunnelController.lastDisconnectWaitUntilStopped, false)
    }

    func testConnectIsRejectedWhileVMIsNotRunning() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        vmCoordinator.canSendConsoleInput = true
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(
                monitor: ObservationTestUSBMonitor()
            ),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: {
                RuntimeEntitlementSnapshot(
                    accessoryAccessUSB: true,
                    packetTunnelProvider: true,
                    systemExtensionInstall: true,
                    virtualization: true
                )
            },
            defaults: defaults
        )
        tunnelController.onSystemExtensionStatusChange?(.active)
        store.wireGuardSession.endpointText = "192.168.64.2:51820"

        store.connectHostWireGuardTunnel()

        XCTAssertEqual(tunnelController.connectCallCount, 0)
    }

    func testResetSkipsProfileAndConfigurationRemovalWhenTunnelCannotStop() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        tunnelController.disconnectSucceeds = false
        let wireGuardStore = ObservationTestWireGuardStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: wireGuardStore,
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )

        let didReset = await store.resetAppSettings()

        XCTAssertFalse(didReset)
        XCTAssertEqual(tunnelController.disconnectCallCount, 1)
        XCTAssertEqual(tunnelController.lastDisconnectWaitUntilStopped, true)
        XCTAssertEqual(tunnelController.removeSavedTunnelCallCount, 0)
        XCTAssertEqual(wireGuardStore.removeConfigurationDirectoryCallCount, 0)
    }

    func testResetPreservesConfigurationWhenTunnelProfileRemovalFails() async throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        tunnelController.savedTunnelRemovalSucceeds = false
        let wireGuardStore = ObservationTestWireGuardStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: wireGuardStore,
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )

        let didReset = await store.resetAppSettings()

        XCTAssertFalse(didReset)
        XCTAssertEqual(tunnelController.disconnectCallCount, 1)
        XCTAssertEqual(tunnelController.removeSavedTunnelCallCount, 1)
        XCTAssertEqual(wireGuardStore.removeConfigurationDirectoryCallCount, 0)
    }

    func testVMCallbacksUpdateAndInvalidateOnlyTheirOwningChildStores() throws {
        let suiteName = "TetheringStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let consoleSession = ConsoleSessionStore()
        let eventLog = EventLogStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(
                monitor: ObservationTestUSBMonitor()
            ),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: eventLog,
            consoleSession: consoleSession,
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )
        var storeChangeCount = 0
        var consoleChangeCount = 0
        var eventLogChangeCount = 0
        let storeCancellable = store.objectWillChange.sink {
            storeChangeCount += 1
        }
        let consoleCancellable = consoleSession.objectWillChange.sink {
            consoleChangeCount += 1
        }
        let eventLogCancellable = eventLog.objectWillChange.sink {
            eventLogChangeCount += 1
        }

        vmCoordinator.onConsoleOutput?(Data("guest output".utf8))

        XCTAssertEqual(consoleSession.output.data, Data("guest output".utf8))
        XCTAssertEqual(consoleChangeCount, 1)
        XCTAssertEqual(eventLogChangeCount, 0)
        XCTAssertEqual(storeChangeCount, 0)

        vmCoordinator.onEventLog?("VM started.", .info)

        XCTAssertEqual(eventLogChangeCount, 1)
        XCTAssertEqual(consoleChangeCount, 1)
        XCTAssertEqual(storeChangeCount, 0)
        XCTAssertEqual(eventLog.records.last?.message, "VM started.")
        XCTAssertEqual(eventLog.records.last?.category, .vm)
        withExtendedLifetime((storeCancellable, consoleCancellable, eventLogCancellable)) {}
    }
}

@MainActor
private final class ObservationTestVMCoordinator: VMCoordinating {
    var onStateChange: ((VMRuntimeState, String) -> Void)?
    var onEventLog: EventLogHandler?
    var onConsoleOutput: ((Data) -> Void)?
    var onUSBPassthroughDisconnect: ((VZUSBPassthroughDevice) -> Void)?
    var onStopped: (() -> Void)?

    var runtimeState: VMRuntimeState = .idle
    var virtualMachine: VZVirtualMachine?
    var canStop = false
    var canRestart = false
    private(set) var invalidateCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var restartCallCount = 0
    private var restartContinuation: (() -> Void)?
    private var stopAndWaitContinuation: CheckedContinuation<Bool, Never>?
    var onOperation: ((String) -> Void)?
    var shouldSuspendStopAndWait = false
    var stopAndWaitResult = true
    var canSendConsoleInput = false
    var canStart = true
    var hasVirtualMachine = false

    func start(input: VMCoordinatorStartInput) {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func stopAndWaitUntilStopped() async -> Bool {
        stopCallCount += 1
        onOperation?("stopVM")
        if shouldSuspendStopAndWait {
            return await withCheckedContinuation { continuation in
                stopAndWaitContinuation = continuation
            }
        }
        completeStoppedStateIfNeeded(didStop: stopAndWaitResult)
        return stopAndWaitResult
    }

    func completeStopAndWait(didStop: Bool) {
        let continuation = stopAndWaitContinuation
        stopAndWaitContinuation = nil
        completeStoppedStateIfNeeded(didStop: didStop)
        continuation?.resume(returning: didStop)
    }

    func restart(reason: String, startAgain: @escaping () -> Void) {
        restartCallCount += 1
        restartContinuation = startAgain
    }

    func completeRestart() {
        let continuation = restartContinuation
        restartContinuation = nil
        continuation?()
    }

    private func completeStoppedStateIfNeeded(didStop: Bool) {
        guard didStop else {
            return
        }
        hasVirtualMachine = false
        runtimeState = .stopped
        onStateChange?(.stopped, "VM stopped")
        onStopped?()
    }
    func sendConsoleBytes(_ data: Data) -> Bool { true }
    func invalidate() {
        invalidateCallCount += 1
    }
}

private final class ObservationTestUSBMonitor: USBAccessoryMonitoring {
    var onConnect: ((AAUSBAccessory) -> Void)?
    var onDisconnect: ((AAUSBAccessory) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start(completion: @escaping (Result<[AAUSBAccessory], Error>) -> Void) {
        startCallCount += 1
        completion(.success([]))
    }

    func stop(completion: (() -> Void)?) {
        stopCallCount += 1
        completion?()
    }
}

private final class DeferredObservationTestUSBMonitor: USBAccessoryMonitoring {
    var onConnect: ((AAUSBAccessory) -> Void)?
    var onDisconnect: ((AAUSBAccessory) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    private var startCompletion: ((Result<[AAUSBAccessory], Error>) -> Void)?
    private var stopCompletions: [() -> Void] = []

    func start(completion: @escaping (Result<[AAUSBAccessory], Error>) -> Void) {
        startCallCount += 1
        startCompletion = completion
    }

    func stop(completion: (() -> Void)?) {
        stopCallCount += 1
        if let completion {
            stopCompletions.append(completion)
        }
    }

    func completeStart(_ result: Result<[AAUSBAccessory], Error>) {
        let completion = startCompletion
        startCompletion = nil
        completion?(result)
    }

    func completeStop() {
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }
}

@MainActor
private final class ObservationTestUSBCoordinator: USBAccessoryCoordinating {
    var onStateChange: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var onEventLog: EventLogHandler?
    var onAccessoryAvailable: ((USBAccessoryRecord) -> Void)?
    var onAccessoryUnavailable: ((UInt64) -> Void)?
    var onUnexpectedDetach: ((UInt64, String) -> Void)?
    var runtimeStateProvider: (() -> VMRuntimeState)?

    private(set) var accessories: [USBAccessoryRecord] = []
    private(set) var isAccessoryMonitoring = false
    private(set) var selectedAccessoryID: UInt64?
    private(set) var attachedAccessoryID: UInt64?
    private(set) var vmSessionAccessoryID: UInt64?
    private(set) var pendingAttachAccessoryID: UInt64?

    private var pendingAttachCompletion: ((Bool) -> Void)?

    var canStartMonitoring: Bool {
        !isAccessoryMonitoring
    }

    var canStopMonitoring: Bool {
        isAccessoryMonitoring
    }

    var canReloadMonitoring: Bool {
        isAccessoryMonitoring
    }

    func canRequestAttachment(for accessoryID: UInt64) -> Bool {
        accessories.contains { $0.id == accessoryID }
            && pendingAttachAccessoryID == nil
            && vmSessionAccessoryID == nil
            && attachedAccessoryID != accessoryID
    }

    func canDetachAccessory(runtimeState: VMRuntimeState) -> Bool {
        runtimeState == .running && attachedAccessoryID != nil
    }

    func selectAccessory(id: UInt64?) {
        selectedAccessoryID = id
        onStateChange?()
    }

    func startMonitoring(
        reason: String,
        completion: (() -> Void)?
    ) {
        isAccessoryMonitoring = true
        onStateChange?()
        completion?()
    }

    func stopMonitoring(
        reason: String,
        completion: (() -> Void)?
    ) {
        isAccessoryMonitoring = false
        accessories.removeAll()
        selectedAccessoryID = nil
        onStateChange?()
        completion?()
    }

    func reloadMonitoring(reason: String) {
        onStateChange?()
    }

    func prepareForIntentionalVMStop() {}

    func resetForVMStart() {
        clearAttachmentState()
        onStateChange?()
    }

    func clearAttachmentForStoppedVM() {
        clearAttachmentState()
        onStateChange?()
    }

    func attachAccessory(
        id accessoryID: UInt64,
        to virtualMachine: VZVirtualMachine?,
        completion: ((Bool) -> Void)?
    ) {
        guard canRequestAttachment(for: accessoryID) else {
            completion?(false)
            return
        }

        pendingAttachAccessoryID = accessoryID
        pendingAttachCompletion = completion
        selectedAccessoryID = accessoryID
        onStateChange?()
    }

    func handlePassthroughDisconnect(device: VZUSBPassthroughDevice) {}

    func setAvailableAccessories(
        _ accessories: [USBAccessoryRecord],
        selectedAccessoryID: UInt64?
    ) {
        self.accessories = accessories
        self.selectedAccessoryID = selectedAccessoryID
        onStateChange?()
    }

    func simulateAccessoryAvailable(_ accessory: USBAccessoryRecord) {
        accessories.removeAll { $0.id == accessory.id }
        accessories.append(accessory)
        accessories.sort { $0.usbIDText < $1.usbIDText }
        if selectedAccessoryID == nil {
            selectedAccessoryID = accessory.id
        }
        onStateChange?()
        onAccessoryAvailable?(accessory)
    }

    func simulateAccessoryUnavailable(_ accessoryID: UInt64) {
        accessories.removeAll { $0.id == accessoryID }
        if selectedAccessoryID == accessoryID {
            selectedAccessoryID = accessories.first?.id
        }
        if attachedAccessoryID == accessoryID {
            attachedAccessoryID = nil
        }
        if vmSessionAccessoryID == accessoryID {
            vmSessionAccessoryID = nil
        }
        if pendingAttachAccessoryID == accessoryID {
            pendingAttachAccessoryID = nil
            pendingAttachCompletion = nil
        }
        onStateChange?()
        onAccessoryUnavailable?(accessoryID)
    }

    func completeAttachment(success: Bool) {
        guard let accessoryID = pendingAttachAccessoryID else {
            XCTFail("No USB attachment is pending.")
            return
        }

        let completion = pendingAttachCompletion
        pendingAttachAccessoryID = nil
        pendingAttachCompletion = nil
        if success {
            attachedAccessoryID = accessoryID
            vmSessionAccessoryID = accessoryID
        }
        onStateChange?()
        completion?(success)
    }

    private func clearAttachmentState() {
        attachedAccessoryID = nil
        vmSessionAccessoryID = nil
        pendingAttachAccessoryID = nil
        pendingAttachCompletion = nil
    }
}

@MainActor
private final class ObservationTestHostWireGuardTunnelController: HostWireGuardTunnelControlling {
    var onStatusChange: ((HostWireGuardTunnelStatus) -> Void)?
    var onSystemExtensionStatusChange: ((WireGuardSystemExtensionStatus) -> Void)?
    var onEventLog: EventLogHandler?
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastDisconnectWaitUntilStopped: Bool?
    private(set) var removeSavedTunnelCallCount = 0
    private(set) var systemExtensionStatusRefreshCallCount = 0
    private(set) var systemExtensionInvalidationCallCount = 0
    var disconnectSucceeds = true
    var savedTunnelRemovalSucceeds = true
    var onOperation: ((String) -> Void)?

    func refreshStatus() async {}

    func refreshSystemExtensionStatus() async {
        systemExtensionStatusRefreshCallCount += 1
    }

    func activateSystemExtension() async {}

    func invalidateSystemExtensionOperations() {
        systemExtensionInvalidationCallCount += 1
    }

    func connect(wgQuickConfiguration: String) async {
        connectCallCount += 1
    }

    @discardableResult
    func disconnect(waitUntilStopped: Bool) async -> Bool {
        disconnectCallCount += 1
        lastDisconnectWaitUntilStopped = waitUntilStopped
        onOperation?("disconnectWireGuard")
        return disconnectSucceeds
    }

    @discardableResult
    func removeSavedTunnelIfNeeded() async -> Bool {
        removeSavedTunnelCallCount += 1
        onOperation?("removeTunnelProfile")
        return savedTunnelRemovalSucceeds
    }
}

@MainActor
private final class ObservationTestLaunchAtLoginService: LaunchAtLoginManaging {
    private(set) var setEnabledValues: [Bool] = []

    func snapshot() -> LaunchAtLoginSnapshot {
        LaunchAtLoginSnapshot(
            isEnabled: false,
            requiresApproval: false,
            statusText: ""
        )
    }

    func setEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginSnapshot {
        setEnabledValues.append(isEnabled)
        return snapshot()
    }
}

@MainActor
private final class ObservationTestAssetProvider: VMAssetProviding {
    var hasConfiguredAssets = true
    var isBusy = false

    func validatedBootAssets() throws -> VMAssetBootAssets {
        VMAssetBootAssets(
            kernelURL: URL(fileURLWithPath: "/tmp/Image-lts"),
            initialRamdiskURL: URL(fileURLWithPath: "/tmp/initramfs-thrurndis-lts")
        )
    }
}

private final class ObservationTestWireGuardStore: WireGuardConfigurationStoring {
    let files: WireGuardConfigurationFiles
    private(set) var removeConfigurationDirectoryCallCount = 0
    var onOperation: ((String) -> Void)?

    var sharedDirectoryURL: URL {
        files.sharedDirectoryURL
    }

    init() {
        let root = URL(fileURLWithPath: "/tmp/ObservationTestWireGuard")
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
        preparedConfiguration()
    }

    func requireExistingConfiguration(
        builder: WireGuardConfigurationBuilder
    ) throws -> PreparedWireGuardConfiguration {
        preparedConfiguration()
    }

    func removeConfigurationDirectory() throws {
        removeConfigurationDirectoryCallCount += 1
        onOperation?("removeWireGuardConfiguration")
    }

    private func preparedConfiguration() -> PreparedWireGuardConfiguration {
        PreparedWireGuardConfiguration(
            files: files,
            keyMaterial: WireGuardKeyMaterial(
                serverPrivateKey: "server-private",
                serverPublicKey: "server-public",
                clientPrivateKey: "client-private",
                clientPublicKey: "client-public"
            )
        )
    }
}
