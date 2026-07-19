/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

struct OnboardingPresentationRequest {
    let sequence: Int
    let restart: Bool
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private(set) var isRestartingVirtualMachine = false
    @Published private(set) var statusMessage = String(localized: "Install or select VM assets to begin.")
    @Published private(set) var runtimeEntitlements: RuntimeEntitlementSnapshot
    @Published private(set) var isResettingAppSettings = false
    @Published private(set) var wireGuardConnectionPrompt: WireGuardConnectionPrompt?
    @Published private(set) var isOnboardingPresented = false
    @Published private(set) var onboardingPresentationRequest = OnboardingPresentationRequest(
        sequence: 0,
        restart: false
    )
    @Published private(set) var resetStatusMessage = ""

    let guestMACAddress = "02:00:5E:10:00:02"
    let eventLog: EventLogStore
    let consoleSession: ConsoleSessionStore
    let usbSession: USBSessionStore
    let vmConfiguration: VMConfigurationStore
    let wireGuardSession: WireGuardSessionStore
    let appPreferences: AppPreferencesStore

    private let vmCoordinator: any VMCoordinating
    private let usbCoordinator: any USBAccessoryCoordinating
    private let assetProvider: VMAssetProviding
    private let runtimeEntitlementSnapshotProvider: () -> RuntimeEntitlementSnapshot
    private var pendingWireGuardConnectionAccessoryID: UInt64?
    private var isPreparingForApplicationTermination = false
    private var didRequestLaunchAccessoryMonitoring = false
    private var shouldResumeAccessoryMonitoringAfterOnboarding = false
    private var isStoppingAccessoryMonitoringForOnboarding = false
    private var pendingAttachmentAccessoryID: UInt64?
    private var pendingAttachmentToken: UUID?
    private var pendingAttachmentStartedVM = false
    private var shouldStartPendingAttachmentAfterStop = false
    private var restartWillStartVM = false
    private var queuedUSBAttachmentPrompts: [USBAttachmentPrompt] = []
    private var promptedAccessoryIDs: Set<UInt64> = []
    private var accessoriesAwaitingAssetSetup: Set<UInt64> = []

    private var attachmentRequiresVMStopRetry: Bool {
        runtimeState == .failed && vmCoordinator.hasVirtualMachine
    }

    var accessories: [USBAccessoryRecord] {
        usbSession.accessories
    }

    var isAccessoryMonitoring: Bool {
        usbSession.isAccessoryMonitoring
    }

    var selectedAccessoryID: UInt64? {
        usbSession.selectedAccessoryID
    }

    var attachedAccessoryID: UInt64? {
        usbSession.attachedAccessoryID
    }

    var vmSessionAccessoryID: UInt64? {
        usbSession.vmSessionAccessoryID
    }

    var usbAttachmentPrompt: USBAttachmentPrompt? {
        usbSession.attachmentPrompt
    }

    var vmDisplayState: VMDisplayState {
        if isRestartingVirtualMachine {
            return .restarting
        }

        switch runtimeState {
        case .starting, .running:
            return .running
        case .idle, .stopping, .stopped, .failed:
            return .stopped
        }
    }

    var canStartVirtualMachine: Bool {
        hasConfiguredVMAssets
            && !assetProvider.isBusy
            && wireGuardSession.hasKeyMaterial
            && vmCoordinator.canStart
    }

    var canRestartVirtualMachine: Bool {
        hasConfiguredVMAssets
            && !assetProvider.isBusy
            && pendingAttachmentAccessoryID == nil
            && vmCoordinator.canRestart
    }

    var canEditVMConfiguration: Bool {
        !vmCoordinator.hasVirtualMachine
            && (runtimeState == .idle || runtimeState == .stopped || runtimeState == .failed)
    }

    var canResetAppSettings: Bool {
        !isResettingAppSettings && !assetProvider.isBusy
    }

    var hasConfiguredVMAssets: Bool {
        assetProvider.hasConfiguredAssets
    }

    var shouldPresentOnboardingOnLaunch: Bool {
        !appPreferences.hasCompletedOnboarding
    }

    var canStartAccessoryMonitoring: Bool {
        !isOnboardingPresented
            && hasConfiguredVMAssets
            && !assetProvider.isBusy
            && runtimeEntitlements.accessoryAccessUSB
            && usbCoordinator.canStartMonitoring
    }

    var canStopAccessoryMonitoring: Bool {
        pendingAttachmentAccessoryID == nil && usbCoordinator.canStopMonitoring
    }

    var canReloadAccessoryMonitoring: Bool {
        !isOnboardingPresented
            && pendingAttachmentAccessoryID == nil
            && runtimeEntitlements.accessoryAccessUSB
            && usbCoordinator.canReloadMonitoring
    }

    var canStopVirtualMachine: Bool {
        vmCoordinator.canStop
    }

    var canSendConsoleInput: Bool {
        vmCoordinator.canSendConsoleInput
    }

    var canAttachSelectedAccessory: Bool {
        guard !isOnboardingPresented,
              hasConfiguredVMAssets,
              !assetProvider.isBusy,
              pendingAttachmentAccessoryID == nil,
              vmSessionAccessoryID == nil,
              !attachmentRequiresVMStopRetry,
              let selectedAccessoryID else {
            return false
        }

        return usbCoordinator.canRequestAttachment(for: selectedAccessoryID)
    }

    var canDetachAccessory: Bool {
        usbCoordinator.canDetachAccessory(runtimeState: runtimeState)
    }

    func canChooseAccessoryForAttachment(_ accessoryID: UInt64) -> Bool {
        pendingAttachmentAccessoryID == nil
            && usbAttachmentPrompt == nil
            && vmSessionAccessoryID == nil
            && !attachmentRequiresVMStopRetry
            && !assetProvider.isBusy
            && usbCoordinator.canRequestAttachment(for: accessoryID)
    }

