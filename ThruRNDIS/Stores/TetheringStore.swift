/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

struct OnboardingPresentationRequest {
    let sequence: Int
    let restart: Bool
}
private enum TetheringApplicationState: Equatable {
    case active
    case resetting
    case terminating
}

private enum TetheringVMRestartState: Equatable {
    case idle
    case stopping
    case starting
}

private enum AccessoryMonitoringConfigurationBlocker {
    case onboardingIncomplete
    case vmAssetsUnavailable
    case privilegedHelperUnavailable

    var statusMessage: String {
        switch self {
        case .onboardingIncomplete:
            String(localized: "Complete onboarding before starting the USB listener.")
        case .vmAssetsUnavailable:
            String(localized: "Install or select valid VM assets before starting the USB listener.")
        case .privilegedHelperUnavailable:
            String(localized: "Install and enable the network route helper before starting the USB listener.")
        }
    }

    var eventLogDescription: String {
        switch self {
        case .onboardingIncomplete:
            "onboarding is incomplete"
        case .vmAssetsUnavailable:
            "no valid VM assets are selected"
        case .privilegedHelperUnavailable:
            "the network route helper is not enabled"
        }
    }
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private var vmRestartState: TetheringVMRestartState = .idle
    @Published private(set) var statusMessage =
        String(localized: "Install or select VM assets to begin.")
    @Published private(set) var runtimeEntitlements: RuntimeEntitlementSnapshot
    @Published private var applicationState: TetheringApplicationState = .active
    @Published private(set) var isOnboardingPresented = false
    @Published private(set) var onboardingPresentationRequest =
        OnboardingPresentationRequest(sequence: 0, restart: false)
    @Published private(set) var resetStatusMessage = ""

    let guestMACAddress = "02:00:5E:10:00:02"
    let eventLog: EventLogStore
    let consoleSession: ConsoleSessionStore
    let usbSession: USBSessionStore
    let vmConfiguration: VMConfigurationStore
    let appPreferences: AppPreferencesStore
    let networkRoute: NetworkRouteStore

    private let vmCoordinator: VMCoordinator
    private let usbCoordinator: USBAccessoryCoordinator
    private let assetProvider: VMAssetProviding
    private let runtimeEntitlementSnapshotProvider: () -> RuntimeEntitlementSnapshot
    private var didRequestLaunchAccessoryMonitoring = false
    private var shouldRunAccessoryMonitoring = false
    private var accessoryMonitoringStartCancellables: Set<AnyCancellable> = []

    private lazy var workflowCoordinator = TetheringWorkflowCoordinator(
        assetProvider: assetProvider,
        vmCoordinator: vmCoordinator,
        usbCoordinator: usbCoordinator,
        eventLog: eventLog,
        usbSession: usbSession,
        actions: TetheringWorkflowCoordinator.Actions(
            canPresentUSBAttachmentPrompt: { [weak self] in
                guard let self else { return false }
                return self.acceptsNewWork
                    && !self.isResettingAppSettings
                    && !self.isOnboardingPresented
                    && !self.restartWillStartVM
            },
            startVirtualMachine: { [weak self] in
                self?.startVirtualMachine() == true
            },
            updateStatusMessage: { [weak self] message in
                self?.statusMessage = message
            },
            workflowStateDidChange: { [weak self] in
                self?.objectWillChange.send()
            }
        )
    )

    init(
        assetProvider: VMAssetProviding,
        vmCoordinator: VMCoordinator,
        usbCoordinator: USBAccessoryCoordinator,
        eventLog: EventLogStore,
        consoleSession: ConsoleSessionStore,
        usbSession: USBSessionStore,
        vmConfiguration: VMConfigurationStore,
        appPreferences: AppPreferencesStore,
        networkRoute: NetworkRouteStore,
        runtimeEntitlementSnapshotProvider: @escaping () -> RuntimeEntitlementSnapshot = {
            .current
        }
    ) {
        self.assetProvider = assetProvider
        self.vmCoordinator = vmCoordinator
        self.usbCoordinator = usbCoordinator
        self.eventLog = eventLog
        self.consoleSession = consoleSession
        self.usbSession = usbSession
        self.vmConfiguration = vmConfiguration
        self.appPreferences = appPreferences
        self.networkRoute = networkRoute
        self.runtimeEntitlementSnapshotProvider = runtimeEntitlementSnapshotProvider
        runtimeEntitlements = runtimeEntitlementSnapshotProvider()

        configureCoordinators()
        configureAccessoryMonitoringStartObservation()
        appendRuntimeEntitlementSummary()
        appendScratchDiskSelectionSummaryIfNeeded()
    }

