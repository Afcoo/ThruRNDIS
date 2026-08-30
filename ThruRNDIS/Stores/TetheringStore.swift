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
            String(localized: "Install and enable the Network Helper before starting the USB listener.")
        }
    }

    var eventLogDescription: String {
        switch self {
        case .onboardingIncomplete:
            "onboarding is incomplete"
        case .vmAssetsUnavailable:
            "no valid VM assets are selected"
        case .privilegedHelperUnavailable:
            "the Network Helper is not enabled"
        }
    }
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private var isVMStopPreparationInProgress = false
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
    let portForwarding: PortForwardingStore

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
            },
            canContinueVMRestart: { [weak self] in
                self?.acceptsNewWork == true
            },
            stopNetworkRouting: { [weak self] reason in
                guard let self else { return false }
                return await self.networkRoute.stopAndWait(reason: reason)
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
        portForwarding: PortForwardingStore,
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
        self.portForwarding = portForwarding
        self.runtimeEntitlementSnapshotProvider = runtimeEntitlementSnapshotProvider
        runtimeEntitlements = runtimeEntitlementSnapshotProvider()

        configureCoordinators()
        configureAccessoryMonitoringStartObservation()
        appendRuntimeEntitlementSummary()
        appendScratchDiskSelectionSummaryIfNeeded()
    }

    var isRestartingVirtualMachine: Bool {
        workflowCoordinator.isRestartingVirtualMachine
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
            && !isVMStopPreparationInProgress
            && !isRestartingVirtualMachine
            && !networkRoute.isOperationInProgress
            && networkRoute.snapshot?.state == .inactive
            && portForwarding.isReadyForVMStart
            && vmCoordinator.canStart
    }

    var canRestartVirtualMachine: Bool {
        acceptsNewWork
            && hasConfiguredVMAssets
            && !assetProvider.isBusy
            && !isVMStopPreparationInProgress
            && !isRestartingVirtualMachine
            && !workflowCoordinator.hasPendingAttachment
            && vmCoordinator.canRestart
    }

    var canEditVMConfiguration: Bool {
        acceptsNewWork
            && !isVMStopPreparationInProgress
            && !vmCoordinator.hasVirtualMachine
            && (runtimeState == .idle
                || runtimeState == .stopped
                || runtimeState == .failed)
    }

    var canResetAppSettings: Bool {
        acceptsNewWork
            && !assetProvider.isBusy
            && !isVMStopPreparationInProgress
            && !isRestartingVirtualMachine
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
        acceptsNewWork
            && !isVMStopPreparationInProgress
            && !isRestartingVirtualMachine
            && vmCoordinator.canStop
    }

    var canSendConsoleInput: Bool {
        acceptsNewWork && vmCoordinator.canSendConsoleInput
    }

    var canAttachSelectedAccessory: Bool {
        guard acceptsNewWork,
              !isOnboardingPresented,
              !isVMStopPreparationInProgress,
              !isRestartingVirtualMachine,
              hasConfiguredVMAssets,
              isNetworkRouteHelperReady,
              !assetProvider.isBusy,
              !workflowCoordinator.hasPendingAttachment,
              !workflowCoordinator.attachmentRequiresVMStopRetry,
              let selectedAccessoryID,
              selectedAccessoryID != attachedAccessoryID else {
            return false
        }

        if attachedAccessoryID != nil {
            return canReplaceAttachedAccessory(with: selectedAccessoryID)
        }

        guard vmSessionAccessoryID == nil else {
            return false
        }
        return usbCoordinator.canRequestAttachment(for: selectedAccessoryID)
    }

    var canDetachAccessory: Bool {
        acceptsNewWork
            && !isVMStopPreparationInProgress
            && !isRestartingVirtualMachine
            && usbCoordinator.canDetachAccessory(runtimeState: runtimeState)
    }

    var canDetachSelectedAccessory: Bool {
        guard let selectedAccessoryID,
              selectedAccessoryID == attachedAccessoryID else {
            return false
        }
        return canDetachAccessory
    }

    private func canReplaceAttachedAccessory(with accessoryID: UInt64) -> Bool {
        guard canRestartVirtualMachine,
              !isOnboardingPresented,
              isNetworkRouteHelperReady,
              runtimeEntitlements.accessoryAccessUSB,
              !workflowCoordinator.attachmentRequiresVMStopRetry,
              let attachedAccessoryID,
              attachedAccessoryID != accessoryID,
              vmSessionAccessoryID == attachedAccessoryID else {
            return false
        }
        return usbCoordinator.canUseAccessoryForAttachment(accessoryID)
    }

    func canChooseAccessoryForAttachment(_ accessoryID: UInt64) -> Bool {
        acceptsNewWork
            && !isVMStopPreparationInProgress
            && !isRestartingVirtualMachine
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
        guard portForwarding.isReadyForVMStart else {
            let message = portForwarding.validationErrorMessage
                ?? String(localized: "Invalid Input")
            statusMessage = message
            appendEventLog(
                "VM start rejected by port forwarding configuration: \(message)",
                level: .warning,
                category: .network
            )
            return false
        }
        guard !isVMStopPreparationInProgress,
              !networkRoute.isOperationInProgress,
              !workflowCoordinator.isStoppingForVMRestart else {
            statusMessage = String(
                localized: "Wait for Network Routing cleanup to finish before starting the VM."
            )
            appendEventLog(
                "VM start rejected while Network Routing cleanup or another VM lifecycle transition is active.",
                level: .debug,
                category: .network
            )
            return false
        }
        guard networkRoute.snapshot?.state == .inactive else {
            if networkRoute.snapshot == nil {
                networkRoute.refresh()
                statusMessage = String(
                    localized: "Wait for Network Routing status before starting the VM."
                )
                appendEventLog(
                    "VM start deferred until Network Routing status is available.",
                    level: .debug,
                    category: .network
                )
            } else {
                networkRoute.resetForVMStart()
                statusMessage = String(
                    localized: "Wait for Network Routing cleanup to finish before starting the VM."
                )
                appendEventLog(
                    "VM start deferred while previous Network Routing state is cleaned up.",
                    level: .debug,
                    category: .network
                )
            }
            return false
        }
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

        guard networkRoute.resetForVMStart() else {
            statusMessage = String(
                localized: "Wait for Network Routing cleanup to finish before starting the VM."
            )
            appendEventLog(
                "VM start deferred until previous Network Routing state is inactive.",
                level: .debug,
                category: .network
            )
            return false
        }
        clearConsoleForVMStart()
        usbCoordinator.resetForVMStart()
        syncUSBState()

        let normalizedBootCommandLine = vmConfiguration.normalizedBootCommandLine()
        if normalizedBootCommandLine != vmConfiguration.kernelCommandLine {
            vmConfiguration.kernelCommandLine = normalizedBootCommandLine
            appendEventLog(
                "Adjusted kernel arguments for initramfs-only boot.",
                level: .debug,
                category: .vm
            )
        }
        let bootCommandLine = portForwarding.prepareBootCommandLine(
            applyingTo: normalizedBootCommandLine
        )

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
        guard canStopVirtualMachine else { return }
        requestVirtualMachineStop(reason: "VM stop requested by user")
    }

    private func requestVirtualMachineStop(reason: String) {
        requestVirtualMachineStop(
            reason: reason,
            continueAfterNetworkFailure: false
        )
    }

    private func requestVirtualMachineStop(
        reason: String,
        continueAfterNetworkFailure: Bool
    ) {
        guard acceptsNewWork,
              !isVMStopPreparationInProgress,
              !isRestartingVirtualMachine else {
            return
        }

        isVMStopPreparationInProgress = true
        workflowCoordinator.cancelWorkflow(reason: reason)
        statusMessage = String(
            localized: "Stopping Network Routing before stopping the VM."
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            let didStopVMNetwork = await self.networkRoute.stopAndWait(
                reason: reason
            )
            if !didStopVMNetwork {
                self.appendEventLog(
                    continueAfterNetworkFailure
                        ? "VM stop will continue after Network Routing cleanup failed because the USB passthrough lifecycle ended."
                        : "VM stop was cancelled because Network Routing cleanup failed.",
                    level: .error,
                    category: .network
                )
                guard continueAfterNetworkFailure else {
                    self.statusMessage = String(
                        localized: "Could not stop Network Routing. Retry Stop before stopping the VM."
                    )
                    self.isVMStopPreparationInProgress = false
                    return
                }
            }
            self.usbCoordinator.prepareForIntentionalVMStop()
            self.vmCoordinator.stop()
            self.isVMStopPreparationInProgress = false
        }
    }

    func restartVirtualMachine() {
        guard canRestartVirtualMachine else { return }
        workflowCoordinator.restartVirtualMachine(
            attachingAccessoryID: attachedAccessoryID
        )
    }

    func replaceAttachedAccessory(with accessoryID: UInt64) {
        refreshRuntimeEntitlements()
        workflowCoordinator.replaceAttachedAccessory(
            with: accessoryID,
            prerequisitesSatisfied: canReplaceAttachedAccessory(
                with: accessoryID
            )
        )
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
        guard acceptsNewWork,
              !isVMStopPreparationInProgress,
              !isRestartingVirtualMachine else {
            return
        }
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
                localized: "Install and enable the Network Helper before attaching USB."
            )
            return
        }
        workflowCoordinator.requestAttachAccessory(id: accessoryID)
    }

    func detachAccessory() {
        guard canDetachAccessory, attachedAccessoryID != nil else { return }
        requestVirtualMachineStop(reason: "USB detach requested by user")
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
                localized: "Install valid VM assets and enable the Network Helper before finishing onboarding."
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
        let didStopVMNetwork = await networkRoute
            .stopForApplicationTermination()
        if !didStopVMNetwork {
            appendEventLog(
                "Application termination will continue after Network Routing cleanup failed.",
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

        guard await networkRoute.stopAndWait(
            reason: "app settings reset"
        ) else {
            resetStatusMessage = String(
                localized: "Could not stop Network Routing before resetting app settings."
            )
            return false
        }

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
                localized: "Could not reset Network Routing: \(error.localizedDescription)"
            )
            return false
        }

        workflowCoordinator.clearDeferredWorkForReset()
        vmConfiguration.reset()
        portForwarding.reset()
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
            self.runtimeState = state
            self.statusMessage = message
            if state == .failed {
                self.networkRoute.vmDidStop()
                if !self.vmCoordinator.hasVirtualMachine {
                    self.portForwarding.vmDidStop()
                }
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
            self.portForwarding.vmDidStop()
            self.workflowCoordinator.vmDidStop()
            self.syncUSBState()
        }

        usbCoordinator.onStateChange = { [weak self] in
            guard let self else { return }
            let previousAttachedAccessoryID = self.usbSession.attachedAccessoryID
            self.syncUSBState()
            let attachedAccessoryID = self.usbSession.attachedAccessoryID
            if attachedAccessoryID != previousAttachedAccessoryID {
                if attachedAccessoryID != nil {
                    self.networkRoute.usbDidAttach()
                } else {
                    self.networkRoute.usbDidDetach()
                }
            }
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
            self.requestVirtualMachineStop(
                reason: "USB passthrough lifecycle ended",
                continueAfterNetworkFailure: true
            )
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
                    reason: "Network Helper status changed"
                )
            }
            .store(in: &accessoryMonitoringStartCancellables)

        networkRoute.helper.$operation
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleAccessoryMonitoringStartIfRequested(
                    reason: "Network Helper operation changed"
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
                reason: "Network Helper health check failed.",
                completion: nil
            )
            return
        }

        scheduleAccessoryMonitoringStartIfRequested(
            reason: "Network Helper health changed"
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
        if let guestIPv4Address = update.guestIPv4Address,
           let vznatGatewayIPv4Address = update.vznatGatewayIPv4Address {
            networkRoute.updateVZNATNetwork(
                guestIPv4Address: guestIPv4Address,
                vznatGatewayIPv4Address: vznatGatewayIPv4Address
            )
        }
        if let isRNDISRouteReady = update.isRNDISRouteReady {
            networkRoute.updateRNDISRouteReady(isRNDISRouteReady)
        }
        if let addressUpdate = update.rndisIPv4AddressUpdate {
            switch addressUpdate {
            case .available(let address):
                if update.isRNDISRouteReady == true {
                    networkRoute.updateRNDISIPv4Address(address)
                }
            case .unavailable:
                networkRoute.clearRNDISIPv4Address()
            }
        }
        if let portForwardingState = update.portForwardingState {
            portForwarding.apply(portForwardingState)
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
