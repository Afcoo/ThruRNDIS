import Combine
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
        var busyValuesAtStateChanges: [Bool] = []
        let stateCancellable = coordinator.$installState
            .dropFirst()
            .sink { _ in
                busyValuesAtStateChanges.append(coordinator.isBusy)
            }

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(downloader.callCount, 0)
        XCTAssertEqual(selectionStore.managedSelectionCount, 1)
        XCTAssertEqual(installer.pruneCount, 1)
        XCTAssertEqual(coordinator.installedRelease, installed)
        XCTAssertEqual(busyValuesAtStateChanges.last, false)
        XCTAssertTrue(busyValuesAtStateChanges.dropLast().allSatisfy { $0 })
        XCTAssertEqual(downloader.discardedOperationIDs.count, 1)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected ready state")
        }
        withExtendedLifetime(stateCancellable) {}
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
        guard case .failed = coordinator.installState else {
            return XCTFail("Expected failed state")
        }
    }

    func testCancellationRestoresReadyStateForExistingSelection() async throws {
        let selectionStore = FakeSelectionStore(initialSelection: FakeSelectionStore.manualSelection)
        let downloader = FakeDownloader(shouldSuspend: true)
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: downloader,
            installService: FakeInstaller(installed: [], matching: nil),
            selectionStore: selectionStore
        )

        coordinator.installLatest()
        try await waitUntil { downloader.callCount == 1 }
        coordinator.cancelInstall()
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.currentSelection, FakeSelectionStore.manualSelection)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(downloader.discardedOperationIDs.count, 1)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected ready state after cancellation")
        }
    }

    func testCancellationAfterDownloadBoundaryDiscardsOperationStaging() async throws {
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
        if let stagingDirectoryURL = downloader.stagingDirectoryURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectoryURL.path))
        } else {
            XCTFail("Expected the fake downloader to create operation staging")
        }
    }

    func testCancelledReleaseRequestReportingURLErrorRestoresReadyState() async throws {
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

    func testCancelledDownloadReportingURLErrorRestoresReadyState() async throws {
        let downloader = URLSessionCancellationDownloader()
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

        XCTAssertEqual(coordinator.currentSelection, FakeSelectionStore.manualSelection)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(downloader.discardedOperationIDs.count, 1)
        guard case .ready = coordinator.installState else {
            return XCTFail("Expected ready state after URLSession-shaped download cancellation")
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

    func testInstallEmitsHighSignalStageEvents() async throws {
        let installed = VMAssetTestSupport.installedRelease(
            at: URL(fileURLWithPath: "/managed/42-100", isDirectory: true)
        )
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: FakeDownloader(),
            installService: FakeInstaller(installed: [installed], matching: nil),
            selectionStore: FakeSelectionStore()
        )
        var events: [String] = []
        coordinator.onEventLog = { events.append($0) }

        coordinator.installLatest()
        try await waitUntilIdle(coordinator)
        await Task.yield()

        XCTAssertTrue(events.contains { $0.contains("Checking the latest VM asset release") })
        XCTAssertTrue(events.contains { $0.contains("Downloading VM assets") })
        XCTAssertTrue(events.contains { $0.contains("Downloaded VM assets") })
        XCTAssertTrue(events.contains { $0.contains("Verifying the downloaded VM assets") })
        XCTAssertTrue(events.contains { $0.contains("Extracting the verified VM assets") })
        XCTAssertTrue(events.contains { $0.contains("Activating VM assets") })
        XCTAssertTrue(events.contains { $0.contains("Installed and activated VM assets") })
    }

    func testCurrentStateReportIncludesRestoredManualSelection() {
        let coordinator = VMAssetWorkflowCoordinator(
            releaseService: FakeReleaseService(result: .success(VMAssetTestSupport.release())),
            downloadService: FakeDownloader(),
            installService: FakeInstaller(installed: [], matching: nil),
            selectionStore: FakeSelectionStore(initialSelection: FakeSelectionStore.manualSelection)
        )
        var events: [String] = []
        coordinator.onEventLog = { events.append($0) }

        coordinator.reportCurrentStateToEventLog()

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].contains(FakeSelectionStore.manualSelection.folderURL.path))
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
    let shouldSuspend: Bool

    init(shouldSuspend: Bool = false) {
        self.shouldSuspend = shouldSuspend
    }

    func download(
        release: VMAssetReleaseDescriptor,
        operationID: UUID,
        progress: @escaping (Double) -> Void
    ) async throws -> DownloadedVMAssetPackage {
        callCount += 1
        if shouldSuspend {
            try await Task.sleep(for: .seconds(30))
        }
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

private final class URLSessionCancellationDownloader: VMAssetDownloading {
    private let lock = NSLock()
    private var started = false
    private var discardedOperationIDsStorage: [UUID] = []

    var didStart: Bool {
        lock.withLock { started }
    }

    var discardedOperationIDs: [UUID] {
        lock.withLock { discardedOperationIDsStorage }
    }

    func download(
        release: VMAssetReleaseDescriptor,
        operationID: UUID,
        progress: @escaping (Double) -> Void
    ) async throws -> DownloadedVMAssetPackage {
        lock.withLock {
            started = true
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cancelled)
    }

    func discardStagingData(for operationID: UUID) {
        lock.withLock {
            discardedOperationIDsStorage.append(operationID)
        }
    }
}

private final class FakeInstaller: VMAssetInstalling {
    var installed: [InstalledVMAssetRelease]
    let matching: InstalledVMAssetRelease?
    let installedReleasesError: Error?
    private(set) var pruneCount = 0
    private(set) var protectedDirectoryURL: URL?

    init(
        installed: [InstalledVMAssetRelease],
        matching: InstalledVMAssetRelease?,
        installedReleasesError: Error? = nil
    ) {
        self.installed = installed
        self.matching = matching
        self.installedReleasesError = installedReleasesError
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
        guard let release = installed.first else {
            throw URLError(.fileDoesNotExist)
        }
        progress(.verifying)
        progress(.extracting)
        return release
    }

    func removeInstalledRelease(_ release: InstalledVMAssetRelease) throws {
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
    private(set) var managedSelectionCount = 0

    init(initialSelection: VMAssetSelection? = nil) {
        selection = initialSelection
    }

    func restoreSelection() throws -> VMAssetSelection? {
        selection
    }

    func selectManualFolder(_ directoryURL: URL) throws -> VMAssetSelection {
        Self.manualSelection
    }

    func selectManagedRelease(_ release: InstalledVMAssetRelease) throws -> VMAssetSelection {
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
