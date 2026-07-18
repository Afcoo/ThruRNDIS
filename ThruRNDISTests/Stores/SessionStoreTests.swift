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
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "Configure VM Assets in Settings",
                value: nil,
                table: nil
            ),
            "설정에서 VM에셋을 구성하세요"
        )

        let statusFormat = koreanBundle.localizedString(
            forKey: "ThruRNDIS — VM %@, %@, %@",
            value: nil,
            table: nil
        )
        XCTAssertEqual(
            String(
                format: statusFormat,
                "실행 중",
                "USB: 연결 안 됨",
                "WireGuard: 연결 안 됨"
            ),
            "ThruRNDIS — VM 실행 중, USB: 연결 안 됨, WireGuard: 연결 안 됨"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "Check that the value is entered correctly",
                value: nil,
                table: nil
            ),
            "값이 올바르게 입력되었는지 확인하세요"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "USB and WireGuard will disconnect. Quit anyway?",
                value: nil,
                table: nil
            ),
            "USB 디바이스와 연결이 해제됩니다.\n정말 종료하시겠어요?"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "Enable the Network Extension",
                value: nil,
                table: nil
            ),
            "네트워크 확장 프로그램 활성화"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "ThruRNDIS requires its Network Extension to be active before it can connect.",
                value: nil,
                table: nil
            ),
            "ThruRNDIS를 연결하려면 네트워크 확장 프로그램이 활성화되어 있어야 합니다."
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "Open Settings",
                value: nil,
                table: nil
            ),
            "설정 열기"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "Ask to Connect When a Device Is Detected",
                value: nil,
                table: nil
            ),
            "기기 감지 시 연결 묻기"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "Detach the current USB accessory before attaching another USB accessory.",
                value: nil,
                table: nil
            ),
            "다른 USB 액세서리를 연결하기 전에 현재 USB 액세서리 연결을 해제하세요."
        )
        let vmAssetsRequiredFormat = koreanBundle.localizedString(
            forKey: "%@ has been connected, but VM assets have not been configured.\nOpen Settings to install VM Assets.",
            value: nil,
            table: nil
        )
        XCTAssertEqual(
            String(format: vmAssetsRequiredFormat, "Android USB"),
            "Android USB 기기가 연결되었지만 VM 에셋이 구성되지 않았습니다. \n설정을 열어 VM Asset을 설치하세요."
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "Network extension activation is already in progress.",
                value: nil,
                table: nil
            ),
            "네트워크 확장 프로그램 활성화가 이미 진행 중입니다."
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "This build cannot activate the Network Extension. Run a signed copy of ThruRNDIS from Applications.",
                value: nil,
                table: nil
            ),
            "이 빌드에서는 네트워크 확장 프로그램을 활성화할 수 없습니다. 서명된 ThruRNDIS를 응용 프로그램 폴더에서 실행하세요."
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
    func testAppendIncludesSourceAndNotifiesObservers() {
        let store = EventLogStore()
        var changeCount = 0
        let cancellable = store.objectWillChange.sink {
            changeCount += 1
        }

        store.append(
            "VM started.",
            source: .virtualMachine,
            at: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(store.text.contains("[VM] VM started."))
        withExtendedLifetime(cancellable) {}
    }

    func testTrimDropsOldestCompleteLineAndClearResetsText() {
        let store = EventLogStore(maximumCharacters: 70)
        let date = Date(timeIntervalSince1970: 0)

        store.append("old entry", source: .app, at: date)
        store.append(String(repeating: "x", count: 50), source: .virtualMachine, at: date)

        XCTAssertLessThanOrEqual(store.text.count, 70)
        XCTAssertFalse(store.text.contains("old entry"))
        XCTAssertTrue(store.text.contains(String(repeating: "x", count: 50)))

        store.clear()

        XCTAssertTrue(store.text.isEmpty)
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
        XCTAssertEqual(model.selectedAccessoryID, 10)
        XCTAssertEqual(model.attachedAccessoryID, 11)
        XCTAssertEqual(model.vmSessionAccessoryID, 12)
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
        XCTAssertEqual(store.memorySizeMiB, 1_280)
        XCTAssertEqual(store.diskImageURL?.path, "/tmp/scratch.img")
        XCTAssertEqual(defaults.integer(forKey: "VM.cpuCount"), 8)
        XCTAssertEqual(defaults.integer(forKey: "VM.memorySizeMiB"), 1_280)
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
final class TetheringStoreObservationTests: XCTestCase {
    func testRequestingSystemExtensionActivationNeverOpensSettingsAutomatically() async throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        var settingsOpenCount = 0
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            systemExtensionSettingsOpener: {
                settingsOpenCount += 1
                return true
            },
            defaults: defaults
        )

        XCTAssertTrue(store.requestWireGuardSystemExtensionActivation())

        XCTAssertEqual(settingsOpenCount, 0)
        await Task.yield()
        XCTAssertEqual(tunnelController.systemExtensionActivationCallCount, 1)

        tunnelController.onSystemExtensionStatusChange?(.awaitingUserApproval)

        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertFalse(store.canRequestWireGuardSystemExtensionActivation)
    }

    func testOpeningSystemExtensionSettingsWhileAwaitingApprovalDoesNotRequestActivation() async throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        var settingsOpenCount = 0
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            systemExtensionSettingsOpener: {
                settingsOpenCount += 1
                return true
            },
            defaults: defaults
        )

        tunnelController.onSystemExtensionStatusChange?(.awaitingUserApproval)

        XCTAssertFalse(store.canRequestWireGuardSystemExtensionActivation)
        store.openWireGuardSystemExtensionSettings()

        XCTAssertEqual(settingsOpenCount, 1)
        await Task.yield()
        XCTAssertEqual(tunnelController.systemExtensionActivationCallCount, 0)
    }

    func testSystemExtensionSettingsCanOpenForEveryStatus() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        var settingsOpenCount = 0
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            systemExtensionSettingsOpener: {
                settingsOpenCount += 1
                return true
            },
            defaults: defaults
        )

        store.openWireGuardSystemExtensionSettings()
        let statuses: [WireGuardSystemExtensionStatus] = [
            .checking,
            .inactive,
            .activationRequested,
            .awaitingUserApproval,
            .active,
            .uninstalling,
            .restartRequired,
            .failed("test failure"),
        ]
        for status in statuses {
            tunnelController.onSystemExtensionStatusChange?(status)
            store.openWireGuardSystemExtensionSettings()
        }

        XCTAssertEqual(settingsOpenCount, statuses.count + 1)
        XCTAssertEqual(tunnelController.systemExtensionActivationCallCount, 0)
    }

    func testTerminationCancelsSystemExtensionActivationAndPreventsLateSettingsOpen() async throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let eventLog = EventLogStore()
        var settingsOpenCount = 0
        let runtimeEntitlements = RuntimeEntitlementSnapshot(
            accessoryAccessUSB: true,
            packetTunnelProvider: true,
            systemExtensionInstall: true,
            virtualization: true
        )
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: eventLog,
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            runtimeEntitlementSnapshotProvider: { runtimeEntitlements },
            systemExtensionSettingsOpener: {
                settingsOpenCount += 1
                return true
            },
            defaults: defaults
        )

        XCTAssertTrue(store.requestWireGuardSystemExtensionActivation())

        await store.prepareForApplicationTermination()
        await Task.yield()

        XCTAssertEqual(tunnelController.systemExtensionInvalidationCallCount, 1)
        XCTAssertEqual(tunnelController.systemExtensionActivationCallCount, 0)
        XCTAssertFalse(store.isWireGuardSystemExtensionActivationInProgress)
        XCTAssertEqual(settingsOpenCount, 0)

        let statusAtTermination = store.wireGuardSystemExtensionStatus
        let eventLogAtTermination = eventLog.text
        tunnelController.onSystemExtensionStatusChange?(.awaitingUserApproval)
        tunnelController.onSystemExtensionStatusChange?(.active)
        tunnelController.onEventLog?("Late system extension callback.")
        store.requestWireGuardSystemExtensionActivation()
        store.openWireGuardSystemExtensionSettings()

        XCTAssertEqual(store.wireGuardSystemExtensionStatus, statusAtTermination)
        XCTAssertEqual(eventLog.text, eventLogAtTermination)
        XCTAssertEqual(settingsOpenCount, 0)
    }

    func testTerminationAfterSettingsResetSkipsRedundantWireGuardDisconnect() async throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let vmCoordinator = ObservationTestVMCoordinator()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )

        await store.prepareForApplicationTermination(disconnectWireGuard: false)

        XCTAssertEqual(tunnelController.disconnectCallCount, 0)
        XCTAssertEqual(tunnelController.systemExtensionInvalidationCallCount, 1)
        XCTAssertEqual(vmCoordinator.invalidateCallCount, 1)
    }

    func testSuccessfulSettingsResetAndTerminationDisconnectWireGuardOnlyOnce() async throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let wireGuardStore = ObservationTestWireGuardStore()
        let launchAtLoginService = ObservationTestLaunchAtLoginService()
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
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        store.shouldAskToAttachDetectedUSBDevices = false

        let didReset = await store.resetAppSettings()
        await store.prepareForApplicationTermination(disconnectWireGuard: false)

        XCTAssertTrue(didReset)
        XCTAssertTrue(store.shouldAskToAttachDetectedUSBDevices)
        XCTAssertNil(defaults.object(forKey: "USB.askToAttachDetectedDevices"))
        XCTAssertEqual(tunnelController.disconnectCallCount, 1)
        XCTAssertEqual(tunnelController.lastDisconnectWaitUntilStopped, true)
        XCTAssertEqual(tunnelController.removeSavedTunnelCallCount, 1)
        XCTAssertEqual(wireGuardStore.removeConfigurationDirectoryCallCount, 1)
        XCTAssertEqual(tunnelController.systemExtensionInvalidationCallCount, 1)
        XCTAssertEqual(launchAtLoginService.setEnabledValues, [false])
    }

    func testOnboardingVersionTwoRequiresNetworkExtensionStep() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(2, forKey: "Onboarding.completedVersion")

        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )

        XCTAssertFalse(store.hasCompletedOnboarding)

        store.completeOnboarding()

        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertEqual(defaults.integer(forKey: "Onboarding.completedVersion"), 3)
    }

    func testDetectedUSBPromptPreferenceDefaultsToEnabledAndPersists() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let makeStore = {
            TetheringStore(
                assetProvider: ObservationTestAssetProvider(),
                vmCoordinator: ObservationTestVMCoordinator(),
                usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
                wireGuardConfigurationStore: ObservationTestWireGuardStore(),
                wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
                eventLog: EventLogStore(),
                consoleSession: ConsoleSessionStore(),
                usbSession: USBSessionStore(),
                vmConfiguration: VMConfigurationStore(defaults: defaults),
                hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
                defaults: defaults
            )
        }

        let store = makeStore()

        XCTAssertTrue(store.shouldAskToAttachDetectedUSBDevices)
        XCTAssertNil(defaults.object(forKey: "USB.askToAttachDetectedDevices"))

        store.shouldAskToAttachDetectedUSBDevices = false

        XCTAssertEqual(
            defaults.object(forKey: "USB.askToAttachDetectedDevices") as? Bool,
            false
        )
        XCTAssertFalse(makeStore().shouldAskToAttachDetectedUSBDevices)
    }

    func testDetectedUSBPromptPreferenceControlsAutomaticOffer() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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

        store.shouldAskToAttachDetectedUSBDevices = false
        usbCoordinator.onAccessoryAvailable?(record)

        XCTAssertNil(usbSession.attachmentPrompt)

        store.shouldAskToAttachDetectedUSBDevices = true
        usbCoordinator.onAccessoryAvailable?(record)

        XCTAssertEqual(usbSession.attachmentPrompt?.accessory.id, record.id)
    }

    func testSystemExtensionStatusUpdatesStoreAndFailsClosed() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let eventLog = EventLogStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: eventLog,
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )

        XCTAssertEqual(store.wireGuardSystemExtensionStatus, .unknown)
        XCTAssertFalse(store.canConnectHostWireGuardTunnel)

        tunnelController.onSystemExtensionStatusChange?(.active)

        XCTAssertEqual(store.wireGuardSystemExtensionStatus, .active)
        XCTAssertTrue(eventLog.text.contains("Network Extension: Active"))

        tunnelController.onSystemExtensionStatusChange?(.inactive)

        XCTAssertEqual(store.wireGuardSystemExtensionStatus, .inactive)
        XCTAssertFalse(store.canConnectHostWireGuardTunnel)
        XCTAssertTrue(eventLog.text.contains("Network Extension: Inactive"))
    }

    func testTerminationConfirmationRequiresAttachedUSBAndActiveWireGuard() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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

        tunnelController.onStatusChange?(.connected)
        XCTAssertTrue(store.shouldConfirmApplicationTermination)

        tunnelController.onStatusChange?(.reasserting)
        XCTAssertTrue(store.shouldConfirmApplicationTermination)

        tunnelController.onStatusChange?(.disconnecting)
        XCTAssertFalse(store.shouldConfirmApplicationTermination)

        tunnelController.onStatusChange?(.connected)
        usbSession.apply(USBSessionSnapshot())
        XCTAssertFalse(store.shouldConfirmApplicationTermination)
    }

    func testManualUSBDetachStopsVMWithoutRestarting() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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

    func testPhysicalAndSystemUSBDetachStopVMWithoutRestartOrAutomaticStart() throws {
        let reasons = [
            "AccessoryAccess disconnected the attached USB accessory.",
            "USB passthrough device disconnected by the system.",
        ]

        for reason in reasons {
            let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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

            usbCoordinator.onUnexpectedDetach?(11, reason)
            vmCoordinator.onStateChange?(.stopping, "VM stopping")
            vmCoordinator.onStopped?()

            XCTAssertEqual(vmCoordinator.stopCallCount, 1, reason)
            XCTAssertEqual(vmCoordinator.restartCallCount, 0, reason)
            XCTAssertEqual(vmCoordinator.startCallCount, 0, reason)
        }
    }

    func testDuplicateUSBDetachWhileStoppingDoesNotRequestAnotherStop() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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
    }

    func testVMStopCancelsPendingTunnelAndClearsDiscoveredEndpoint() async throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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
        store.wireGuardEndpointText = "manual.example.com:51820"
        let providerStatus = HostWireGuardTunnelStatus.activatingSystemExtension
        tunnelController.onStatusChange?(providerStatus)
        XCTAssertEqual(store.discoveredWireGuardEndpoint, "192.168.64.2:51820")
        XCTAssertTrue(
            store.eventLog.text.contains(
                "Provider: \(providerStatus.eventLogDescription)"
            )
        )

        vmCoordinator.onStateChange?(.stopping, "VM stopping")
        vmCoordinator.onStopped?()
        await Task.yield()

        XCTAssertNil(store.discoveredWireGuardEndpoint)
        XCTAssertEqual(store.resolvedWireGuardEndpoint, "manual.example.com:51820")
        XCTAssertEqual(tunnelController.disconnectCallCount, 1)
        XCTAssertEqual(tunnelController.lastDisconnectWaitUntilStopped, false)
    }

    func testWireGuardConnectionValuesUseFallbacksAndPersistOverrides() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )

        vmCoordinator.onConsoleOutput?(
            Data("THRURNDIS_WG_ENDPOINT=192.168.64.2:51820\n".utf8)
        )

        XCTAssertEqual(store.resolvedWireGuardEndpoint, "192.168.64.2:51820")
        XCTAssertEqual(store.resolvedWireGuardAllowedIPs, "0.0.0.0/0")
        XCTAssertEqual(
            store.resolvedWireGuardDNSServers,
            ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
        )

        store.wireGuardEndpointText = " vpn.example.com:12345 "
        store.wireGuardAllowedIPsText = " 10.0.0.0/8 "
        store.wireGuardDNSServersText = "9.9.9.9,\n149.112.112.112"

        XCTAssertEqual(store.resolvedWireGuardEndpoint, "vpn.example.com:12345")
        XCTAssertEqual(store.resolvedWireGuardAllowedIPs, "10.0.0.0/8")
        XCTAssertEqual(store.resolvedWireGuardDNSServers, ["9.9.9.9", "149.112.112.112"])
        XCTAssertTrue(store.wireGuardClientConfiguration.contains("Endpoint = vpn.example.com:12345"))
        XCTAssertTrue(store.wireGuardClientConfiguration.contains("AllowedIPs = 10.0.0.0/8"))
        XCTAssertTrue(store.wireGuardClientConfiguration.contains("DNS = 9.9.9.9, 149.112.112.112"))
        XCTAssertEqual(defaults.string(forKey: "WireGuard.endpointOverride"), " vpn.example.com:12345 ")
        XCTAssertEqual(defaults.string(forKey: "WireGuard.allowedIPs"), " 10.0.0.0/8 ")
        XCTAssertEqual(defaults.string(forKey: "WireGuard.dnsServers"), "9.9.9.9,\n149.112.112.112")

        store.wireGuardDNSServersText = " \n "

        XCTAssertEqual(
            store.resolvedWireGuardDNSServers,
            ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
        )
        XCTAssertFalse(store.hasWireGuardDNSServersValidationError)
        XCTAssertTrue(
            store.wireGuardClientConfiguration.contains(
                "DNS = 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4"
            )
        )
    }

    func testConnectionValuesAreValidatedLiveAndBlockConnect() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        vmCoordinator.canSendConsoleInput = true
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let eventLog = EventLogStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: eventLog,
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )
        vmCoordinator.onStateChange?(.running, "VM running")
        XCTAssertTrue(store.invalidWireGuardConnectionFields.isEmpty)
        store.wireGuardEndpointText = "1:51820"
        XCTAssertTrue(store.hasWireGuardEndpointValidationError)
        store.wireGuardAllowedIPsText = "1"
        XCTAssertTrue(store.hasWireGuardAllowedIPsValidationError)
        store.wireGuardDNSServersText = "1"
        XCTAssertTrue(store.hasWireGuardDNSServersValidationError)
        XCTAssertEqual(
            store.invalidWireGuardConnectionFields,
            Set(WireGuardConnectionField.allCases)
        )

        store.connectHostWireGuardTunnel()

        XCTAssertEqual(tunnelController.connectCallCount, 0)
        XCTAssertTrue(
            eventLog.text.contains(
                "invalid connection values (Endpoint, Allowed IPs, DNS Servers)"
            )
        )

        store.wireGuardEndpointText = "vpn.example.com:51820"
        XCTAssertFalse(store.hasWireGuardEndpointValidationError)
        store.wireGuardAllowedIPsText = "0.0.0.0/0"
        XCTAssertFalse(store.hasWireGuardAllowedIPsValidationError)
        store.wireGuardDNSServersText = "1.1.1.1, 8.8.8.8"
        XCTAssertFalse(store.hasWireGuardDNSServersValidationError)
        XCTAssertTrue(store.invalidWireGuardConnectionFields.isEmpty)

        store.wireGuardEndpointText = "invalid"
        XCTAssertTrue(store.hasWireGuardEndpointValidationError)
        store.wireGuardEndpointText = ""
        XCTAssertFalse(store.hasWireGuardEndpointValidationError)
        store.wireGuardAllowedIPsText = ""
        XCTAssertFalse(store.hasWireGuardAllowedIPsValidationError)
        store.wireGuardDNSServersText = ""
        XCTAssertFalse(store.hasWireGuardDNSServersValidationError)
        XCTAssertEqual(
            store.resolvedWireGuardDNSServers,
            ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
        )

        vmCoordinator.onConsoleOutput?(
            Data("THRURNDIS_WG_ENDPOINT=1:51820\n".utf8)
        )
        XCTAssertTrue(store.hasWireGuardEndpointValidationError)
    }

    func testPersistedInvalidConnectionValuesAreValidatedDuringInitialization() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("vpn.example.com", forKey: "WireGuard.endpointOverride")
        defaults.set("10.100.0.2/33", forKey: "WireGuard.allowedIPs")
        defaults.set("1.1.1.1,", forKey: "WireGuard.dnsServers")

        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(monitor: ObservationTestUSBMonitor()),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: EventLogStore(),
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: ObservationTestHostWireGuardTunnelController(),
            defaults: defaults
        )

        XCTAssertEqual(
            store.invalidWireGuardConnectionFields,
            Set(WireGuardConnectionField.allCases)
        )
    }

    func testConnectIsRejectedWhileVMIsNotRunning() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tunnelController = ObservationTestHostWireGuardTunnelController()
        let eventLog = EventLogStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: ObservationTestVMCoordinator(),
            usbCoordinator: USBAccessoryCoordinator(
                monitor: ObservationTestUSBMonitor()
            ),
            wireGuardConfigurationStore: ObservationTestWireGuardStore(),
            wireGuardConfigurationBuilder: WireGuardConfigurationBuilder(elements: .defaults),
            eventLog: eventLog,
            consoleSession: ConsoleSessionStore(),
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults),
            hostWireGuardTunnelController: tunnelController,
            defaults: defaults
        )

        store.connectHostWireGuardTunnel()

        XCTAssertEqual(tunnelController.connectCallCount, 0)
        XCTAssertFalse(store.canConnectHostWireGuardTunnel)
        XCTAssertTrue(eventLog.text.contains("VM is not running"))
        XCTAssertTrue(
            eventLog.text.contains(
                "Provider: Not configured — " +
                    "Start the VM and wait for its WireGuard endpoint."
            )
        )
    }

    func testResetSkipsProfileAndConfigurationRemovalWhenTunnelCannotStop() async throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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

    func testConsoleOutputOnlyInvalidatesConsoleSession() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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

        XCTAssertEqual(consoleChangeCount, 1)
        XCTAssertEqual(eventLogChangeCount, 0)
        XCTAssertEqual(storeChangeCount, 0)
        withExtendedLifetime((storeCancellable, consoleCancellable, eventLogCancellable)) {}
    }

    func testVMEventLogOnlyInvalidatesEventLogStore() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
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

        vmCoordinator.onEventLog?("VM started.")

        XCTAssertEqual(eventLogChangeCount, 1)
        XCTAssertEqual(consoleChangeCount, 0)
        XCTAssertEqual(storeChangeCount, 0)
        XCTAssertTrue(eventLog.text.contains("[VM] VM started."))
        withExtendedLifetime((storeCancellable, consoleCancellable, eventLogCancellable)) {}
    }
}

