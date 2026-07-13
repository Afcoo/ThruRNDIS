/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

@MainActor
final class VMAssetWorkflowCoordinator: ObservableObject, VMAssetProviding {
    @Published private(set) var currentSelection: VMAssetSelection?
    @Published private(set) var installedReleases: [InstalledVMAssetRelease] = []
    @Published private(set) var installState: VMAssetInstallState = .idle
    @Published private(set) var errorMessage: String?

    var onEvent: ((String) -> Void)?

    private let releaseService: VMAssetReleaseServing
    private let downloadService: VMAssetDownloading
    private let installService: VMAssetInstalling
    private let selectionStore: VMAssetSelectionStoring
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?

    convenience init() {
        let fileManager = FileManager.default
        let layout = VMAssetStorageLayout(fileManager: fileManager)
        let resolver = VMAssetFolderResolver(fileManager: fileManager)
        self.init(
            releaseService: GitHubVMAssetReleaseService(),
            downloadService: VMAssetDownloadService(
                fileManager: fileManager,
                layout: layout
            ),
            installService: VMAssetInstallService(
                fileManager: fileManager,
                layout: layout,
                resolver: resolver
            ),
            selectionStore: VMAssetSelectionStore(resolver: resolver)
        )
    }

    init(
        releaseService: VMAssetReleaseServing,
        downloadService: VMAssetDownloading,
        installService: VMAssetInstalling,
        selectionStore: VMAssetSelectionStoring
    ) {
        self.releaseService = releaseService
        self.downloadService = downloadService
        self.installService = installService
        self.selectionStore = selectionStore

        var initializationError: Error?
        do {
            let restoredSelection = try selectionStore.restoreSelection()
            if let restoredSelection {
                _ = try selectionStore.validate(restoredSelection)
            }
            currentSelection = restoredSelection
        } catch {
            currentSelection = nil
            initializationError = error
        }

        do {
            installedReleases = try installService.installedReleases()
        } catch {
            installedReleases = []
            if initializationError == nil {
                initializationError = error
            }
        }

        if let initializationError {
            errorMessage = initializationError.localizedDescription
            installState = .failed(message: initializationError.localizedDescription)
        } else if let currentSelection {
            installState = .ready(message: readyMessage(for: currentSelection))
        }
    }

    var hasConfiguredAssets: Bool {
        guard let currentSelection else {
            return false
        }
        return (try? selectionStore.validate(currentSelection)) != nil
    }

    var isBusy: Bool {
        operationTask != nil
    }

    var selectedFolderURL: URL? {
        currentSelection?.folderURL
    }

    var kernelURL: URL? {
        currentSelection?.effectiveKernelURL
    }

    var initialRamdiskURL: URL? {
        currentSelection?.effectiveInitialRamdiskURL
    }

    var kernelOverrideURL: URL? {
        currentSelection?.kernelOverrideURL
    }

    var initialRamdiskOverrideURL: URL? {
        currentSelection?.initialRamdiskOverrideURL
    }

    var installedRelease: InstalledVMAssetRelease? {
        currentSelection?.managedRelease
    }

    func validatedBootAssets() throws -> VMAssetBootAssets {
        guard let currentSelection else {
            throw VMAssetWorkflowCoordinatorError.noSelection
        }
        return try selectionStore.validate(currentSelection)
    }

