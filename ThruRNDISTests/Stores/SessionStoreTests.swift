import AccessoryAccess
import Combine
import XCTest
@preconcurrency import Virtualization
@testable import ThruRNDIS

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
    func testConsoleOutputOnlyInvalidatesConsoleSession() throws {
        let suiteName = "TetheringStoreObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vmCoordinator = ObservationTestVMCoordinator()
        let consoleSession = ConsoleSessionStore()
        let store = TetheringStore(
            assetProvider: ObservationTestAssetProvider(),
            vmCoordinator: vmCoordinator,
            usbCoordinator: USBAccessoryCoordinator(
                monitor: ObservationTestUSBMonitor()
            ),
            wireGuardConfStore: ObservationTestWireGuardStore(),
            wireGuardConfBuilder: WireGuardConfBuilder(elements: .defaults),
            consoleSession: consoleSession,
            usbSession: USBSessionStore(),
            vmConfiguration: VMConfigurationStore(defaults: defaults)
        )
        var storeChangeCount = 0
        var consoleChangeCount = 0
        let storeCancellable = store.objectWillChange.sink {
            storeChangeCount += 1
        }
        let consoleCancellable = consoleSession.objectWillChange.sink {
            consoleChangeCount += 1
        }

        vmCoordinator.onConsoleOutput?(Data("guest output".utf8))

        XCTAssertEqual(consoleChangeCount, 1)
        XCTAssertEqual(storeChangeCount, 0)
        withExtendedLifetime((storeCancellable, consoleCancellable)) {}
    }
}

@MainActor
private final class ObservationTestVMCoordinator: VMCoordinating {
    var onStateChange: ((VMRuntimeState, String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onConsoleOutput: ((Data) -> Void)?
    var onUSBPassthroughDisconnect: ((VZUSBPassthroughDevice) -> Void)?
    var onStopped: (() -> Void)?

    var runtimeState: VMRuntimeState = .idle
    var virtualMachine: VZVirtualMachine?
    var canStop = false
    var canRestart = false
    var canSendConsoleInput = false
    var canStart = true
    var hasVirtualMachine = false

    func start(input: VMCoordinatorStartInput) {}
    func stop() {}
    func restart(reason: String, startAgain: @escaping () -> Void) {}
    func sendConsoleBytes(_ data: Data) -> Bool { true }
    func invalidate() {}
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

private struct ObservationTestWireGuardStore: WireGuardConfigurationStoring {
    let files: WireGuardConfigurationFiles

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
        builder: WireGuardConfBuilder
    ) throws -> PreparedWireGuardConfiguration {
        preparedConfiguration()
    }

    func requireExistingConfiguration(
        builder: WireGuardConfBuilder
    ) throws -> PreparedWireGuardConfiguration {
        preparedConfiguration()
    }

    func removeConfigurationDirectory() throws {}

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