@MainActor
private final class ObservationTestVMCoordinator: VMCoordinating {
    var onStateChange: ((VMRuntimeState, String) -> Void)?
    var onEventLog: ((String) -> Void)?
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
    var canSendConsoleInput = false
    var canStart = true
    var hasVirtualMachine = false

    func start(input: VMCoordinatorStartInput) {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
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
    func sendConsoleBytes(_ data: Data) -> Bool { true }
    func invalidate() {
        invalidateCallCount += 1
    }
}

private final class ObservationTestUSBMonitor: USBAccessoryMonitoring {
    var onConnect: ((AAUSBAccessory) -> Void)?
    var onDisconnect: ((AAUSBAccessory) -> Void)?

    func start(completion: @escaping (Result<[AAUSBAccessory], Error>) -> Void) {
        completion(.success([]))
    }

    func stop(completion: (() -> Void)?) {
        completion?()
    }
}

@MainActor
private final class ObservationTestHostWireGuardTunnelController: HostWireGuardTunnelControlling {
    var onStatusChange: ((HostWireGuardTunnelStatus) -> Void)?
    var onSystemExtensionStatusChange: ((WireGuardSystemExtensionStatus) -> Void)?
    var onEventLog: ((String) -> Void)?
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastDisconnectWaitUntilStopped: Bool?
    private(set) var removeSavedTunnelCallCount = 0
    private(set) var systemExtensionStatusRefreshCallCount = 0
    private(set) var systemExtensionActivationCallCount = 0
    private(set) var systemExtensionInvalidationCallCount = 0
    var disconnectSucceeds = true
    var savedTunnelRemovalSucceeds = true

    func refreshStatus() async {}

    func refreshSystemExtensionStatus() async {
        systemExtensionStatusRefreshCallCount += 1
    }

    func activateSystemExtension() async {
        systemExtensionActivationCallCount += 1
    }

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
        return disconnectSucceeds
    }

    @discardableResult
    func removeSavedTunnelIfNeeded() async -> Bool {
        removeSavedTunnelCallCount += 1
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