    func installLatest() {
        guard operationTask == nil else {
            return
        }

        errorMessage = nil
        let operationID = UUID()
        self.operationID = operationID
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runLatestInstall(operationID: operationID)
        }
        operationTask = task
        installState = .checking
    }

    func cancelInstall() {
        guard let operationTask else {
            return
        }
        operationTask.cancel()
        onEvent?("VM asset installation cancellation requested.")
    }

    @discardableResult
    func selectManualFolder(_ directoryURL: URL) -> Error? {
        guard !isBusy else {
            return VMAssetWorkflowCoordinatorError.operationInProgress
        }
        do {
            let selection = try selectionStore.selectManualFolder(directoryURL)
            currentSelection = selection
            errorMessage = nil
            installState = .ready(message: readyMessage(for: selection))
            onEvent?("Selected VM assets manually: \(selection.folderURL.path).")
            return nil
        } catch {
            reportFailure(error)
            return error
        }
    }

    @discardableResult
    func setKernelOverride(_ url: URL?) -> Error? {
        updateSelection { selection in
            try selectionStore.setKernelOverride(url, for: selection)
        }
    }

    @discardableResult
    func setInitialRamdiskOverride(_ url: URL?) -> Error? {
        updateSelection { selection in
            try selectionStore.setInitialRamdiskOverride(url, for: selection)
        }
    }

    @discardableResult
    func useMostRecentInstalledAssets() -> Error? {
        guard !isBusy else {
            return VMAssetWorkflowCoordinatorError.operationInProgress
        }
        do {
            installedReleases = try installService.installedReleases()
            guard let release = installedReleases.first else {
                throw VMAssetWorkflowCoordinatorError.noInstalledRelease
            }
            let selection = try selectionStore.selectManagedRelease(release)
            currentSelection = selection
            errorMessage = nil
            installState = .ready(message: readyMessage(for: selection))
            onEvent?("Activated installed VM asset release \(release.displayName).")
            return nil
        } catch {
            reportFailure(error)
            return error
        }
    }

    func clearSelection() {
        guard !isBusy else {
            return
        }
        selectionStore.clearSelection()
        currentSelection = nil
        errorMessage = nil
        installState = .idle
        onEvent?("Cleared the VM asset selection; managed release files were preserved.")
    }

    func clearError() {
        errorMessage = nil
        guard case .failed = installState else {
            return
        }
        installState = currentSelection.map { .ready(message: readyMessage(for: $0)) } ?? .idle
    }

    func prepareForApplicationTermination() {
        operationTask?.cancel()
    }

    private func runLatestInstall(operationID: UUID) async {
        var newlyInstalledRelease: InstalledVMAssetRelease?
        var didDiscardStaging = false
        defer {
            if !didDiscardStaging {
                downloadService.discardStagingData(for: operationID)
            }
        }

        do {
            let release = try await releaseService.fetchLatestRelease()
            try requireCurrentOperation(operationID)

            if let installed = try installService.installedRelease(matching: release) {
                installState = .activating
                try activate(installed)
                try requireMatchingOperation(operationID)
                downloadService.discardStagingData(for: operationID)
                didDiscardStaging = true
                finishOperation(operationID)
                finishSuccessfully(
                    release: installed,
                    message: "VM assets \(installed.displayName) are already installed and ready."
                )
                return
            }

            installState = .downloading(progress: 0)
            let package = try await downloadService.download(
                release: release,
                operationID: operationID,
                progress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.operationID == operationID,
                              !Task.isCancelled else {
                            return
                        }
                        self.installState = .downloading(progress: progress)
                    }
                }
            )
            try requireCurrentOperation(operationID)

            let installed = try await installService.install(
                package: package,
                progress: { [weak self] stage in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == operationID else {
                            return
                        }
                        switch stage {
                        case .verifying:
                            self.installState = .verifying
                        case .extracting:
                            self.installState = .extracting
                        }
                    }
                }
            )
            newlyInstalledRelease = installed
            // A successful installer return is the atomic promotion commit point.
            // Cancellation before it is surfaced by the installer and rolled back;
            // cancellation after it must not delete a replacement whose backup was
            // already committed.
            try requireMatchingOperation(operationID)

            installState = .activating
            do {
                try activate(installed)
            } catch {
                try? installService.removeInstalledRelease(installed)
                throw error
            }
            try requireMatchingOperation(operationID)
            downloadService.discardStagingData(for: operationID)
            didDiscardStaging = true
            finishOperation(operationID)
            finishSuccessfully(
                release: installed,
                message: "Installed and activated VM assets \(installed.displayName)."
            )
        } catch {
            guard self.operationID == operationID else {
                return
            }
            downloadService.discardStagingData(for: operationID)
            didDiscardStaging = true

            if Task.isCancelled || error is CancellationError {
                if let newlyInstalledRelease,
                   currentSelection?.managedRelease != newlyInstalledRelease {
                    try? installService.removeInstalledRelease(newlyInstalledRelease)
                }
                finishOperation(operationID)
                errorMessage = nil
                installState = currentSelection.map {
                    .ready(message: "Installation cancelled. \(readyMessage(for: $0))")
                } ?? .idle
                onEvent?("VM asset installation cancelled.")
                return
            }

            finishOperation(operationID)
            reportFailure(error)
        }
    }

    private func activate(_ release: InstalledVMAssetRelease) throws {
        let protectedManualDirectoryURL = currentSelection?.source == .manual
            ? currentSelection?.folderURL
            : nil
        let inventory = (try? installService.installedReleases()) ?? [release]
        let selection = try selectionStore.selectManagedRelease(release)
        currentSelection = selection
        installedReleases = inventory
        do {
            try installService.pruneInstalledReleases(
                keeping: release,
                preserving: protectedManualDirectoryURL
            )
            installedReleases = try installService.installedReleases()
        } catch {
            onEvent?("VM asset cleanup failed after activation: \(error.localizedDescription)")
        }
    }

    private func finishSuccessfully(
        release: InstalledVMAssetRelease,
        message: String
    ) {
        errorMessage = nil
        installState = .ready(message: message)
        onEvent?(message)
    }

    private func finishOperation(_ operationID: UUID) {
        guard self.operationID == operationID else {
            return
        }
        self.operationID = nil
        operationTask = nil
    }

    private func requireCurrentOperation(_ operationID: UUID) throws {
        try Task.checkCancellation()
        try requireMatchingOperation(operationID)
    }

    private func requireMatchingOperation(_ operationID: UUID) throws {
        guard self.operationID == operationID else {
            throw CancellationError()
        }
    }

    @discardableResult
    private func updateSelection(
        _ update: (VMAssetSelection) throws -> VMAssetSelection
    ) -> Error? {
        guard !isBusy else {
            return VMAssetWorkflowCoordinatorError.operationInProgress
        }
        guard let currentSelection else {
            let error = VMAssetWorkflowCoordinatorError.noSelection
            reportFailure(error)
            return error
        }
        do {
            let selection = try update(currentSelection)
            self.currentSelection = selection
            errorMessage = nil
            installState = .ready(message: readyMessage(for: selection))
            onEvent?("Updated VM asset overrides.")
            return nil
        } catch {
            reportFailure(error)
            return error
        }
    }

    private func reportFailure(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        installState = .failed(message: message)
        onEvent?("VM asset operation failed: \(message)")
    }

    private func readyMessage(for selection: VMAssetSelection) -> String {
        if let release = selection.managedRelease {
            return "VM assets \(release.displayName) are ready."
        }
        return "Manually selected VM assets are ready."
    }
}

enum VMAssetWorkflowCoordinatorError: LocalizedError {
    case noSelection
    case noInstalledRelease
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return "Select or install VM assets first."
        case .noInstalledRelease:
            return "No managed VM asset release is installed."
        case .operationInProgress:
            return "Wait for the current VM asset operation to finish."
        }
    }
}
