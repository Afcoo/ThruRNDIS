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
    case networkExtensionInactive
    case privilegedHelperUnavailable

    var statusMessage: String {
        switch self {
        case .onboardingIncomplete:
            String(localized: "Complete onboarding before starting the USB listener.")
        case .vmAssetsUnavailable:
            String(localized: "Install or select valid VM assets before starting the USB listener.")
        case .networkExtensionInactive:
            String(localized: "Enable the Network Extension before starting the USB listener.")
        case .privilegedHelperUnavailable:
            String(localized: "Install and enable the Dummy Ethernet helper before starting the USB listener.")
        }
    }

    var eventLogDescription: String {
        switch self {
        case .onboardingIncomplete:
            "onboarding is incomplete"
        case .vmAssetsUnavailable:
            "no valid VM assets are selected"
        case .networkExtensionInactive:
            "the Network Extension is not active"
        case .privilegedHelperUnavailable:
            "the Dummy Ethernet helper is not enabled"
        }
    }
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private var vmRestartState: TetheringVMRestartState = .idle
    @Published private(set) var statusMessage = String(localized: "Install or select VM assets to begin.")
    @Published private(set) var runtimeEntitlements: RuntimeEntitlementSnapshot
    @Published private var applicationState: TetheringApplicationState = .active
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
    lazy var dummyEthernet = managedDummyEthernet
        ?? DummyEthernetStore(eventLog: eventLog)

    private let vmCoordinator: VMCoordinator
    private let usbCoordinator: USBAccessoryCoordinator
    private let assetProvider: VMAssetProviding
    private let managedDummyEthernet: DummyEthernetStore?
    private let prepareDummyEthernetForWireGuardConnection:
        (@MainActor () async -> Bool)?
    private let deactivateDummyEthernetAfterWireGuardConnection:
        (@MainActor () async -> Void)?
    private let runtimeEntitlementSnapshotProvider: () -> RuntimeEntitlementSnapshot
    private var didRequestLaunchAccessoryMonitoring = false
    private var shouldRunAccessoryMonitoring = false
    private var accessoryMonitoringStartCancellables: Set<AnyCancellable> = []

    private lazy var managedWireGuardConnectionCoordinator =
        ManagedWireGuardConnectionCoordinator(
            wireGuardSession: wireGuardSession,
            dummyEthernet: managedDummyEthernet,
            eventLog: eventLog,
            prepareDummyEthernet: prepareDummyEthernetForWireGuardConnection,
            deactivateDummyEthernet:
                deactivateDummyEthernetAfterWireGuardConnection,
            actions: ManagedWireGuardConnectionCoordinator.Actions(
                refreshRuntimeEntitlements: { [weak self] in
                    self?.refreshRuntimeEntitlements()
                },
                canConnectWireGuardTunnel: { [weak self] in
                    self?.canConnectWireGuardTunnel == true
                },
                connectWireGuardTunnel: { [weak self] in
                    self?.connectWireGuardTunnel() == true
                }
            )
        )

    private lazy var workflowCoordinator = TetheringWorkflowCoordinator(
            assetProvider: assetProvider,
            vmCoordinator: vmCoordinator,
            usbCoordinator: usbCoordinator,
            eventLog: eventLog,
            usbSession: usbSession,
            wireGuardSession: wireGuardSession,
            appPreferences: appPreferences,
            managedWireGuardConnection: managedWireGuardConnectionCoordinator,
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
                canConnectWireGuardTunnel: { [weak self] in
                    self?.canConnectWireGuardTunnel == true
                },
                updateStatusMessage: { [weak self] message in
                    self?.statusMessage = message
                },
                workflowStateDidChange: { [weak self] in
                    self?.objectWillChange.send()
                }
            )
        )

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

    var wireGuardConnectionPrompt: WireGuardConnectionPrompt? {
        wireGuardSession.wireGuardConnectionPrompt
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
        acceptsNewWork
            && hasConfiguredVMAssets
            && !assetProvider.isBusy
            && wireGuardSession.hasKeyMaterial
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
            && (runtimeState == .idle || runtimeState == .stopped || runtimeState == .failed)
    }

    var canResetAppSettings: Bool {
        acceptsNewWork
            && !assetProvider.isBusy
            && managedDummyEthernet?.isAnyOperationInProgress
                != true
    }

    var hasConfiguredVMAssets: Bool {
        assetProvider.hasConfiguredAssets
    }

    var shouldPresentOnboardingOnLaunch: Bool {
        !appPreferences.hasCompletedOnboarding
    }

    var isApplicationConfigured: Bool {
        appPreferences.hasCompletedOnboarding
            && hasConfiguredVMAssets
            && wireGuardSession.systemExtensionStatus.isActive
            && isDummyEthernetHelperReady
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
            && !workflowCoordinator.hasPendingAttachment
            && usbAttachmentPrompt == nil
            && vmSessionAccessoryID == nil
            && !workflowCoordinator.attachmentRequiresVMStopRetry
            && !assetProvider.isBusy
            && usbCoordinator.canRequestAttachment(for: accessoryID)
    }

    var canConnectWireGuardTunnel: Bool {
        acceptsNewWork
            && runtimeState == .running
            && vmCoordinator.canSendConsoleInput
            && wireGuardSession.canExportConfiguration
            && runtimeEntitlements.packetTunnelProvider
            && runtimeEntitlements.systemExtensionInstall
            && wireGuardSession.systemExtensionStatus.isActive
            && !wireGuardSession.tunnelStatus.isTransitioning
    }

    var canRequestWireGuardSystemExtensionActivation: Bool {
        acceptsNewWork
            && runtimeEntitlements.systemExtensionInstall
            && wireGuardSession.canRequestSystemExtensionActivation
    }

    var canDisconnectWireGuardTunnel: Bool {
        acceptsNewWork && wireGuardSession.canDisconnectTunnel
    }

    var canRefreshWireGuardTunnelStatus: Bool {
        acceptsNewWork
            && (!wireGuardSession.tunnelStatus.isTransitioning
                || wireGuardSession.tunnelFailure != nil)
    }

    var shouldConfirmApplicationTermination: Bool {
        attachedAccessoryID != nil
            && wireGuardSession.tunnelStatus.isConnectingOrConnected
    }

    private var accessoryMonitoringConfigurationBlocker:
        AccessoryMonitoringConfigurationBlocker? {
        guard !appPreferences.isDebugModeEnabled else {
            return nil
        }
        guard appPreferences.hasCompletedOnboarding else {
            return .onboardingIncomplete
        }
        guard hasConfiguredVMAssets else {
            return .vmAssetsUnavailable
        }
        guard !appPreferences.isWireGuardManualConfigurationModeEnabled else {
            return nil
        }
        guard wireGuardSession.systemExtensionStatus.isActive else {
            return .networkExtensionInactive
        }
        guard isDummyEthernetHelperReady else {
            return .privilegedHelperUnavailable
        }
        return nil
    }

    private var isDummyEthernetHelperReady: Bool {
        guard let helper = managedDummyEthernet?.helper else {
            return false
        }
        return helper.isAvailable && !helper.isOperationInProgress
    }

    init(
        assetProvider: VMAssetProviding,
        vmCoordinator: VMCoordinator,
        usbCoordinator: USBAccessoryCoordinator,
        eventLog: EventLogStore,
        consoleSession: ConsoleSessionStore,
        usbSession: USBSessionStore,
        vmConfiguration: VMConfigurationStore,
        wireGuardSession: WireGuardSessionStore,
        appPreferences: AppPreferencesStore,
        dummyEthernet: DummyEthernetStore? = nil,
        prepareDummyEthernetForWireGuardConnection:
            (@MainActor () async -> Bool)? = nil,
        deactivateDummyEthernetAfterWireGuardConnection:
            (@MainActor () async -> Void)? = nil,
        runtimeEntitlementSnapshotProvider: @escaping () -> RuntimeEntitlementSnapshot = {
            .current
        }
    ) {
        self.assetProvider = assetProvider
        self.vmCoordinator = vmCoordinator
        self.usbCoordinator = usbCoordinator
        self.managedDummyEthernet = dummyEthernet
        self.prepareDummyEthernetForWireGuardConnection =
            prepareDummyEthernetForWireGuardConnection
        self.deactivateDummyEthernetAfterWireGuardConnection =
            deactivateDummyEthernetAfterWireGuardConnection
        self.runtimeEntitlementSnapshotProvider = runtimeEntitlementSnapshotProvider
        self.eventLog = eventLog
        self.consoleSession = consoleSession
        self.usbSession = usbSession
        self.vmConfiguration = vmConfiguration
        self.wireGuardSession = wireGuardSession
        self.appPreferences = appPreferences
        self.runtimeEntitlements = runtimeEntitlementSnapshotProvider()

        configureCoordinators()
        configureAccessoryMonitoringStartObservation()
        appendRuntimeEntitlementSummary()
        appendScratchDiskSelectionSummaryIfNeeded()
    }

    convenience init(
        assetProvider: VMAssetProviding,
        vmCoordinator: VMCoordinator,
        usbCoordinator: USBAccessoryCoordinator,
        wireGuardConfigurationStore: WireGuardConfigurationStore,
        wireGuardConfigurationBuilder: WireGuardConfigurationBuilder,
        eventLog: EventLogStore,
        consoleSession: ConsoleSessionStore,
        usbSession: USBSessionStore,
        vmConfiguration: VMConfigurationStore,
        wireGuardTunnelController: WireGuardTunnelController,
        runtimeEntitlementSnapshotProvider: @escaping () -> RuntimeEntitlementSnapshot = {
            .current
        },
        systemExtensionSettingsOpener: @escaping @MainActor () -> Bool = {
            NetworkExtensionSettingsOpener.open()
        },
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        defaults: UserDefaults = .standard
    ) {
        let appPreferences = AppPreferencesStore(
            launchAtLoginService: launchAtLoginService,
            defaults: defaults
        )
        let wireGuardSession = WireGuardSessionStore(
            configurationStore: wireGuardConfigurationStore,
            configurationBuilder: wireGuardConfigurationBuilder,
            tunnelController: wireGuardTunnelController,
            eventLog: eventLog,
            systemExtensionSettingsOpener: systemExtensionSettingsOpener,
            defaults: defaults,
            shouldRefreshManagedWireGuardStatus:
                !appPreferences.isWireGuardManualConfigurationModeEnabled
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
        guard acceptsNewWork else { return }
        if let blocker = accessoryMonitoringConfigurationBlocker {
            reportAccessoryMonitoringBlocked(blocker, action: "start")
            return
        }
        shouldRunAccessoryMonitoring = true
        startAccessoryMonitoring(reason: "manual request")
    }

    func startAccessoryMonitoringOnLaunch() {
        guard acceptsNewWork else { return }
        guard !didRequestLaunchAccessoryMonitoring else {
            return
        }

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
        guard !isOnboardingPresented else {
            return
        }

        isOnboardingPresented = true
    }

    func onboardingPresentationDidEnd() {
        guard isOnboardingPresented else {
            return
        }

        isOnboardingPresented = false
        startAccessoryMonitoringIfRequested(reason: "onboarding closed")
        workflowCoordinator.presentNextUSBAttachmentPromptIfPossible()
    }

    func stopAccessoryMonitoring() {
        guard acceptsNewWork else { return }
        guard !workflowCoordinator.hasPendingAttachment else {
            statusMessage = String(localized: "Wait for the current USB attachment workflow before stopping the listener.")
            appendEventLog(
                "USB listener stop rejected: a USB attachment workflow is active.",
                level: .debug,
                category: .usb
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

        guard !workflowCoordinator.hasPendingAttachment else {
            statusMessage = String(localized: "Wait for the current USB attachment workflow before reloading the listener.")
            appendEventLog(
                "USB listener reload rejected: a USB attachment workflow is active.",
                level: .debug,
                category: .usb
            )
            return
        }

        usbCoordinator.reloadMonitoring(reason: "user request")
    }

    @discardableResult
    func startVirtualMachine() -> Bool {
        guard acceptsNewWork else { return false }
        refreshRuntimeEntitlements()

        guard !assetProvider.isBusy else {
            statusMessage = String(localized: "Wait for VM asset installation to finish before starting the VM.")
            appendEventLog(
                "VM start rejected: a VM asset operation is active.",
                level: .debug,
                category: .vm
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

        guard wireGuardSession.hasKeyMaterial else {
            statusMessage = String(localized: "Fix the WireGuard configuration error before starting the VM.")
            appendEventLog(
                "VM start rejected: WireGuard key material is unavailable.",
                level: .debug,
                category: .wireGuard
            )
            return false
        }

        guard vmCoordinator.canStart else {
            statusMessage = String(localized: "Wait for the current VM transition to finish.")
            appendEventLog(
                "VM start rejected while VM state is \(runtimeState.rawValue); " +
                    "hasVirtualMachine=\(vmCoordinator.hasVirtualMachine).",
                level: .debug,
                category: .vm
            )
            return false
        }

        guard runtimeEntitlements.virtualization else {
            reportMissingEntitlement(
                .virtualization,
                action: "VM start",
                category: .vm
            )
            return false
        }

        guard wireGuardSession.reloadConfiguration(
            reason: "VM starting",
            requireExisting: true
        ) else {
            statusMessage = String(localized: "Fix the WireGuard configuration error before starting the VM.")
            appendEventLog(
                "VM start rejected: existing WireGuard configuration could not be regenerated.",
                level: .debug,
                category: .wireGuard
            )
            return false
        }

        wireGuardSession.clearDiscoveredEndpoint(reason: "VM starting")
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
            wireGuardConfigurationDirectoryURL: wireGuardSession.sharedConfigurationDirectoryURL,
            cpuCount: vmConfiguration.cpuCount,
            memorySizeMiB: vmConfiguration.memorySizeMiB,
            bootCommandLine: bootCommandLine,
            guestMACAddress: guestMACAddress
        )

        appendEventLog(
            "Kernel asset: \(bootAssets.kernelURL.path)",
            level: .debug,
            category: .vm
        )
        appendEventLog(
            "Initramfs asset: \(bootAssets.initialRamdiskURL.path)",
            level: .debug,
            category: .vm
        )
        appendEventLog(
            "Kernel arguments: \(bootCommandLine)",
            level: .debug,
            category: .vm
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
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.stop()
    }

    func restartVirtualMachine() {
        guard canRestartVirtualMachine else {
            return
        }

        workflowCoordinator.prepareForManualVMRestart(
            attachedAccessoryID: attachedAccessoryID
        )
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
            appendEventLog(
                "USB attach request rejected: no USB accessory is selected.",
                level: .debug,
                category: .usb
            )
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

        workflowCoordinator.requestAttachAccessory(id: accessoryID)
    }

    func detachAccessory() {
        guard acceptsNewWork else { return }
        guard attachedAccessoryID != nil else {
            appendEventLog(
                "USB detach request ignored: no accessory is attached.",
                level: .debug,
                category: .usb
            )
            return
        }

        stopVirtualMachine(reason: "USB detach requested by user")
    }

    func resolveUSBAttachmentPrompt(accepted: Bool) {
        guard acceptsNewWork else { return }
        workflowCoordinator.resolveUSBAttachmentPrompt(accepted: accepted)
    }

    func resolveWireGuardConnectionPrompt(
        id promptID: UUID,
        accepted: Bool,
        shouldAutomaticallyConnectNextTime: Bool
    ) {
        guard acceptsNewWork else { return }
        workflowCoordinator.resolveWireGuardConnectionPrompt(
            id: promptID,
            accepted: accepted,
            shouldAutomaticallyConnectNextTime:
                shouldAutomaticallyConnectNextTime
        )
    }

    func prepareForApplicationTermination() async -> Bool {
        guard applicationState != .terminating else { return false }
        applicationState = .terminating
        shouldRunAccessoryMonitoring = false
        appendEventLog(
            "Application terminating.",
            level: .debug,
            category: .application
        )
        workflowCoordinator.cancelPendingWireGuardConnection(
            reason: "application termination"
        )
        var didStopManagedNetworkServices = true
        if !appPreferences.isWireGuardManualConfigurationModeEnabled {
            let didStopWireGuard =
                await wireGuardSession.prepareForApplicationTermination()
            let didStopDummyEthernet = if let managedDummyEthernet {
                await managedDummyEthernet
                    .stopForApplicationTerminationIfNeeded()
            } else {
                true
            }
            didStopManagedNetworkServices =
                didStopWireGuard && didStopDummyEthernet
        }
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.invalidate()
        usbCoordinator.stopMonitoring(reason: "Application terminating.")
        return didStopManagedNetworkServices
    }

    func refreshWireGuardTunnelStatus() {
        guard !appPreferences.isWireGuardManualConfigurationModeEnabled,
              canRefreshWireGuardTunnelStatus else { return }
        refreshRuntimeEntitlements()
        wireGuardSession.refreshSystemExtensionStatus()
        guard runtimeEntitlements.packetTunnelProvider else {
            wireGuardSession.updateTunnelFailure(.missingPacketTunnelEntitlement)
            appendEventLog(
                "WireGuard status not refreshed: missing NetworkExtension entitlement.",
                level: .error,
                category: .wireGuard
            )
            return
        }
        wireGuardSession.refreshTunnelStatus()
    }

    func refreshWireGuardSystemExtensionStatus() {
        guard acceptsNewWork,
              !appPreferences.isWireGuardManualConfigurationModeEnabled else {
            return
        }
        refreshRuntimeEntitlements()
        wireGuardSession.refreshSystemExtensionStatus()
    }

    @discardableResult
    func requestWireGuardSystemExtensionActivation() -> Bool {
        guard acceptsNewWork,
              !appPreferences.isWireGuardManualConfigurationModeEnabled else {
            return false
        }
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.systemExtensionInstall else {
            reportMissingEntitlement(
                .systemExtensionInstall,
                action: "network extension activation",
                category: .wireGuard
            )
            wireGuardSession.updateSystemExtensionStatus(
                .unknown("System Extension installation entitlement is missing.")
            )
            return false
        }
        guard canRequestWireGuardSystemExtensionActivation else {
            appendEventLog(
                "Network extension activation request rejected: status=" +
                    "\(wireGuardSession.systemExtensionStatus.eventLogDescription), " +
                    "activationInProgress=" +
                    "\(wireGuardSession.isSystemExtensionActivationInProgress).",
                level: .debug,
                category: .wireGuard
            )
            return false
        }

        return wireGuardSession.requestSystemExtensionActivation()
    }

    func openWireGuardSystemExtensionSettings() {
        guard acceptsNewWork,
              !appPreferences.isWireGuardManualConfigurationModeEnabled else {
            return
        }
        wireGuardSession.openSystemExtensionSettings()
    }

    @discardableResult
    func connectWireGuardTunnel() -> Bool {
        guard acceptsNewWork,
              !appPreferences.isWireGuardManualConfigurationModeEnabled else { return false }
        refreshRuntimeEntitlements()

        guard runtimeState == .running, vmCoordinator.canSendConsoleInput else {
            wireGuardSession.updateTunnelStatus(.unconfigured)
            appendEventLog(
                "WireGuard tunnel not started: VM is not running.",
                level: .warning,
                category: .wireGuard
            )
            return false
        }
        guard runtimeEntitlements.packetTunnelProvider else {
            reportMissingEntitlement(
                .packetTunnelProvider,
                action: "WireGuard tunnel start",
                category: .wireGuard
            )
            wireGuardSession.updateTunnelFailure(.missingPacketTunnelEntitlement)
            return false
        }
        guard runtimeEntitlements.systemExtensionInstall else {
            reportMissingEntitlement(
                .systemExtensionInstall,
                action: "WireGuard tunnel start",
                category: .wireGuard
            )
            wireGuardSession.updateTunnelFailure(
                .missingSystemExtensionInstallEntitlement
            )
            return false
        }

        return wireGuardSession.connect()
    }

    func connectWireGuardTunnelWithAutomaticDummyEthernet() {
        guard acceptsNewWork,
              !appPreferences.isWireGuardManualConfigurationModeEnabled,
              canConnectWireGuardTunnel else { return }
        managedWireGuardConnectionCoordinator.connect()
    }

    func disconnectWireGuardTunnel() {
        guard !appPreferences.isWireGuardManualConfigurationModeEnabled,
              canDisconnectWireGuardTunnel else { return }
        workflowCoordinator.cancelPendingWireGuardConnection(
            reason: "manual WireGuard disconnect"
        )
        wireGuardSession.disconnect()
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
        guard hasConfiguredVMAssets, !assetProvider.isBusy else {
            statusMessage = String(localized: "Install or select valid VM assets before finishing onboarding.")
            return
        }

        appPreferences.completeOnboarding()
        appendEventLog(
            "Onboarding completed.",
            level: .info,
            category: .application
        )

        workflowCoordinator.assetsDidBecomeAvailable()
        startAccessoryMonitoringIfRequested(reason: "onboarding completed")
    }

    @discardableResult
    func resetAppSettings() async -> Bool {
        guard canResetAppSettings else {
            if assetProvider.isBusy {
                resetStatusMessage = String(
                    localized: "Wait for the current VM asset operation to finish."
                )
            } else if managedDummyEthernet?
                .isAnyOperationInProgress == true {
                resetStatusMessage = String(
                    localized: "Wait for the current Dummy Ethernet operation to finish."
                )
            }
            appendEventLog(
                "App settings reset rejected: resetInProgress=\(isResettingAppSettings), " +
                    "vmAssetOperationActive=\(assetProvider.isBusy), " +
                    "dummyEthernetOperationActive=" +
                    "\(managedDummyEthernet?.isAnyOperationInProgress == true).",
                level: .debug,
                category: .application
            )
            return false
        }

        applicationState = .resetting
        defer {
            if applicationState == .resetting {
                applicationState = .active
            }
        }

        workflowCoordinator.cancelManagedWireGuardConnection(
            reason: "app settings reset"
        )
        guard await wireGuardSession.disconnectAndWait() else {
            resetStatusMessage = String(
                localized: "Could not stop the WireGuard tunnel before resetting app settings."
            )
            appendEventLog(
                "App settings reset cancelled: WireGuard tunnel could not be stopped.",
                level: .error,
                category: .wireGuard
            )
            return false
        }

        workflowCoordinator.cancelPendingWorkForReset()

        if vmCoordinator.hasVirtualMachine {
            usbCoordinator.prepareForIntentionalVMStop()
            guard await vmCoordinator.stopAndWaitUntilStopped() else {
                resetStatusMessage = String(
                    localized: "Could not stop the VM before resetting app settings."
                )
                appendEventLog(
                    "App settings reset cancelled: VM could not be stopped.",
                    level: .error,
                    category: .vm
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
                level: .error,
                category: .wireGuard
            )
            return false
        }

        do {
            try wireGuardSession.removeConfigurationDirectory()
        } catch {
            resetStatusMessage = String(localized: "Could not remove WireGuard configuration: \(error.localizedDescription)")
            appendEventLog(
                "App settings reset cancelled: Could not remove WireGuard configuration: " +
                    EventLogErrorFormatter.description(for: error),
                level: .error,
                category: .wireGuard
            )
            return false
        }

        workflowCoordinator.clearDeferredWorkForReset()

        vmConfiguration.reset()
        wireGuardSession.resetPersistedValues()
        statusMessage = String(localized: "App settings reset. Install or select VM assets to continue.")

        if let managedDummyEthernet {
            do {
                try await managedDummyEthernet
                    .resetForAppSettings()
            } catch {
                resetStatusMessage = String(
                    localized: "Could not reset Dummy Ethernet: \(error.localizedDescription)"
                )
                return false
            }
        }

        do {
            try appPreferences.resetPersistedValues()
            resetStatusMessage = String(localized: "App settings were reset.")
        } catch {
            resetStatusMessage = String(localized: "Settings reset, but Launch at Login could not be disabled: \(error.localizedDescription)")
            appendEventLog(
                "Launch at Login could not be disabled during app settings reset: " +
                    EventLogErrorFormatter.description(for: error),
                level: .warning,
                category: .application
            )
        }

        appendEventLog(
            "App settings and WireGuard configuration were reset; VM asset files were not deleted.",
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
        wireGuardSession.onReadinessChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.workflowCoordinator.wireGuardReadinessDidChange()
            self.startAccessoryMonitoringIfRequested(
                reason: "Network Extension status changed"
            )
        }

        vmCoordinator.onStateChange = { [weak self] state, message in
            guard let self else { return }
            if state == .running || state == .failed {
                self.vmRestartState = .idle
            }
            self.runtimeState = state
            self.statusMessage = message
            self.workflowCoordinator.vmStateDidChange(state)
        }
        vmCoordinator.onEventLog = { [weak self] message, level in
            self?.appendEventLog(message, level: level, category: .vm)
        }
        vmCoordinator.onConsoleOutput = { [weak self] data in
            self?.appendConsole(data)
        }
        vmCoordinator.onUSBPassthroughDisconnect = { [weak self] device in
            self?.usbCoordinator.handlePassthroughDisconnect(device: device)
        }
        vmCoordinator.onStopped = { [weak self] in
            guard let self else { return }
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
        appPreferences.$isDebugModeEnabled
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleAccessoryMonitoringStartIfRequested(
                    reason: "debug mode changed"
                )
            }
            .store(in: &accessoryMonitoringStartCancellables)

        guard let helper = managedDummyEthernet?.helper else {
            return
        }

        helper.$registrationStatus
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleAccessoryMonitoringStartIfRequested(
                    reason: "Dummy Ethernet helper status changed"
                )
            }
            .store(in: &accessoryMonitoringStartCancellables)

        helper.$operation
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleAccessoryMonitoringStartIfRequested(
                    reason: "Dummy Ethernet helper operation changed"
                )
            }
            .store(in: &accessoryMonitoringStartCancellables)
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
        guard usbCoordinator.canStartMonitoring else {
            return
        }
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
                "Restored optional scratch disk selection.",
                level: .debug,
                category: .vm
            )
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
        statusMessage = String(localized: "\(entitlement.label) entitlement missing.")
        appendEventLog(
            "\(action) not started: missing \(entitlement.rawValue). The default " +
                "ThruRNDIS scheme is for local UI builds; run the ThruRNDIS Runtime " +
                "scheme with an approved provisioning profile to exercise this runtime path.",
            level: .error,
            category: category
        )
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
        level: EventLogLevel,
        category: EventLogCategory
    ) {
        eventLog.append(message, level: level, category: category)
    }

}