    var isRestartingVirtualMachine: Bool {
        vmRestartState != .idle
    }

    var isResettingAppSettings: Bool {
        applicationState == .resetting
    }

    private var acceptsNewWork: Bool {
        applicationState == .active
    }

    private var isPreparingForApplicationTermination: Bool {
        applicationState == .terminating
    }

    private var restartWillStartVM: Bool {
        vmRestartState == .stopping
    }

    var accessories: [USBAccessoryRecord] { usbSession.accessories }
    var isAccessoryMonitoring: Bool { usbSession.isAccessoryMonitoring }
    var selectedAccessoryID: UInt64? { usbSession.selectedAccessoryID }
    var attachedAccessoryID: UInt64? { usbSession.attachedAccessoryID }
    var vmSessionAccessoryID: UInt64? { usbSession.vmSessionAccessoryID }
    var usbAttachmentPrompt: USBAttachmentPrompt? { usbSession.attachmentPrompt }

    var vmDisplayState: VMDisplayState {
        if isRestartingVirtualMachine {
            return .restarting
        }
        return switch runtimeState {
        case .starting, .running:
            .running
        case .idle, .stopping, .stopped, .failed:
            .stopped
        }
    }

    var canStartVirtualMachine: Bool {
        acceptsNewWork
            && hasConfiguredVMAssets
            && !assetProvider.isBusy
            && vmCoordinator.canStart
    }

    var canRestartVirtualMachine: Bool {
        acceptsNewWork
            && hasConfiguredVMAssets
            && !assetProvider.isBusy
            && !workflowCoordinator.hasPendingAttachment
            && vmCoordinator.canRestart
    }

    var canEditVMConfiguration: Bool {
        acceptsNewWork
            && !vmCoordinator.hasVirtualMachine
            && (runtimeState == .idle
                || runtimeState == .stopped
                || runtimeState == .failed)
    }

    var canResetAppSettings: Bool {
        acceptsNewWork
            && !assetProvider.isBusy
            && !networkRoute.isOperationInProgress
    }

    var hasConfiguredVMAssets: Bool { assetProvider.hasConfiguredAssets }
    var shouldPresentOnboardingOnLaunch: Bool {
        !appPreferences.hasCompletedOnboarding
    }

    var isApplicationConfigured: Bool {
        appPreferences.hasCompletedOnboarding
            && hasConfiguredVMAssets
            && isNetworkRouteHelperReady
    }

    var canStartAccessoryMonitoring: Bool {
        acceptsNewWork
            && accessoryMonitoringConfigurationBlocker == nil
            && runtimeEntitlements.accessoryAccessUSB
            && usbCoordinator.canStartMonitoring
    }

    var canStopAccessoryMonitoring: Bool {
        acceptsNewWork
            && !workflowCoordinator.hasPendingAttachment
            && usbCoordinator.canStopMonitoring
    }

    var canReloadAccessoryMonitoring: Bool {
        acceptsNewWork
            && accessoryMonitoringConfigurationBlocker == nil
            && !workflowCoordinator.hasPendingAttachment
            && runtimeEntitlements.accessoryAccessUSB
            && usbCoordinator.canReloadMonitoring
    }

    var canStopVirtualMachine: Bool {
        acceptsNewWork && vmCoordinator.canStop
    }

    var canSendConsoleInput: Bool {
        acceptsNewWork && vmCoordinator.canSendConsoleInput
    }

