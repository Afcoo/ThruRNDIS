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

    var onEventLog: EventLogHandler?

    private let releaseService: GitHubVMAssetReleaseService
    private let downloadService: VMAssetDownloadService
    private let installService: VMAssetInstallService
    private let selectionStore: VMAssetSelectionStore
    private var eventLogErrorDescription: String?
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
        releaseService: GitHubVMAssetReleaseService,
        downloadService: VMAssetDownloadService,
        installService: VMAssetInstallService,
        selectionStore: VMAssetSelectionStore
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
            eventLogErrorDescription = EventLogErrorFormatter.description(
                for: initializationError
            )
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
        if errorMessage != nil {
            let diagnostic = eventLogErrorDescription ?? "No error diagnostic is available."
            reportEventLog(
                "VM asset state could not be loaded: \(diagnostic)",
                level: .error
            )
        } else if let currentSelection {
            switch currentSelection.source {
            case .managed:
                let name = currentSelection.managedRelease?.displayName ?? "unknown release"
                reportEventLog(
                    "Loaded selected VM asset release \(name).",
                    level: .debug
                )
            case .manual:
                reportEventLog(
                    "Loaded manually selected VM assets.",
                    level: .debug
                )
                reportEventLog(
                    "Loaded manual VM asset path: \(currentSelection.folderURL.path).",
                    level: .debug
                )
            }
        } else {
            reportEventLog("No VM assets are selected.", level: .warning)
        }

        if !installedReleases.isEmpty {
            reportEventLog(
                "Loaded \(installedReleases.count) installed VM asset release(s).",
                level: .debug
            )
        }
    }

    func installLatest() {
        guard operationTask == nil else {
            return
        }

        errorMessage = nil
        eventLogErrorDescription = nil
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
        reportEventLog(
            "Checking the latest compatible VM asset release.",
            level: .debug
        )
    }

    func cancelInstall() {
        guard let operationTask else {
            return
        }
        operationTask.cancel()
        reportEventLog(
            "VM asset installation cancellation requested.",
            level: .debug
        )
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
            eventLogErrorDescription = nil
            installState = .ready(message: readyMessage(for: selection))
            reportEventLog(
                "Selected VM assets manually.",
                level: .info
            )
            reportEventLog(
                "Selected manual VM asset path: \(selection.folderURL.path).",
                level: .debug
            )
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

    func clearSelection() {
        guard !isBusy else {
            return
        }
        selectionStore.clearSelection()
        currentSelection = nil
        errorMessage = nil
        eventLogErrorDescription = nil
        installState = .idle
        reportEventLog(
            "Cleared the VM asset selection; managed release files were preserved.",
            level: .info
        )
    }

    func clearError() {
        errorMessage = nil
        eventLogErrorDescription = nil
        guard case .failed = installState else {
            return
        }
        installState = currentSelection.map { .ready(message: readyMessage(for: $0)) } ?? .idle
    }

    func prepareForApplicationTermination() async {
        let task = operationTask
        task?.cancel()
        await task?.value
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
            let release = try await releaseService.fetchLatestCompatibleRelease()
            try requireCurrentOperation(operationID)
            let releaseName = displayName(for: release)
            reportEventLog(
                "Latest compatible VM asset release found: \(releaseName).",
                level: .debug
            )

            if let installed = try installService.installedRelease(matching: release) {
                installState = .activating
                reportEventLog(
                    "VM assets \(installed.displayName) are already installed; " +
                        "activating them.",
                    level: .debug
                )
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
            reportEventLog(
                "Downloading VM assets \(releaseName).",
                level: .debug
            )
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
            reportEventLog(
                "Downloaded VM assets \(releaseName).",
                level: .debug
            )

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
                                self.reportEventLog(
                                    "Verifying the downloaded VM assets.",
                                    level: .debug
                                )
                            }
                        case .extracting:
                            if self.installState != .extracting {
                                self.installState = .extracting
                                self.reportEventLog(
                                    "Extracting the verified VM assets.",
                                    level: .debug
                                )
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
            reportEventLog(
                "Activating VM assets \(installed.displayName).",
                level: .debug
            )
            do {
                try activate(installed)
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    removeInstalledReleaseAfterRollbackFailure(
                        installed,
                        context: "activation failure"
                    )
                }
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
                    removeInstalledReleaseAfterRollbackFailure(
                        newlyInstalledRelease,
                        context: "installation cancellation"
                    )
                }
                finishOperation(operationID)
                errorMessage = nil
                eventLogErrorDescription = nil
                installState = currentSelection.map {
                    .ready(message: String(localized: "Installation cancelled. \(readyMessage(for: $0))"))
                } ?? .idle
                reportEventLog(
                    "VM asset installation cancelled.",
                    level: .info
                )
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
            reportEventLog(
                "VM asset cleanup failed after activation: " +
                    EventLogErrorFormatter.description(for: error),
                level: .warning
            )
        }
    }

    private func finishSuccessfully(
        release: InstalledVMAssetRelease,
        message: String,
        eventMessage: String
    ) {
        errorMessage = nil
        eventLogErrorDescription = nil
        installState = .ready(message: message)
        reportEventLog(eventMessage, level: .info)
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
            eventLogErrorDescription = nil
            installState = .ready(message: readyMessage(for: selection))
            reportEventLog(
                "Updated VM asset overrides.",
                level: .info
            )
            return nil
        } catch {
            reportFailure(error)
            return error
        }
    }

    private func reportFailure(_ error: Error) {
        let message = error.localizedDescription
        let eventLogDescription = EventLogErrorFormatter.description(for: error)
        errorMessage = message
        eventLogErrorDescription = eventLogDescription
        installState = .failed(message: message)
        reportEventLog(
            "VM asset operation failed: \(eventLogDescription)",
            level: .error
        )
    }

    private func removeInstalledReleaseAfterRollbackFailure(
        _ release: InstalledVMAssetRelease,
        context: String
    ) {
        do {
            try installService.removeInstalledRelease(release)
        } catch {
            reportEventLog(
                "VM asset rollback cleanup failed after \(context): " +
                    EventLogErrorFormatter.description(for: error),
                level: .warning
            )
        }
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

    private func reportEventLog(
        _ message: String,
        level: EventLogLevel
    ) {
        onEventLog?(message, level)
    }
}

enum VMAssetWorkflowCoordinatorError: LocalizedError {
    case noSelection
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return String(localized: "Select or install VM assets first.")
        case .operationInProgress:
            return String(localized: "Wait for the current VM asset operation to finish.")
        }
    }
}