    var canConnectHostWireGuardTunnel: Bool {
        runtimeState == .running
            && vmCoordinator.canSendConsoleInput
            && wireGuardSession.canExportConfiguration
            && runtimeEntitlements.packetTunnelProvider
            && runtimeEntitlements.systemExtensionInstall
            && wireGuardSession.systemExtensionStatus.isActive
            && !wireGuardSession.hostTunnelStatus.isTransitioning
    }

    var canRequestWireGuardSystemExtensionActivation: Bool {
        !isPreparingForApplicationTermination
            && runtimeEntitlements.systemExtensionInstall
            && wireGuardSession.canRequestSystemExtensionActivation
    }

    var shouldConfirmApplicationTermination: Bool {
        attachedAccessoryID != nil
            && wireGuardSession.hostTunnelStatus.isConnectingOrConnected
    }

    init(
        assetProvider: VMAssetProviding,
        vmCoordinator: any VMCoordinating,
        usbCoordinator: any USBAccessoryCoordinating,
        eventLog: EventLogStore,
        consoleSession: ConsoleSessionStore,
        usbSession: USBSessionStore,
        vmConfiguration: VMConfigurationStore,
        wireGuardSession: WireGuardSessionStore,
        appPreferences: AppPreferencesStore,
        runtimeEntitlementSnapshotProvider: @escaping () -> RuntimeEntitlementSnapshot = {
            .current
        }
    ) {
        self.assetProvider = assetProvider
        self.vmCoordinator = vmCoordinator
        self.usbCoordinator = usbCoordinator
        self.runtimeEntitlementSnapshotProvider = runtimeEntitlementSnapshotProvider
        self.eventLog = eventLog
        self.consoleSession = consoleSession
        self.usbSession = usbSession
        self.vmConfiguration = vmConfiguration
        self.wireGuardSession = wireGuardSession
        self.appPreferences = appPreferences
        self.runtimeEntitlements = runtimeEntitlementSnapshotProvider()

        wireGuardSession.onReadinessChange = { [weak self] in
            self?.attemptPendingWireGuardConnectionIfReady()
        }
        configureCoordinators()
        appendRuntimeEntitlementSummary()
        appendScratchDiskSelectionSummaryIfNeeded()
    }

    convenience init(
        assetProvider: VMAssetProviding,
        vmCoordinator: any VMCoordinating,
        usbCoordinator: any USBAccessoryCoordinating,
        wireGuardConfigurationStore: any WireGuardConfigurationStoring,
        wireGuardConfigurationBuilder: WireGuardConfigurationBuilder,
        eventLog: EventLogStore,
        consoleSession: ConsoleSessionStore,
        usbSession: USBSessionStore,
        vmConfiguration: VMConfigurationStore,
        hostWireGuardTunnelController: any HostWireGuardTunnelControlling,
        runtimeEntitlementSnapshotProvider: @escaping () -> RuntimeEntitlementSnapshot = {
            .current
        },
        systemExtensionSettingsOpener: @escaping @MainActor () -> Bool = {
            NetworkExtensionSettingsOpener.open()
        },
        launchAtLoginService: (any LaunchAtLoginManaging)? = nil,
        defaults: UserDefaults = .standard
    ) {
        let wireGuardSession = WireGuardSessionStore(
            configurationStore: wireGuardConfigurationStore,
            configurationBuilder: wireGuardConfigurationBuilder,
            tunnelController: hostWireGuardTunnelController,
            eventLog: eventLog,
            systemExtensionSettingsOpener: systemExtensionSettingsOpener,
            defaults: defaults
        )
        let appPreferences = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        self.init(
            assetProvider: assetProvider,
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            eventLog: eventLog,
            consoleSession: consoleSession,
            usbSession: usbSession,
            vmConfiguration: vmConfiguration,
            wireGuardSession: wireGuardSession,
            appPreferences: appPreferences,
            runtimeEntitlementSnapshotProvider: runtimeEntitlementSnapshotProvider
        )
    }

    func startAccessoryMonitoring() {
        guard !isOnboardingPresented else {
            appendEventLog(
                "USB listener start ignored while onboarding is presented.",
                source: .accessoryAccess
            )
            return
        }

        guard hasConfiguredVMAssets, !assetProvider.isBusy else {
            statusMessage = assetProvider.isBusy
                ? String(localized: "Wait for VM asset installation to finish before starting the USB listener.")
                : String(localized: "Install or select valid VM assets before starting the USB listener.")
            return
        }

        startAccessoryMonitoring(reason: "manual request")
    }

    func startAccessoryMonitoringOnLaunch() {
        guard !didRequestLaunchAccessoryMonitoring else {
            return
        }

        didRequestLaunchAccessoryMonitoring = true
        guard !isOnboardingPresented else {
            shouldResumeAccessoryMonitoringAfterOnboarding = true
            appendEventLog(
                "USB listener start deferred until onboarding closes.",
                source: .accessoryAccess
            )
            return
        }
        startAccessoryMonitoring(reason: "app launch")
    }

    func onboardingPresentationDidBegin() {
        guard !isOnboardingPresented else {
            return
        }

        isOnboardingPresented = true
        if !didRequestLaunchAccessoryMonitoring {
            shouldResumeAccessoryMonitoringAfterOnboarding = true
        }

        guard usbCoordinator.isAccessoryMonitoring else {
            appendEventLog(
                "AccessoryAccess USB listener remains stopped during onboarding.",
                source: .accessoryAccess
            )
            return
        }

        shouldResumeAccessoryMonitoringAfterOnboarding = true
        isStoppingAccessoryMonitoringForOnboarding = true
        usbCoordinator.stopMonitoring(reason: "Onboarding presented.") { [weak self] in
            guard let self else {
                return
            }
            self.isStoppingAccessoryMonitoringForOnboarding = false
            self.resumeAccessoryMonitoringAfterOnboardingIfNeeded()
        }
    }