    var canAttachSelectedAccessory: Bool {
        guard acceptsNewWork,
              !isOnboardingPresented,
              hasConfiguredVMAssets,
              isNetworkRouteHelperReady,
              !assetProvider.isBusy,
              !workflowCoordinator.hasPendingAttachment,
              vmSessionAccessoryID == nil,
              !workflowCoordinator.attachmentRequiresVMStopRetry,
              let selectedAccessoryID else {
            return false
        }
        return usbCoordinator.canRequestAttachment(for: selectedAccessoryID)
    }

    var canDetachAccessory: Bool {
        acceptsNewWork
            && usbCoordinator.canDetachAccessory(runtimeState: runtimeState)
    }

    func canChooseAccessoryForAttachment(_ accessoryID: UInt64) -> Bool {
        acceptsNewWork
            && isNetworkRouteHelperReady
            && !workflowCoordinator.hasPendingAttachment
            && usbAttachmentPrompt == nil
            && vmSessionAccessoryID == nil
            && !workflowCoordinator.attachmentRequiresVMStopRetry
            && !assetProvider.isBusy
            && usbCoordinator.canRequestAttachment(for: accessoryID)
    }

    var shouldConfirmApplicationTermination: Bool {
        attachedAccessoryID != nil
            || networkRoute.snapshot?.state == .active
            || networkRoute.snapshot?.state == .degraded
    }

    private var accessoryMonitoringConfigurationBlocker:
        AccessoryMonitoringConfigurationBlocker? {
        guard appPreferences.hasCompletedOnboarding else {
            return .onboardingIncomplete
        }
        guard hasConfiguredVMAssets else {
            return .vmAssetsUnavailable
        }
        guard isNetworkRouteHelperReady else {
            return .privilegedHelperUnavailable
        }
        return nil
    }

    private var isNetworkRouteHelperReady: Bool {
        networkRoute.helper.isAvailable
            && !networkRoute.helper.isOperationInProgress
            && networkRoute.operation == nil
            && networkRoute.snapshot != nil
            && networkRoute.lastErrorMessage == nil
    }

    func startAccessoryMonitoring() {
        guard acceptsNewWork else { return }
        if let blocker = accessoryMonitoringConfigurationBlocker {
            reportAccessoryMonitoringBlocked(blocker, action: "start")
            return
        }
        shouldRunAccessoryMonitoring = true
        startAccessoryMonitoring(reason: "manual request")
    }

    func startAccessoryMonitoringOnLaunch() {
        guard acceptsNewWork, !didRequestLaunchAccessoryMonitoring else { return }
        didRequestLaunchAccessoryMonitoring = true
        shouldRunAccessoryMonitoring = true
        if let blocker = accessoryMonitoringConfigurationBlocker {
            appendEventLog(
                "USB listener start deferred because \(blocker.eventLogDescription).",
                level: .debug,
                category: .usb
            )
            return
        }
        startAccessoryMonitoring(reason: "app launch")
    }

    func onboardingPresentationDidBegin() {
        isOnboardingPresented = true
    }

    func onboardingPresentationDidEnd() {
        guard isOnboardingPresented else { return }
        isOnboardingPresented = false
        startAccessoryMonitoringIfRequested(reason: "onboarding closed")
        workflowCoordinator.presentNextUSBAttachmentPromptIfPossible()
    }

    func stopAccessoryMonitoring() {
        guard acceptsNewWork else { return }
        guard !workflowCoordinator.hasPendingAttachment else {
            statusMessage = String(
                localized: "Wait for the current USB attachment workflow before stopping the listener."
            )
            return
        }
        shouldRunAccessoryMonitoring = false
        usbCoordinator.stopMonitoring(
            reason: "User stopped USB listener.",
            completion: nil
        )
    }

