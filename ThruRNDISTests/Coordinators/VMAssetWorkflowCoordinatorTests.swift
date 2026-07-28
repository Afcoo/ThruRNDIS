import XCTest
@testable import ThruRNDIS

@MainActor
final class VMAssetWorkflowCoordinatorTests: XCTestCase {
    func testAlreadyInstalledReleaseIsActivatedWithoutDownload() async throws {
        let release = VMAssetTestSupport.release()
        let installed = VMAssetTestSupport.installedRelease(
            at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
        )
        let releaseService = FakeReleaseService(result: .success(release))
        let downloader = FakeDownloader()
        let installer = FakeInstaller(installed: [installed], matching: installed)
        let selectionStore = FakeSelectionStore()
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: releaseService,
            downloadService: downloader,
            installService: installer,
            selectionStore: selectionStore
        )

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(downloader.callCount, 0)
        XCTAssertEqual(installer.installCount, 0)
        XCTAssertEqual(selectionStore.managedSelectionCount, 1)
        XCTAssertEqual(installer.pruneCount, 1)
        XCTAssertEqual(coordinator.installedRelease, installed)
        XCTAssertEqual(downloader.discardedOperationIDs.count, 1)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected ready state")
        }
    }

    func testReleaseFailurePreservesPreviousSelection() async throws {
        let previous = FakeSelectionStore.manualSelection
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .failure(URLError(.notConnectedToInternet))),
            downloadService: FakeDownloader(),
            installService: FakeInstaller(installed: [], matching: nil),
            selectionStore: FakeSelectionStore(initialSelection: previous)
        )

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.currentSelection, previous)
        XCTAssertNotNil(coordinator.errorMessage)
        guard case .failed = coordinator.installState else {
            return XCTFail("Expected failed state")
        }
    }

    func testDownloadCancellationPreservesSelectionAndDiscardsOperationStaging() async throws {
        let temporaryURL = try VMAssetTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let downloader = BoundaryCancellationDownloader(baseURL: temporaryURL)
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: downloader,
            installService: FakeInstaller(installed: [], matching: nil),
            selectionStore: FakeSelectionStore(initialSelection: FakeSelectionStore.manualSelection)
        )

        coordinator.installLatest()
        try await waitUntil { downloader.didStart }
        coordinator.cancelInstall()
        try await waitUntilIdle(coordinator)

        XCTAssertTrue(downloader.didDiscard)
        let stagingDirectoryURL = try XCTUnwrap(downloader.stagingDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectoryURL.path))
        XCTAssertEqual(coordinator.currentSelection, FakeSelectionStore.manualSelection)
        XCTAssertNil(coordinator.errorMessage)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected ready state after cancellation")
        }
    }

    func testReleaseCheckCancellationDoesNotBecomeFailure() async throws {
        let releaseService = URLSessionCancellationReleaseService()
        let downloader = FakeDownloader()
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: releaseService,
            downloadService: downloader,
            installService: FakeInstaller(installed: [], matching: nil),
            selectionStore: FakeSelectionStore(initialSelection: FakeSelectionStore.manualSelection)
        )

        coordinator.installLatest()
        try await waitUntil { releaseService.didStart }
        coordinator.cancelInstall()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.currentSelection, FakeSelectionStore.manualSelection)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(downloader.callCount, 0)
        XCTAssertEqual(downloader.discardedOperationIDs.count, 1)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected ready state after URLSession-shaped release cancellation")
        }
    }

    func testInstalledReleaseInventoryFailurePreservesValidRestoredSelection() {
        let inventoryError = CocoaError(.fileReadNoPermission)
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: FakeDownloader(),
            installService: FakeInstaller(
                installed: [],
                matching: nil,
                installedReleasesError: inventoryError
            ),
            selectionStore: FakeSelectionStore(initialSelection: FakeSelectionStore.manualSelection)
        )

        XCTAssertEqual(coordinator.currentSelection, FakeSelectionStore.manualSelection)
        XCTAssertTrue(coordinator.hasConfiguredAssets)
        XCTAssertTrue(coordinator.installedReleases.isEmpty)
        XCTAssertEqual(coordinator.errorMessage, inventoryError.localizedDescription)
        guard case .failed = coordinator.installState else {
            return XCTFail("Expected the inventory error to remain visible")
        }
    }

    func testActivationProtectsPreviousManualSelectionDuringPruning() async throws {
        let installed = VMAssetTestSupport.installedRelease(
            at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
        )
        let installer = FakeInstaller(installed: [installed], matching: installed)
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: FakeDownloader(),
            installService: installer,
            selectionStore: FakeSelectionStore(initialSelection: FakeSelectionStore.manualSelection)
        )

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(
            installer.protectedDirectoryURL,
            FakeSelectionStore.manualSelection.folderURL
        )
    }

    func testActivationFailureRollsBackNewInstallAndPreservesPreviousSelection() async throws {
        let installed = VMAssetTestSupport.installedRelease(
            at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
        )
        let installer = FakeInstaller(installed: [installed], matching: nil)
        let previous = FakeSelectionStore.manualSelection
        let selectionStore = FakeSelectionStore(
            initialSelection: previous,
            managedSelectionError: CocoaError(.fileWriteUnknown)
        )
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: FakeDownloader(),
            installService: installer,
            selectionStore: selectionStore
        )

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.currentSelection, previous)
        XCTAssertEqual(selectionStore.selection, previous)
        XCTAssertEqual(installer.removeCount, 1)
        XCTAssertTrue(installer.installed.isEmpty)
        guard case .failed = coordinator.installState else {
            return XCTFail("Expected failed state after activation rollback")
        }
    }

    func testCancellationDuringActivationRollsBackNewInstallAndPreservesSelection() async throws {
        let installed = VMAssetTestSupport.installedRelease(
            at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
        )
        let installer = FakeInstaller(installed: [installed], matching: nil)
        let previous = FakeSelectionStore.manualSelection
        let selectionStore = FakeSelectionStore(
            initialSelection: previous,
            managedSelectionError: CancellationError()
        )
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: FakeDownloader(),
            installService: installer,
            selectionStore: selectionStore
        )

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.currentSelection, previous)
        XCTAssertEqual(selectionStore.selection, previous)
        XCTAssertEqual(installer.removeCount, 1)
        XCTAssertTrue(installer.installed.isEmpty)
        XCTAssertNil(coordinator.errorMessage)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected ready state after activation cancellation")
        }
    }

    func testRollbackCleanupFailureDoesNotMaskActivationFailureOrCancellation() async throws {
        let scenarios: [(selectionError: Error, isCancellation: Bool, context: String)] = [
            (CocoaError(.fileWriteUnknown), false, "activation failure"),
            (CancellationError(), true, "installation cancellation"),
        ]

        for scenario in scenarios {
            let installed = VMAssetTestSupport.installedRelease(
                at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
            )
            let installer = FakeInstaller(
                installed: [installed],
                matching: nil,
                removeInstalledReleaseError: CocoaError(.fileWriteNoPermission)
            )
            let previous = FakeSelectionStore.manualSelection
            let coordinator = VMAssetWorkflowCoordinator(
                releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
                downloadService: FakeDownloader(),
                installService: installer,
                selectionStore: FakeSelectionStore(
                    initialSelection: previous,
                    managedSelectionError: scenario.selectionError
                )
            )
            var events: [(String, EventLogLevel)] = []
            coordinator.onEventLog = { events.append(($0, $1)) }

            coordinator.installLatest()
            try await waitUntilIdle(coordinator)

            XCTAssertEqual(coordinator.currentSelection, previous, scenario.context)
            XCTAssertEqual(installer.installed, [installed], scenario.context)
            XCTAssertTrue(events.contains {
                $0.1 == .warning && $0.0.contains(scenario.context)
            })
            if scenario.isCancellation {
                XCTAssertNil(coordinator.errorMessage)
                guard case .ready = coordinator.installState else {
                    return XCTFail("Cancellation outcome was masked")
                }
            } else {
                guard case .failed = coordinator.installState else {
                    return XCTFail("Activation failure was masked")
                }
            }
        }
    }

    func testDownloadedReleaseIsInstalledActivatedAndPruned() async throws {
        let installed = VMAssetTestSupport.installedRelease(
            at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
        )
        let downloader = FakeDownloader()
        let installer = FakeInstaller(installed: [installed], matching: nil)
        let selectionStore = FakeSelectionStore()
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: downloader,
            installService: installer,
            selectionStore: selectionStore
        )

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(downloader.callCount, 1)
        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(selectionStore.managedSelectionCount, 1)
        XCTAssertEqual(installer.pruneCount, 1)
        XCTAssertEqual(coordinator.installedRelease, installed)
        XCTAssertEqual(downloader.discardedOperationIDs.count, 1)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected installed release to be ready")
        }
    }

    func testClearSelectionPreservesManagedReleases() {
        let installed = VMAssetTestSupport.installedRelease(
            at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
        )
        let selectionStore = FakeSelectionStore(
            initialSelection: FakeSelectionStore.manualSelection
        )
        let installer = FakeInstaller(installed: [installed], matching: nil)
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: FakeDownloader(),
            installService: installer,
            selectionStore: selectionStore
        )

        coordinator.clearSelection()

        XCTAssertNil(coordinator.currentSelection)
        XCTAssertNil(selectionStore.selection)
        XCTAssertEqual(coordinator.installedReleases, [installed])
        XCTAssertEqual(installer.installed, [installed])
        XCTAssertEqual(coordinator.installState, .idle)
    }

    private func waitUntilIdle(_ coordinator: VMAssetWorkflowCoordinator) async throws {
        try await waitUntil { !coordinator.isBusy }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline {
                throw VMAssetWorkflowCoordinatorTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum VMAssetWorkflowCoordinatorTestError: Error {
    case timeout
}

private final class FakeReleaseService: VMAssetReleaseServing {
    let result: Result<VMAssetReleaseDescriptor, Error>

    init(result: Result<VMAssetReleaseDescriptor, Error>) {
        self.result = result
    }

    func fetchLatestRelease() async throws -> VMAssetReleaseDescriptor {
        try result.get()
    }
}

private final class URLSessionCancellationReleaseService: VMAssetReleaseServing {
    private let lock = NSLock()
    private var started = false

    var didStart: Bool {
        lock.withLock { started }
    }

    func fetchLatestRelease() async throws -> VMAssetReleaseDescriptor {
        lock.withLock {
            started = true
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cancelled)
    }
}

private final class FakeDownloader: VMAssetDownloading {
    private(set) var callCount = 0
    private(set) var discardedOperationIDs: [UUID] = []

    func download(
        release: VMAssetReleaseDescriptor,
        operationID: UUID,
        progress: @escaping (Double) -> Void
    ) async throws -> DownloadedVMAssetPackage {
        callCount += 1
        let stagingURL = URL(fileURLWithPath: "/tmp/\(operationID.uuidString)", isDirectory: true)
        return DownloadedVMAssetPackage(
            release: release,
            stagingDirectoryURL: stagingURL,
            archiveURL: stagingURL.appendingPathComponent("vm_assets.zip"),
            checksumsURL: stagingURL.appendingPathComponent("SHA256SUMS")
        )
    }

    func discardStagingData(for operationID: UUID) {
        discardedOperationIDs.append(operationID)
    }
}

private final class BoundaryCancellationDownloader: VMAssetDownloading {
    private let baseURL: URL
    private let lock = NSLock()
    private var started = false
    private var discarded = false
    private var stagedURL: URL?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    var didStart: Bool {
        lock.withLock { started }
    }

    var didDiscard: Bool {
        lock.withLock { discarded }
    }

    var stagingDirectoryURL: URL? {
        lock.withLock { stagedURL }
    }

    func download(
        release: VMAssetReleaseDescriptor,
        operationID: UUID,
        progress: @escaping (Double) -> Void
    ) async throws -> DownloadedVMAssetPackage {
        let stagingURL = baseURL.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        lock.withLock {
            stagedURL = stagingURL
            started = true
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }

        return DownloadedVMAssetPackage(
            release: release,
            stagingDirectoryURL: stagingURL,
            archiveURL: stagingURL.appendingPathComponent("vm_assets.zip"),
            checksumsURL: stagingURL.appendingPathComponent("SHA256SUMS")
        )
    }

    func discardStagingData(for operationID: UUID) {
        let stagingURL = baseURL.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: stagingURL)
        lock.withLock {
            discarded = true
        }
    }
}

private final class FakeInstaller: VMAssetInstalling {
    var installed: [InstalledVMAssetRelease]
    let matching: InstalledVMAssetRelease?
    let installedReleasesError: Error?
    let removeInstalledReleaseError: Error?
    private(set) var pruneCount = 0
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var protectedDirectoryURL: URL?

    init(
        installed: [InstalledVMAssetRelease],
        matching: InstalledVMAssetRelease?,
        installedReleasesError: Error? = nil,
        removeInstalledReleaseError: Error? = nil
    ) {
        self.installed = installed
        self.matching = matching
        self.installedReleasesError = installedReleasesError
        self.removeInstalledReleaseError = removeInstalledReleaseError
    }

    func installedRelease(matching release: VMAssetReleaseDescriptor) throws -> InstalledVMAssetRelease? {
        matching
    }

    func installedReleases() throws -> [InstalledVMAssetRelease] {
        if let installedReleasesError {
            throw installedReleasesError
        }
        return installed
    }

    func install(
        package: DownloadedVMAssetPackage,
        progress: @escaping (VMAssetInstallStage) -> Void
    ) async throws -> InstalledVMAssetRelease {
        installCount += 1
        guard let release = installed.first else {
            throw URLError(.fileDoesNotExist)
        }
        progress(.verifying)
        progress(.extracting)
        return release
    }

    func removeInstalledRelease(_ release: InstalledVMAssetRelease) throws {
        removeCount += 1
        if let removeInstalledReleaseError {
            throw removeInstalledReleaseError
        }
        installed.removeAll { $0 == release }
    }

    func pruneInstalledReleases(
        keeping release: InstalledVMAssetRelease,
        preserving protectedDirectoryURL: URL?
    ) throws {
        pruneCount += 1
        self.protectedDirectoryURL = protectedDirectoryURL
        installed = installed.filter { $0 == release }
    }
}

private final class FakeSelectionStore: VMAssetSelectionStoring {
    static let manualSelection = VMAssetSelection(
        source: .manual,
        folderURL: URL(fileURLWithPath: "/manual/vm_assets", isDirectory: true),
        kernelURL: URL(fileURLWithPath: "/manual/vm_assets/Image-lts"),
        initialRamdiskURL: URL(fileURLWithPath: "/manual/vm_assets/initramfs-thrurndis-lts"),
        kernelOverrideURL: nil,
        initialRamdiskOverrideURL: nil,
        managedRelease: nil
    )

    var selection: VMAssetSelection?
    let managedSelectionError: Error?
    private(set) var managedSelectionCount = 0

    init(
        initialSelection: VMAssetSelection? = nil,
        managedSelectionError: Error? = nil
    ) {
        selection = initialSelection
        self.managedSelectionError = managedSelectionError
    }

    func restoreSelection() throws -> VMAssetSelection? {
        selection
    }

    func selectManualFolder(_ directoryURL: URL) throws -> VMAssetSelection {
        Self.manualSelection
    }

    func selectManagedRelease(_ release: InstalledVMAssetRelease) throws -> VMAssetSelection {
        if let managedSelectionError {
            throw managedSelectionError
        }
        managedSelectionCount += 1
        let selection = VMAssetSelection(
            source: .managed,
            folderURL: release.assetFolderURL,
            kernelURL: release.assetFolderURL.appendingPathComponent("Image-lts"),
            initialRamdiskURL: release.assetFolderURL.appendingPathComponent("initramfs-thrurndis-lts"),
            kernelOverrideURL: nil,
            initialRamdiskOverrideURL: nil,
            managedRelease: release
        )
        self.selection = selection
        return selection
    }

    func setKernelOverride(_ url: URL?, for selection: VMAssetSelection) throws -> VMAssetSelection {
        selection
    }

    func setInitialRamdiskOverride(_ url: URL?, for selection: VMAssetSelection) throws -> VMAssetSelection {
        selection
    }

    func validate(_ selection: VMAssetSelection) throws -> VMAssetBootAssets {
        VMAssetBootAssets(
            kernelURL: selection.effectiveKernelURL,
            initialRamdiskURL: selection.effectiveInitialRamdiskURL
        )
    }

    func clearSelection() {
        selection = nil
    }
}
