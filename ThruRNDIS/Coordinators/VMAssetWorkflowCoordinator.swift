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

    var onEventLog: ((String) -> Void)?

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

    func reportCurrentStateToEventLog() {
        if let errorMessage {
            onEventLog?("VM asset state could not be loaded: \(errorMessage)")
        } else if let currentSelection {
            switch currentSelection.source {
            case .managed:
                let name = currentSelection.managedRelease?.displayName ?? "unknown release"
                onEventLog?("Loaded selected VM asset release \(name).")
            case .manual:
                onEventLog?("Loaded manually selected VM assets: \(currentSelection.folderURL.path).")
            }
        } else {
            onEventLog?("No VM assets are selected.")
        }

        if !installedReleases.isEmpty {
            onEventLog?("Loaded \(installedReleases.count) installed VM asset release(s).")
        }
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
        onEventLog?("Checking the latest VM asset release.")
    }

    func cancelInstall() {
        guard let operationTask else {
            return
        }
        operationTask.cancel()
        onEventLog?("VM asset installation cancellation requested.")
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
            onEventLog?("Selected VM assets manually: \(selection.folderURL.path).")
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
            onEventLog?("Activated installed VM asset release \(release.displayName).")
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
        onEventLog?("Cleared the VM asset selection; managed release files were preserved.")
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
            let releaseName = displayName(for: release)
            onEventLog?("Latest VM asset release found: \(releaseName).")

            if let installed = try installService.installedRelease(matching: release) {
                installState = .activating
                onEventLog?("VM assets \(installed.displayName) are already installed; activating them.")
                try activate(installed)
                try requireMatchingOperation(operationID)
                downloadService.discardStagingData(for: operationID)
                didDiscardStaging = true
                finishOperation(operationID)
                finishSuccessfully(
                    release: installed,
                    message: String(localized: "VM assets \(installed.displayName) are already installed and ready."),
                    eventMessage: "VM assets \(installed.displayName) are already installed and ready."
                )
                return
            }

            installState = .downloading(progress: 0)
            onEventLog?("Downloading VM assets \(releaseName).")
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
            onEventLog?("Downloaded VM assets \(releaseName).")

            let installed = try await installService.install(
                package: package,
                progress: { [weak self] stage in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == operationID else {
                            return
                        }
                        switch stage {
                        case .verifying:
                            if self.installState != .verifying {
                                self.installState = .verifying
                                self.onEventLog?("Verifying the downloaded VM assets.")
                            }
                        case .extracting:
                            if self.installState != .extracting {
                                self.installState = .extracting
                                self.onEventLog?("Extracting the verified VM assets.")
                            }
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
            onEventLog?("Activating VM assets \(installed.displayName).")
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
                message: String(localized: "Installed and activated VM assets \(installed.displayName)."),
                eventMessage: "Installed and activated VM assets \(installed.displayName)."
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
                    .ready(message: String(localized: "Installation cancelled. \(readyMessage(for: $0))"))
                } ?? .idle
                onEventLog?("VM asset installation cancelled.")
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
            onEventLog?("VM asset cleanup failed after activation: \(error.localizedDescription)")
        }
    }

    private func finishSuccessfully(
        release: InstalledVMAssetRelease,
        message: String,
        eventMessage: String
    ) {
        errorMessage = nil
        installState = .ready(message: message)
        onEventLog?(eventMessage)
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
            onEventLog?("Updated VM asset overrides.")
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
        onEventLog?("VM asset operation failed: \(message)")
    }

    private func readyMessage(for selection: VMAssetSelection) -> String {
        if let release = selection.managedRelease {
            return String(localized: "VM assets \(release.displayName) are ready.")
        }
        return String(localized: "Manually selected VM assets are ready.")
    }

    private func displayName(for release: VMAssetReleaseDescriptor) -> String {
        release.tagName.isEmpty ? "release \(release.id)" : release.tagName
    }
}

enum VMAssetWorkflowCoordinatorError: LocalizedError {
    case noSelection
    case noInstalledRelease
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return String(localized: "Select or install VM assets first.")
        case .noInstalledRelease:
            return String(localized: "No managed VM asset release is installed.")
        case .operationInProgress:
            return String(localized: "Wait for the current VM asset operation to finish.")
        }
    }
}