    func reloadAccessoryMonitoring() {
        guard acceptsNewWork else { return }
        refreshRuntimeEntitlements()
        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(
                .accessoryAccessUSB,
                action: "USB listener reload",
                category: .usb
            )
            return
        }
        if let blocker = accessoryMonitoringConfigurationBlocker {
            reportAccessoryMonitoringBlocked(blocker, action: "reload")
            return
        }
        guard !workflowCoordinator.hasPendingAttachment else { return }
        usbCoordinator.reloadMonitoring(reason: "user request")
    }

    @discardableResult
    func startVirtualMachine() -> Bool {
        guard acceptsNewWork else { return false }
        refreshRuntimeEntitlements()
        guard !assetProvider.isBusy else {
            statusMessage = String(
                localized: "Wait for VM asset installation to finish before starting the VM."
            )
            return false
        }

        let bootAssets: VMAssetBootAssets
        do {
            bootAssets = try assetProvider.validatedBootAssets()
        } catch {
            statusMessage = error.localizedDescription
            appendEventLog(
                "VM asset validation failed before VM start: " +
                    EventLogErrorFormatter.description(for: error),
                level: .error,
                category: .vmAsset
            )
            return false
        }

        guard vmCoordinator.canStart else {
            statusMessage = String(
                localized: "Wait for the current VM transition to finish."
            )
            return false
        }
        guard runtimeEntitlements.virtualization else {
            reportMissingEntitlement(.virtualization, action: "VM start", category: .vm)
            return false
        }

        networkRoute.resetForVMStart()
        clearConsoleForVMStart()
        usbCoordinator.resetForVMStart()
        syncUSBState()

        let bootCommandLine = vmConfiguration.normalizedBootCommandLine()
        if bootCommandLine != vmConfiguration.kernelCommandLine {
            vmConfiguration.kernelCommandLine = bootCommandLine
            appendEventLog(
                "Adjusted kernel arguments for initramfs-only boot.",
                level: .debug,
                category: .vm
            )
        }

        let input = VMCoordinatorStartInput(
            kernelURL: bootAssets.kernelURL,
            initialRamdiskURL: bootAssets.initialRamdiskURL,
            diskImageURL: vmConfiguration.diskImageURL,
            cpuCount: vmConfiguration.cpuCount,
            memorySizeMiB: vmConfiguration.memorySizeMiB,
            bootCommandLine: bootCommandLine,
            guestMACAddress: guestMACAddress
        )

        appendEventLog(
            "VM start parameters: cpuCount=\(vmConfiguration.cpuCount), " +
                "memoryMiB=\(vmConfiguration.memorySizeMiB), " +
                "scratchDisk=\(vmConfiguration.diskImageURL == nil ? "none" : "present"), " +
                "guestMAC=\(guestMACAddress).",
            level: .debug,
            category: .vm
        )
        vmCoordinator.start(input: input)
        return true
    }

    func stopVirtualMachine() {
        guard acceptsNewWork else { return }
        stopVirtualMachine(reason: "VM stop requested by user")
    }

    private func stopVirtualMachine(reason: String) {
        vmRestartState = .idle
        workflowCoordinator.cancelWorkflow(reason: reason)
        networkRoute.stop(reason: reason)
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.stop()
    }

    func restartVirtualMachine() {
        guard canRestartVirtualMachine else { return }
        workflowCoordinator.prepareForManualVMRestart(
            attachedAccessoryID: attachedAccessoryID
        )
        networkRoute.stop(reason: "VM restart")
        usbCoordinator.prepareForIntentionalVMStop()
        vmRestartState = .stopping
        vmCoordinator.restart(reason: "manual request") { [weak self] in
            guard let self else { return }
            self.vmRestartState = .starting
            guard self.workflowCoordinator.canStartVMForManualRestart() else {
                self.vmRestartState = .idle
                return
            }
            if self.startVirtualMachine() {
                if self.workflowCoordinator.hasPendingAttachment,
                   self.runtimeState == .starting {
                    self.workflowCoordinator.markVMStartedForPendingAttachment()
                }
            } else {
                self.vmRestartState = .idle
                self.workflowCoordinator.cancelWorkflow(
                    reason: "VM preflight failed after restart"
                )
            }
        }
    }

    func requestAttachSelectedAccessory() {
        guard acceptsNewWork else { return }
        guard let selectedAccessoryID else {
            statusMessage = String(localized: "Select a USB accessory.")
            return
        }
        requestAttachAccessory(id: selectedAccessoryID)
    }

    func selectAccessory(id: UInt64?) {
        guard acceptsNewWork else { return }
        usbCoordinator.selectAccessory(id: id)
    }

    func requestAttachAccessory(id accessoryID: UInt64) {
        guard acceptsNewWork else { return }
        refreshRuntimeEntitlements()
        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(
                .accessoryAccessUSB,
                action: "USB attach",
                category: .usb
            )
            return
        }
        guard isNetworkRouteHelperReady else {
            statusMessage = String(
                localized: "Install and enable the network route helper before attaching USB."
            )
            return
        }
        workflowCoordinator.requestAttachAccessory(id: accessoryID)
    }

    func detachAccessory() {
        guard acceptsNewWork, attachedAccessoryID != nil else { return }
        stopVirtualMachine(reason: "USB detach requested by user")
    }

    func resolveUSBAttachmentPrompt(accepted: Bool) {
        guard acceptsNewWork else { return }
        workflowCoordinator.resolveUSBAttachmentPrompt(accepted: accepted)
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        acceptsNewWork && vmCoordinator.sendConsoleBytes(data)
    }

    func requestOnboardingPresentation(restart: Bool = true) {
        onboardingPresentationRequest = OnboardingPresentationRequest(
            sequence: onboardingPresentationRequest.sequence + 1,
            restart: restart
        )
    }

    func completeOnboarding() {
        guard hasConfiguredVMAssets,
              !assetProvider.isBusy,
              (!networkRoute.helper.isSignedBuild
                || isNetworkRouteHelperReady) else {
            statusMessage = String(
                localized: "Install valid VM assets and enable the network route helper before finishing onboarding."
            )
            return
        }
        appPreferences.completeOnboarding()
        appendEventLog("Onboarding completed.", level: .info, category: .application)
        workflowCoordinator.assetsDidBecomeAvailable()
        startAccessoryMonitoringIfRequested(reason: "onboarding completed")
    }

    func prepareForApplicationTermination() async {
        guard applicationState != .terminating else { return }
        applicationState = .terminating
        appendEventLog(
            "Application terminating.",
            level: .debug,
            category: .application
        )
        let routesRemoved = await networkRoute.stopForApplicationTermination()
        if !routesRemoved {
            appendEventLog(
                "Application termination will continue after managed route cleanup failed.",
                level: .error,
                category: .application
            )
        }
        shouldRunAccessoryMonitoring = false
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.invalidate()
        usbCoordinator.stopMonitoring(reason: "Application terminating.")
    }

    @discardableResult
    func resetAppSettings() async -> Bool {
        guard canResetAppSettings else {
            resetStatusMessage = String(
                localized: "Wait for the current operation to finish."
            )
            return false
        }

        applicationState = .resetting
        defer {
            if applicationState == .resetting {
                applicationState = .active
            }
        }
        workflowCoordinator.cancelPendingWorkForReset()

        if vmCoordinator.hasVirtualMachine {
            usbCoordinator.prepareForIntentionalVMStop()
            guard await vmCoordinator.stopAndWaitUntilStopped() else {
                resetStatusMessage = String(
                    localized: "Could not stop the VM before resetting app settings."
                )
                return false
            }
        }

        do {
            try await networkRoute.resetForAppSettings()
        } catch {
            resetStatusMessage = String(
                localized: "Could not reset network routes: \(error.localizedDescription)"
            )
            return false
        }

        workflowCoordinator.clearDeferredWorkForReset()
        vmConfiguration.reset()
        statusMessage = String(
            localized: "App settings reset. Install or select VM assets to continue."
        )

        do {
            try appPreferences.resetPersistedValues()
            resetStatusMessage = String(localized: "App settings were reset.")
        } catch {
            resetStatusMessage = String(
                localized: "Settings reset, but Launch at Login could not be disabled: \(error.localizedDescription)"
            )
        }
        appendEventLog(
            "App settings were reset; VM asset files were not deleted.",
            level: .info,
            category: .application
        )
        return true
    }

    func assetAvailabilityDidChange() {
        objectWillChange.send()
        workflowCoordinator.assetsDidBecomeAvailable()
        startAccessoryMonitoringIfRequested(
            reason: "VM asset availability changed"
        )
    }

    private func configureCoordinators() {
        vmCoordinator.onStateChange = { [weak self] state, message in
            guard let self else { return }
            if state == .running || state == .failed {
                self.vmRestartState = .idle
            }
            self.runtimeState = state
            self.statusMessage = message
            if state == .failed {
                self.networkRoute.vmDidStop()
            }
            self.workflowCoordinator.vmStateDidChange(state)
        }
        vmCoordinator.onEventLog = { [weak self] message, level in
            self?.appendEventLog(message, level: level, category: .vm)
        }
        vmCoordinator.onConsoleOutput = { [weak self] data in
            self?.appendConsole(data)
        }
        vmCoordinator.onConsoleUnavailable = { [weak self] in
            self?.networkRoute.guestControlPathDidFail(
                reason: "VM console became unavailable"
            )
        }
        vmCoordinator.onNetworkDisconnect = { [weak self] in
            self?.networkRoute.guestControlPathDidFail(
                reason: "VZNAT network attachment disconnected"
            )
        }
        vmCoordinator.onUSBPassthroughDisconnect = { [weak self] device in
            self?.usbCoordinator.handlePassthroughDisconnect(device: device)
        }
        vmCoordinator.onStopped = { [weak self] in
            guard let self else { return }
            self.networkRoute.vmDidStop()
            self.workflowCoordinator.vmDidStop(
                restartWillStartVM: self.restartWillStartVM
            )
            self.syncUSBState()
        }

        usbCoordinator.onStateChange = { [weak self] in
            guard let self else { return }
            self.syncUSBState()
            self.workflowCoordinator.usbStateDidChange()
        }
        usbCoordinator.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }
        usbCoordinator.onEventLog = { [weak self] message, level in
            self?.appendEventLog(message, level: level, category: .usb)
        }
        usbCoordinator.onAccessoryAvailable = { [weak self] record in
            guard let self else { return }
            guard self.appPreferences.shouldAskToAttachDetectedUSBDevices else {
                return
            }
            guard !self.isOnboardingPresented else {
                self.appendEventLog(
                    "USB attach prompt deferred while onboarding is presented.",
                    level: .debug,
                    category: .usb
                )
                return
            }
            self.workflowCoordinator.accessoryDidBecomeAvailable(record)
        }
        usbCoordinator.onAccessoryUnavailable = { [weak self] accessoryID in
            self?.workflowCoordinator.accessoryDidBecomeUnavailable(accessoryID)
        }
        usbCoordinator.onUnexpectedDetach = { [weak self] accessoryID, reason in
            guard let self,
                  self.workflowCoordinator.handleUnexpectedUSBDetach(
                    accessoryID: accessoryID,
                    reason: reason
                  ) else {
                return
            }
            self.stopVirtualMachine(reason: "USB passthrough lifecycle ended")
        }
        usbCoordinator.runtimeStateProvider = { [weak self] in
            self?.runtimeState ?? .idle
        }

        syncUSBState()
    }

    private func configureAccessoryMonitoringStartObservation() {
        networkRoute.helper.$registrationStatus
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleAccessoryMonitoringStartIfRequested(
                    reason: "network route helper status changed"
                )
            }
            .store(in: &accessoryMonitoringStartCancellables)

        networkRoute.helper.$operation
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleAccessoryMonitoringStartIfRequested(
                    reason: "network route helper operation changed"
                )
            }
            .store(in: &accessoryMonitoringStartCancellables)

        Publishers.CombineLatest3(
            networkRoute.$snapshot,
            networkRoute.$operation,
            networkRoute.$lastErrorMessage
        )
        .dropFirst()
        .sink { [weak self] _, _, _ in
            self?.networkRouteHealthDidChange()
        }
        .store(in: &accessoryMonitoringStartCancellables)
    }

    private func networkRouteHealthDidChange() {
        objectWillChange.send()

        let hasHealthFailure = networkRoute.lastErrorMessage != nil
            || (!networkRoute.helper.isAvailable
                && !networkRoute.helper.isOperationInProgress)
        if hasHealthFailure,
           usbCoordinator.isAccessoryMonitoring,
           attachedAccessoryID == nil,
           !workflowCoordinator.hasPendingAttachment {
            usbCoordinator.stopMonitoring(
                reason: "Network route helper health check failed.",
                completion: nil
            )
            return
        }

        scheduleAccessoryMonitoringStartIfRequested(
            reason: "network route helper health changed"
        )
    }

    private func startAccessoryMonitoring(reason: String) {
        if let blocker = accessoryMonitoringConfigurationBlocker {
            appendEventLog(
                "USB listener start deferred because " +
                    "\(blocker.eventLogDescription): \(reason).",
                level: .debug,
                category: .usb
            )
            return
        }
        refreshRuntimeEntitlements()
        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(
                .accessoryAccessUSB,
                action: "USB listener",
                category: .usb
            )
            return
        }
        guard usbCoordinator.canStartMonitoring else { return }
        usbCoordinator.startMonitoring(reason: reason, completion: nil)
    }

    private func startAccessoryMonitoringIfRequested(reason: String) {
        guard acceptsNewWork,
              !isPreparingForApplicationTermination,
              shouldRunAccessoryMonitoring,
              !usbCoordinator.isAccessoryMonitoring else {
            return
        }
        refreshRuntimeEntitlements()
        guard runtimeEntitlements.accessoryAccessUSB,
              accessoryMonitoringConfigurationBlocker == nil,
              usbCoordinator.canStartMonitoring else {
            return
        }
        startAccessoryMonitoring(reason: reason)
    }

    private func scheduleAccessoryMonitoringStartIfRequested(reason: String) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.objectWillChange.send()
            self.startAccessoryMonitoringIfRequested(reason: reason)
        }
    }

    private func reportAccessoryMonitoringBlocked(
        _ blocker: AccessoryMonitoringConfigurationBlocker,
        action: String
    ) {
        statusMessage = blocker.statusMessage
        appendEventLog(
            "USB listener \(action) rejected because \(blocker.eventLogDescription).",
            level: .debug,
            category: .usb
        )
    }

    private func syncUSBState() {
        usbSession.apply(
            USBSessionSnapshot(
                accessories: usbCoordinator.accessories,
                isAccessoryMonitoring: usbCoordinator.isAccessoryMonitoring,
                selectedAccessoryID: usbCoordinator.selectedAccessoryID,
                attachedAccessoryID: usbCoordinator.attachedAccessoryID,
                vmSessionAccessoryID: usbCoordinator.vmSessionAccessoryID
            )
        )
    }

    private func appendScratchDiskSelectionSummaryIfNeeded() {
        if let diskImageURL = vmConfiguration.diskImageURL {
            appendEventLog(
                "Restored scratch disk path: \(diskImageURL.path).",
                level: .debug,
                category: .vm
            )
        }
    }

    private func refreshRuntimeEntitlements() {
        let snapshot = runtimeEntitlementSnapshotProvider()
        if snapshot != runtimeEntitlements {
            runtimeEntitlements = snapshot
            appendRuntimeEntitlementSummary()
        }
    }

    private func appendRuntimeEntitlementSummary() {
        let summary = RuntimeEntitlement.allCases.map { entitlement in
            "\(entitlement.rawValue)=\(runtimeEntitlements.has(entitlement) ? "present" : "missing")"
        }
        appendEventLog(
            "Runtime entitlements: \(summary.joined(separator: ", ")).",
            level: .debug,
            category: .application
        )
    }

    private func reportMissingEntitlement(
        _ entitlement: RuntimeEntitlement,
        action: String,
        category: EventLogCategory
    ) {
        statusMessage = String(
            localized: "\(entitlement.label) entitlement missing."
        )
        appendEventLog(
            "\(action) not started: missing \(entitlement.rawValue).",
            level: .error,
            category: category
        )
    }

    private func clearConsoleForVMStart() {
        consoleSession.clear()
    }

    private func appendConsole(_ data: Data) {
        guard let update = consoleSession.append(data) else { return }
        if let guestIPv4Address = update.guestIPv4Address {
            networkRoute.updateGuestIPv4Address(guestIPv4Address)
        }
        if let isRNDISRouteReady = update.isRNDISRouteReady {
            networkRoute.updateRNDISRouteReady(isRNDISRouteReady)
        }
    }

    private func appendEventLog(
        _ message: String,
        level: EventLogLevel,
        category: EventLogCategory
    ) {
        eventLog.append(message, level: level, category: category)
    }
}