    func onboardingPresentationDidEnd() {
        guard isOnboardingPresented else {
            return
        }

        isOnboardingPresented = false
        resumeAccessoryMonitoringAfterOnboardingIfNeeded()
        presentNextUSBAttachmentPromptIfNeeded()
    }

    func stopAccessoryMonitoring() {
        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = String(localized: "Wait for the current USB attachment workflow before stopping the listener.")
            return
        }
        usbCoordinator.stopMonitoring(
            reason: "User stopped USB listener.",
            completion: nil
        )
    }

    func reloadAccessoryMonitoring() {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB listener reload")
            return
        }

        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = String(localized: "Wait for the current USB attachment workflow before reloading the listener.")
            return
        }

        usbCoordinator.reloadMonitoring(reason: "user request")
    }

    @discardableResult
    func startVirtualMachine() -> Bool {
        refreshRuntimeEntitlements()

        guard !assetProvider.isBusy else {
            statusMessage = String(localized: "Wait for VM asset installation to finish before starting the VM.")
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
                source: .vmAssets
            )
            return false
        }

        guard wireGuardSession.hasKeyMaterial else {
            statusMessage = String(localized: "Fix the WireGuard configuration error before starting the VM.")
            return false
        }

        guard vmCoordinator.canStart else {
            statusMessage = String(localized: "Wait for the current VM transition to finish.")
            return false
        }

        guard runtimeEntitlements.virtualization else {
            reportMissingEntitlement(.virtualization, action: "VM start")
            return false
        }

        guard wireGuardSession.reloadConfiguration(
            reason: "VM starting",
            requireExisting: true
        ) else {
            statusMessage = String(localized: "Fix the WireGuard configuration error before starting the VM.")
            return false
        }

        wireGuardSession.clearDiscoveredEndpoint(reason: "VM starting")
        clearConsoleForVMStart()
        usbCoordinator.resetForVMStart()
        syncUSBState()

        let bootCommandLine = vmConfiguration.normalizedBootCommandLine()
        if bootCommandLine != vmConfiguration.kernelCommandLine {
            vmConfiguration.kernelCommandLine = bootCommandLine
            appendEventLog("Adjusted kernel arguments for initramfs-only boot.", source: .virtualMachine)
        }

        let input = VMCoordinatorStartInput(
            kernelURL: bootAssets.kernelURL,
            initialRamdiskURL: bootAssets.initialRamdiskURL,
            diskImageURL: vmConfiguration.diskImageURL,
            wireGuardConfigurationDirectoryURL: wireGuardSession.sharedConfigurationDirectoryURL,
            cpuCount: vmConfiguration.cpuCount,
            memorySizeMiB: vmConfiguration.memorySizeMiB,
            bootCommandLine: bootCommandLine,
            guestMACAddress: guestMACAddress
        )

        appendEventLog("Kernel asset: \(bootAssets.kernelURL.path)", source: .virtualMachine)
        appendEventLog("Initramfs asset: \(bootAssets.initialRamdiskURL.path)", source: .virtualMachine)
        appendEventLog("Kernel arguments: \(bootCommandLine)", source: .virtualMachine)
        vmCoordinator.start(input: input)
        return true
    }

    func stopVirtualMachine() {
        stopVirtualMachine(reason: "VM stop requested by user")
    }

    private func stopVirtualMachine(reason: String) {
        isRestartingVirtualMachine = false
        cancelPendingWireGuardConnection(reason: reason)
        cancelPendingAttachment(reason: reason)
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.stop()
    }

    func restartVirtualMachine() {
        guard canRestartVirtualMachine else {
            return
        }

        pendingAttachmentAccessoryID = attachedAccessoryID
        pendingAttachmentToken = attachedAccessoryID == nil ? nil : UUID()
        shouldStartPendingAttachmentAfterStop = false
        usbCoordinator.prepareForIntentionalVMStop()
        restartVirtualMachine(reason: "manual request")
    }

    func requestAttachSelectedAccessory() {
        guard let selectedAccessoryID else {
            statusMessage = String(localized: "Select a USB accessory.")
            return
        }

        requestAttachAccessory(id: selectedAccessoryID)
    }

    func selectAccessory(id: UInt64?) {
        usbCoordinator.selectAccessory(id: id)
    }

    func requestAttachAccessory(id accessoryID: UInt64) {
        refreshRuntimeEntitlements()

        guard !assetProvider.isBusy else {
            statusMessage = String(localized: "Wait for VM asset installation to finish before attaching USB.")
            return
        }

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB attach")
            return
        }

        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = String(localized: "Wait for the current USB attachment workflow to finish.")
            return
        }

        guard !attachmentRequiresVMStopRetry else {
            statusMessage = String(localized: "The VM did not stop cleanly. Retry Stop before attaching a USB accessory.")
            return
        }

        if attachedAccessoryID == accessoryID {
            statusMessage = String(localized: "The selected USB accessory is already attached.")
            return
        }

        guard vmSessionAccessoryID == nil else {
            statusMessage = String(localized: "Detach the current USB accessory before attaching another USB accessory.")
            return
        }

        guard let record = accessories.first(where: { $0.id == accessoryID }) else {
            statusMessage = String(localized: "The selected USB accessory is no longer available.")
            return
        }

        guard hasConfiguredVMAssets else {
            enqueueUSBAttachmentPrompt(
                USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
            )
            return
        }

        if beginAttachmentWorkflow(accessoryID: accessoryID) {
            prepareWireGuardConnectionForUSBAttachment(record)
        }
    }

    func detachAccessory() {
        guard attachedAccessoryID != nil else {
            return
        }

        stopVirtualMachine(reason: "USB detach requested by user")
    }

    func resolveUSBAttachmentPrompt(accepted: Bool) {
        guard let prompt = usbSession.takeAttachmentPrompt() else {
            return
        }
        promptedAccessoryIDs.remove(prompt.accessory.id)

        if accepted {
            switch prompt.kind {
            case .attach:
                if beginAttachmentWorkflow(accessoryID: prompt.accessory.id) {
                    prepareWireGuardConnectionForUSBAttachment(prompt.accessory)
                }
            case .assetsRequired:
                accessoriesAwaitingAssetSetup.insert(prompt.accessory.id)
            }
        } else {
            appendEventLog(
                "USB attach declined for registry \(prompt.accessory.registryIDText).",
                source: .accessoryAccess
            )
        }

        presentNextUSBAttachmentPromptIfNeeded()
    }

    func resolveWireGuardConnectionPrompt(
        id promptID: UUID,
        accepted: Bool,
        shouldAutomaticallyConnectNextTime: Bool
    ) {
        guard let prompt = wireGuardConnectionPrompt,
              prompt.id == promptID else {
            appendEventLog(
                "Ignoring a stale WireGuard connection prompt response.",
                source: .wireGuard
            )
            return
        }

        wireGuardConnectionPrompt = nil
        defer { presentNextUSBAttachmentPromptIfNeeded() }

        guard accepted else {
            appendEventLog(
                "Automatic WireGuard connection declined for USB registry " +
                    "\(prompt.accessory.registryIDText).",
                source: .wireGuard
            )
            return
        }

        if shouldAutomaticallyConnectNextTime {
            appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches = true
        }

        guard pendingAttachmentAccessoryID == prompt.accessory.id
                || attachedAccessoryID == prompt.accessory.id
                || vmSessionAccessoryID == prompt.accessory.id else {
            appendEventLog(
                "WireGuard connection request ignored because USB registry " +
                    "\(prompt.accessory.registryIDText) is no longer part of the current attachment workflow.",
                source: .wireGuard
            )
            return
        }

        requestWireGuardConnectionAfterUSBAttachment(
            accessoryID: prompt.accessory.id
        )
    }

    private func prepareWireGuardConnectionForUSBAttachment(
        _ accessory: USBAccessoryRecord
    ) {
        if appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches {
            requestWireGuardConnectionAfterUSBAttachment(accessoryID: accessory.id)
        } else {
            wireGuardConnectionPrompt = WireGuardConnectionPrompt(accessory: accessory)
        }
    }

    private func requestWireGuardConnectionAfterUSBAttachment(accessoryID: UInt64) {
        pendingWireGuardConnectionAccessoryID = accessoryID
        appendEventLog(
            "WireGuard connection queued for USB registry " +
                "\(Self.registryIDText(accessoryID)); waiting for USB and VM readiness.",
            source: .wireGuard
        )
        attemptPendingWireGuardConnectionIfReady()
    }

    func prepareForApplicationTermination(
        disconnectWireGuard: Bool = true
    ) async {
        isPreparingForApplicationTermination = true
        shouldResumeAccessoryMonitoringAfterOnboarding = false
        appendEventLog("Application terminating.")
        pendingWireGuardConnectionAccessoryID = nil
        wireGuardConnectionPrompt = nil
        await wireGuardSession.prepareForApplicationTermination(
            disconnectTunnel: disconnectWireGuard
        )
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.invalidate()
        usbCoordinator.stopMonitoring(
            reason: "Application terminating.",
            completion: nil
        )
    }

    func refreshHostWireGuardTunnelStatus() {
        refreshRuntimeEntitlements()
        refreshWireGuardSystemExtensionStatus()
        guard !wireGuardSession.hostTunnelStatus.isTransitioning else {
            appendEventLog(
                "Host WireGuard status refresh skipped during a tunnel transition.",
                source: .wireGuard
            )
            return
        }
        guard runtimeEntitlements.packetTunnelProvider else {
            wireGuardSession.updateHostTunnelStatus(.missingPacketTunnelEntitlement)
            appendEventLog(
                "Host WireGuard status not refreshed: missing NetworkExtension entitlement.",
                source: .wireGuard
            )
            return
        }
        wireGuardSession.refreshHostTunnelStatus()
    }

    func refreshWireGuardSystemExtensionStatus() {
        guard !isPreparingForApplicationTermination else {
            return
        }
        refreshRuntimeEntitlements()
        wireGuardSession.refreshSystemExtensionStatus()
    }

    @discardableResult
    func requestWireGuardSystemExtensionActivation() -> Bool {
        guard !isPreparingForApplicationTermination else {
            return false
        }
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.systemExtensionInstall else {
            reportMissingEntitlement(
                .systemExtensionInstall,
                action: "network extension activation"
            )
            wireGuardSession.updateSystemExtensionStatus(
                .failed("System Extension installation entitlement is missing.")
            )
            return false
        }
        guard canRequestWireGuardSystemExtensionActivation else {
            return false
        }

        return wireGuardSession.requestSystemExtensionActivation()
    }

    func openWireGuardSystemExtensionSettings() {
        guard !isPreparingForApplicationTermination else {
            return
        }
        wireGuardSession.openSystemExtensionSettings()
    }

    func connectHostWireGuardTunnel() {
        refreshRuntimeEntitlements()

        guard runtimeState == .running, vmCoordinator.canSendConsoleInput else {
            wireGuardSession.updateHostTunnelStatus(.unconfigured)
            appendEventLog(
                "Host WireGuard tunnel not started: VM is not running.",
                source: .wireGuard
            )
            return
        }
        guard wireGuardSession.validateConnectionInputs() else {
            return
        }
        guard runtimeEntitlements.packetTunnelProvider else {
            reportMissingEntitlement(.packetTunnelProvider, action: "Host WireGuard tunnel start")
            wireGuardSession.updateHostTunnelStatus(.missingPacketTunnelEntitlement)
            return
        }
        guard runtimeEntitlements.systemExtensionInstall else {
            reportMissingEntitlement(.systemExtensionInstall, action: "Host WireGuard tunnel start")
            wireGuardSession.updateHostTunnelStatus(
                .missingSystemExtensionInstallEntitlement
            )
            return
        }

        _ = wireGuardSession.connect()
    }

    func disconnectHostWireGuardTunnel() {
        cancelPendingWireGuardConnection(reason: "manual WireGuard disconnect")
        wireGuardSession.disconnect()
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        return vmCoordinator.sendConsoleBytes(data)
    }

    func requestOnboardingPresentation(restart: Bool = true) {
        onboardingPresentationRequest = OnboardingPresentationRequest(
            sequence: onboardingPresentationRequest.sequence + 1,
            restart: restart
        )
    }

    func completeOnboarding() {
        guard hasConfiguredVMAssets, !assetProvider.isBusy else {
            statusMessage = String(localized: "Install or select valid VM assets before finishing onboarding.")
            return
        }

        appPreferences.completeOnboarding()
        appendEventLog("Onboarding completed.")

        resumeAttachmentsAwaitingAssetSetup()
        presentNextUSBAttachmentPromptIfNeeded()
    }

    @discardableResult
    func resetAppSettings() async -> Bool {
        guard canResetAppSettings else {
            if assetProvider.isBusy {
                resetStatusMessage = String(
                    localized: "Wait for the current VM asset operation to finish."
                )
            }
            return false
        }

        isResettingAppSettings = true
        defer { isResettingAppSettings = false }

        guard await wireGuardSession.disconnectAndWait() else {
            resetStatusMessage = String(
                localized: "Could not stop the WireGuard tunnel before resetting app settings."
            )
            appendEventLog(
                "App settings reset cancelled: Host WireGuard tunnel could not be stopped.",
                source: .wireGuard
            )
            return false
        }

        isRestartingVirtualMachine = false
        restartWillStartVM = false
        cancelPendingAttachment(
            reason: "app settings reset",
            presentNextPrompt: false
        )
        cancelPendingWireGuardConnection(reason: "app settings reset")
        usbSession.clearAttachmentPrompt()
        wireGuardConnectionPrompt = nil

        if vmCoordinator.hasVirtualMachine {
            usbCoordinator.prepareForIntentionalVMStop()
            guard await vmCoordinator.stopAndWaitUntilStopped() else {
                resetStatusMessage = String(
                    localized: "Could not stop the VM before resetting app settings."
                )
                appendEventLog(
                    "App settings reset cancelled: VM could not be stopped.",
                    source: .virtualMachine
                )
                return false
            }
        }

        guard await wireGuardSession.removeSavedTunnelIfNeeded() else {
            resetStatusMessage = String(
                localized: "Could not remove the saved WireGuard tunnel profile."
            )
            appendEventLog(
                "App settings reset cancelled: Saved WireGuard tunnel profile could not be removed.",
                source: .wireGuard
            )
            return false
        }

        do {
            try wireGuardSession.removeConfigurationDirectory()
        } catch {
            resetStatusMessage = String(localized: "Could not remove WireGuard configuration: \(error.localizedDescription)")
            appendEventLog(
                "App settings reset cancelled: Could not remove WireGuard configuration: " +
                    EventLogErrorFormatter.description(for: error)
            )
            return false
        }

        queuedUSBAttachmentPrompts.removeAll()
        promptedAccessoryIDs.removeAll()
        accessoriesAwaitingAssetSetup.removeAll()
        usbSession.clearAttachmentPrompt()
        wireGuardConnectionPrompt = nil

        vmConfiguration.reset()
        wireGuardSession.resetPersistedValues()
        statusMessage = String(localized: "App settings reset. Install or select VM assets to continue.")

        do {
            try appPreferences.resetPersistedValues()
            resetStatusMessage = String(localized: "App settings were reset.")
        } catch {
            resetStatusMessage = String(localized: "Settings reset, but Launch at Login could not be disabled: \(error.localizedDescription)")
        }

        appendEventLog("App settings and WireGuard configuration were reset; VM asset files were not deleted.")
        return true
    }

    func assetAvailabilityDidChange() {
        objectWillChange.send()
        resumeAttachmentsAwaitingAssetSetup()
        presentNextUSBAttachmentPromptIfNeeded()
    }

    private func resumeAttachmentsAwaitingAssetSetup() {
        guard hasConfiguredVMAssets, !assetProvider.isBusy else {
            return
        }

        let waitingAccessoryIDs = accessoriesAwaitingAssetSetup
        accessoriesAwaitingAssetSetup.removeAll()
        for accessoryID in waitingAccessoryIDs {
            guard let record = accessories.first(where: { $0.id == accessoryID }) else {
                continue
            }
            enqueueUSBAttachmentPrompt(
                USBAttachmentPrompt(accessory: record, kind: .attach)
            )
        }
    }

    private func configureCoordinators() {
        vmCoordinator.onStateChange = { [weak self] state, message in
            guard let self else { return }
            if state == .running || state == .failed {
                self.isRestartingVirtualMachine = false
            }
            self.runtimeState = state
            self.statusMessage = message

            switch state {
            case .running:
                self.continuePendingAttachmentIfPossible()
                self.attemptPendingWireGuardConnectionIfReady()
                self.presentNextUSBAttachmentPromptIfNeeded()
            case .failed:
                self.restartWillStartVM = false
                self.cancelPendingWireGuardConnection(reason: "VM start or runtime failure")
                self.cancelPendingAttachment(reason: "VM start or runtime failure")
                self.wireGuardSession.clearDiscoveredEndpoint(reason: "VM failed")
            default:
                break
            }
        }
        vmCoordinator.onEventLog = { [weak self] message in
            self?.appendEventLog(message, source: .virtualMachine)
        }
        vmCoordinator.onConsoleOutput = { [weak self] data in
            self?.appendConsole(data)
        }
        vmCoordinator.onUSBPassthroughDisconnect = { [weak self] device in
            self?.usbCoordinator.handlePassthroughDisconnect(device: device)
        }
        vmCoordinator.onStopped = { [weak self] in
            guard let self else { return }
            let continuingAttachmentID = self.pendingAttachmentAccessoryID.flatMap { accessoryID in
                self.shouldStartPendingAttachmentAfterStop || self.restartWillStartVM
                    ? accessoryID
                    : nil
            }
            let pendingWireGuardAccessoryID = self.pendingWireGuardConnectionAccessoryID
            let promptedWireGuardAccessoryID = self.wireGuardConnectionPrompt?.accessory.id
            let hasWireGuardConnectionRequest = pendingWireGuardAccessoryID != nil
                || promptedWireGuardAccessoryID != nil
            let shouldPreserveWireGuardConnectionRequest = continuingAttachmentID != nil
                && (pendingWireGuardAccessoryID == nil
                    || pendingWireGuardAccessoryID == continuingAttachmentID)
                && (promptedWireGuardAccessoryID == nil
                    || promptedWireGuardAccessoryID == continuingAttachmentID)
            if hasWireGuardConnectionRequest,
               !shouldPreserveWireGuardConnectionRequest {
                self.cancelPendingWireGuardConnection(reason: "VM stopped")
            }
            self.wireGuardSession.clearDiscoveredEndpoint(reason: "VM stopped")
            self.usbCoordinator.clearAttachmentForStoppedVM()
            self.syncUSBState()

            if let pendingAccessoryID = self.pendingAttachmentAccessoryID,
               !self.shouldStartPendingAttachmentAfterStop,
               !self.restartWillStartVM {
                let pendingRecord = self.accessories.first { $0.id == pendingAccessoryID }
                self.cancelPendingAttachment(
                    reason: "VM stopped before USB attachment completed",
                    presentNextPrompt: false
                )
                if let pendingRecord {
                    self.enqueueUSBAttachmentPrompt(
                        USBAttachmentPrompt(accessory: pendingRecord, kind: .attach)
                    )
                }
                self.presentNextUSBAttachmentPromptIfNeeded()
                return
            }

            guard self.shouldStartPendingAttachmentAfterStop,
                  self.pendingAttachmentAccessoryID != nil,
                  !self.restartWillStartVM else {
                self.presentNextUSBAttachmentPromptIfNeeded()
                return
            }

            self.shouldStartPendingAttachmentAfterStop = false
            if !self.startVirtualMachine() {
                self.cancelPendingAttachment(reason: "VM preflight failed after stop")
            }
        }

        usbCoordinator.onStateChange = { [weak self] in
            guard let self else { return }
            self.syncUSBState()
            self.attemptPendingWireGuardConnectionIfReady()
            self.presentNextUSBAttachmentPromptIfNeeded()
        }
        usbCoordinator.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }
        usbCoordinator.onEventLog = { [weak self] message in
            self?.appendEventLog(message, source: .accessoryAccess)
        }
        usbCoordinator.onAccessoryAvailable = { [weak self] record in
            self?.offerAttachmentForAvailableAccessory(record)
        }
        usbCoordinator.onAccessoryUnavailable = { [weak self] accessoryID in
            self?.handleAccessoryUnavailable(accessoryID)
        }
        usbCoordinator.onUnexpectedDetach = { [weak self] accessoryID, reason in
            self?.handleUnexpectedUSBDetach(accessoryID: accessoryID, reason: reason)
        }
        usbCoordinator.runtimeStateProvider = { [weak self] in
            self?.runtimeState ?? .idle
        }

        syncUSBState()
    }

    private func attemptPendingWireGuardConnectionIfReady() {
        guard let accessoryID = pendingWireGuardConnectionAccessoryID else {
            return
        }

        if wireGuardSession.hostTunnelStatus.isConnectingOrConnected {
            pendingWireGuardConnectionAccessoryID = nil
            return
        }

        guard attachedAccessoryID == accessoryID,
              vmSessionAccessoryID == accessoryID,
              wireGuardSession.invalidConnectionFields.isEmpty,
              canConnectHostWireGuardTunnel else {
            return
        }

        pendingWireGuardConnectionAccessoryID = nil
        appendEventLog(
            "USB and VM are ready; starting the queued WireGuard connection for registry " +
                "\(Self.registryIDText(accessoryID)).",
            source: .wireGuard
        )
        connectHostWireGuardTunnel()
    }

    private func cancelPendingWireGuardConnection(reason: String) {
        guard let accessoryID = pendingWireGuardConnectionAccessoryID
                ?? wireGuardConnectionPrompt?.accessory.id else {
            return
        }

        pendingWireGuardConnectionAccessoryID = nil
        wireGuardConnectionPrompt = nil
        appendEventLog(
            "Pending WireGuard connection cancelled for USB registry " +
                "\(Self.registryIDText(accessoryID)): \(reason).",
            source: .wireGuard
        )
    }

    private func offerAttachmentForAvailableAccessory(_ record: USBAccessoryRecord) {
        guard !isOnboardingPresented else {
            appendEventLog(
                "USB attach prompt deferred while onboarding is presented.",
                source: .accessoryAccess
            )
            return
        }

        guard appPreferences.shouldAskToAttachDetectedUSBDevices else {
            appendEventLog(
                "USB attach prompt skipped for registry \(record.registryIDText): " +
                    "asking on device detection is disabled.",
                source: .accessoryAccess
            )
            return
        }

        guard record.hasConfigurationDescriptor,
              attachedAccessoryID != record.id,
              pendingAttachmentAccessoryID != record.id,
              !accessoriesAwaitingAssetSetup.contains(record.id) else {
            return
        }

        enqueueUSBAttachmentPrompt(attachmentPrompt(for: record))
    }

    private func enqueueUSBAttachmentPrompt(_ prompt: USBAttachmentPrompt) {
        guard promptedAccessoryIDs.insert(prompt.accessory.id).inserted else {
            return
        }

        queuedUSBAttachmentPrompts.append(prompt)
        presentNextUSBAttachmentPromptIfNeeded()
    }

    private func presentNextUSBAttachmentPromptIfNeeded() {
        guard !isResettingAppSettings,
              !isOnboardingPresented,
              usbAttachmentPrompt == nil,
              wireGuardConnectionPrompt == nil,
              pendingAttachmentAccessoryID == nil,
              vmSessionAccessoryID == nil,
              !restartWillStartVM,
              !assetProvider.isBusy else {
            return
        }

        guard hasConfiguredVMAssets || accessoriesAwaitingAssetSetup.isEmpty else {
            return
        }

        while let firstPrompt = queuedUSBAttachmentPrompts.first {
            guard let currentRecord = accessories.first(where: { $0.id == firstPrompt.accessory.id }),
                  currentRecord.id != attachedAccessoryID else {
                queuedUSBAttachmentPrompts.removeFirst()
                promptedAccessoryIDs.remove(firstPrompt.accessory.id)
                continue
            }

            queuedUSBAttachmentPrompts.removeFirst()
            usbSession.present(attachmentPrompt(for: currentRecord))
            return
        }
    }

    private func attachmentPrompt(for record: USBAccessoryRecord) -> USBAttachmentPrompt {
        guard hasConfiguredVMAssets else {
            return USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
        }

        return USBAttachmentPrompt(accessory: record, kind: .attach)
    }

    @discardableResult
    private func beginAttachmentWorkflow(accessoryID: UInt64) -> Bool {
        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = String(localized: "Wait for the current USB attachment workflow to finish.")
            return false
        }

        guard !assetProvider.isBusy else {
            statusMessage = String(localized: "Wait for VM asset installation to finish before attaching USB.")
            return false
        }

        guard !attachmentRequiresVMStopRetry else {
            statusMessage = String(localized: "The VM did not stop cleanly. Retry Stop before attaching a USB accessory.")
            presentNextUSBAttachmentPromptIfNeeded()
            return false
        }

        guard hasConfiguredVMAssets else {
            if let record = accessories.first(where: { $0.id == accessoryID }) {
                enqueueUSBAttachmentPrompt(
                    USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
                )
            }
            return false
        }

        guard accessories.contains(where: { $0.id == accessoryID }) else {
            statusMessage = String(localized: "The selected USB accessory is no longer available.")
            return false
        }

        if attachedAccessoryID == accessoryID {
            statusMessage = String(localized: "The selected USB accessory is already attached.")
            return false
        }

        guard vmSessionAccessoryID == nil else {
            statusMessage = String(localized: "Detach the current USB accessory before attaching another USB accessory.")
            return false
        }

        pendingAttachmentAccessoryID = accessoryID
        pendingAttachmentToken = UUID()
        pendingAttachmentStartedVM = false
        shouldStartPendingAttachmentAfterStop = false
        usbCoordinator.selectAccessory(id: accessoryID)
        continuePendingAttachmentIfPossible()
        return pendingAttachmentAccessoryID == accessoryID
            || attachedAccessoryID == accessoryID
    }

    private func continuePendingAttachmentIfPossible() {
        guard let accessoryID = pendingAttachmentAccessoryID,
              let attachmentToken = pendingAttachmentToken else {
            return
        }

        guard accessories.contains(where: { $0.id == accessoryID }) else {
            let shouldStopVM = pendingAttachmentStartedVM && vmCoordinator.canStop
            cancelPendingAttachment(
                reason: "USB accessory became unavailable",
                presentNextPrompt: !shouldStopVM
            )
            statusMessage = String(localized: "The USB accessory became unavailable before it could be attached.")
            if shouldStopVM {
                usbCoordinator.prepareForIntentionalVMStop()
                vmCoordinator.stop()
            }
            return
        }

        switch runtimeState {
        case .running:
            usbCoordinator.attachAccessory(
                id: accessoryID,
                to: vmCoordinator.virtualMachine
            ) { [weak self] success in
                guard let self,
                      self.pendingAttachmentToken == attachmentToken else {
                    return
                }
                self.pendingAttachmentAccessoryID = nil
                self.pendingAttachmentToken = nil
                self.pendingAttachmentStartedVM = false
                self.shouldStartPendingAttachmentAfterStop = false
                self.syncUSBState()

                if success {
                    self.attemptPendingWireGuardConnectionIfReady()
                } else {
                    self.cancelPendingWireGuardConnection(
                        reason: "approved USB attachment failed"
                    )
                    self.appendEventLog(
                        "Approved USB attach did not complete for registry \(Self.registryIDText(accessoryID)).",
                        source: .accessoryAccess
                    )
                }
                self.presentNextUSBAttachmentPromptIfNeeded()
            }
        case .starting:
            break
        case .stopping:
            shouldStartPendingAttachmentAfterStop = true
        case .idle, .stopped, .failed:
            if startVirtualMachine() {
                if pendingAttachmentToken == attachmentToken,
                   pendingAttachmentAccessoryID == accessoryID,
                   runtimeState == .starting {
                    pendingAttachmentStartedVM = true
                }
            } else {
                cancelPendingAttachment(reason: "VM preflight failed")
            }
        }
    }

    private func restartVirtualMachine(reason: String) {
        guard vmCoordinator.canRestart else {
            if runtimeState == .stopping {
                shouldStartPendingAttachmentAfterStop = pendingAttachmentAccessoryID != nil
            }
            return
        }

        isRestartingVirtualMachine = true
        restartWillStartVM = true
        vmCoordinator.restart(reason: reason) { [weak self] in
            guard let self else { return }
            self.restartWillStartVM = false

            if let accessoryID = self.pendingAttachmentAccessoryID,
               !self.accessories.contains(where: { $0.id == accessoryID }) {
                self.isRestartingVirtualMachine = false
                self.cancelPendingAttachment(reason: "target USB accessory disconnected during VM restart")
                self.statusMessage = String(
                    localized: "The USB accessory became unavailable before it could be attached."
                )
                return
            }

            if self.startVirtualMachine() {
                if self.pendingAttachmentAccessoryID != nil,
                   self.runtimeState == .starting {
                    self.pendingAttachmentStartedVM = true
                }
            } else {
                self.isRestartingVirtualMachine = false
                self.cancelPendingAttachment(reason: "VM preflight failed after restart")
            }
        }
    }

    private func handleAccessoryUnavailable(_ accessoryID: UInt64) {
        accessoriesAwaitingAssetSetup.remove(accessoryID)

        guard pendingAttachmentAccessoryID == accessoryID else {
            return
        }

        let shouldStopVM = pendingAttachmentStartedVM && vmCoordinator.canStop
        cancelPendingAttachment(
            reason: "target USB accessory disconnected",
            presentNextPrompt: !shouldStopVM
        )

        if shouldStopVM {
            usbCoordinator.prepareForIntentionalVMStop()
            vmCoordinator.stop()
        }
    }

    private func handleUnexpectedUSBDetach(accessoryID: UInt64, reason: String) {
        guard runtimeState == .running || runtimeState == .starting else {
            return
        }

        appendEventLog(
            "Stopping VM because the USB passthrough lifecycle ended for registry " +
                "\(Self.registryIDText(accessoryID)): \(reason)",
            source: .accessoryAccess
        )
        stopVirtualMachine(reason: "USB passthrough lifecycle ended")
    }

    private func cancelPendingAttachment(
        reason: String,
        presentNextPrompt: Bool = true
    ) {
        guard pendingAttachmentAccessoryID != nil || shouldStartPendingAttachmentAfterStop else {
            return
        }

        cancelPendingWireGuardConnection(reason: "USB attachment workflow cancelled: \(reason)")
        pendingAttachmentAccessoryID = nil
        pendingAttachmentToken = nil
        pendingAttachmentStartedVM = false
        shouldStartPendingAttachmentAfterStop = false
        appendEventLog("Pending USB attachment cancelled: \(reason).", source: .accessoryAccess)
        if presentNextPrompt {
            presentNextUSBAttachmentPromptIfNeeded()
        }
    }

    private func startAccessoryMonitoring(reason: String) {
        guard !isOnboardingPresented else {
            shouldResumeAccessoryMonitoringAfterOnboarding = true
            appendEventLog(
                "USB listener start deferred while onboarding is presented: \(reason).",
                source: .accessoryAccess
            )
            return
        }

        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB listener")
            return
        }

        usbCoordinator.startMonitoring(reason: reason, completion: nil)
    }

    private func resumeAccessoryMonitoringAfterOnboardingIfNeeded() {
        guard shouldResumeAccessoryMonitoringAfterOnboarding,
              !isOnboardingPresented,
              !isStoppingAccessoryMonitoringForOnboarding,
              !isPreparingForApplicationTermination else {
            return
        }

        shouldResumeAccessoryMonitoringAfterOnboarding = false
        if didRequestLaunchAccessoryMonitoring {
            startAccessoryMonitoring(reason: "onboarding closed")
        } else {
            startAccessoryMonitoringOnLaunch()
        }
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
                "Restored optional scratch disk selection: \(diskImageURL.path).",
                source: .virtualMachine
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
        appendEventLog("Runtime entitlements: \(summary.joined(separator: ", ")).")
    }

    private func reportMissingEntitlement(_ entitlement: RuntimeEntitlement, action: String) {
        statusMessage = String(localized: "\(entitlement.label) entitlement missing.")
        appendEventLog("\(action) not started: missing \(entitlement.rawValue). The default ThruRNDIS scheme is for local UI builds; run the ThruRNDIS Runtime scheme with an approved provisioning profile to exercise this runtime path.")
    }

    private func clearConsoleForVMStart() {
        consoleSession.clear()
    }

    private func appendConsole(_ data: Data) {
        if let endpoint = consoleSession.append(data) {
            wireGuardSession.updateDiscoveredEndpoint(endpoint)
        }
    }

    private func appendEventLog(
        _ message: String,
        source: EventLogSource = .app
    ) {
        eventLog.append(message, source: source)
    }

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }
}
