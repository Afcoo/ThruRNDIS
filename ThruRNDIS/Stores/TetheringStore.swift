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
    private let prepareDummyEthernetForWireGuardConnection:
        (@MainActor () async -> Bool)?
    private let deactivateDummyEthernetAfterWireGuardConnection:
        (@MainActor () -> Void)?
    private let runtimeEntitlementSnapshotProvider: () -> RuntimeEntitlementSnapshot
    private var pendingWireGuardConnectionAccessoryID: UInt64?
    private var automaticWireGuardConnectionTask: Task<Void, Never>?
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
        prepareDummyEthernetForWireGuardConnection:
            (@MainActor () async -> Bool)? = nil,
        deactivateDummyEthernetAfterWireGuardConnection:
            (@MainActor () -> Void)? = nil,
        runtimeEntitlementSnapshotProvider: @escaping () -> RuntimeEntitlementSnapshot = {
            .current
        }
    ) {
        self.assetProvider = assetProvider
        self.vmCoordinator = vmCoordinator
        self.usbCoordinator = usbCoordinator
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
                level: .debug,
                category: .usb
            )
            return
        }

        guard hasConfiguredVMAssets, !assetProvider.isBusy else {
            statusMessage = assetProvider.isBusy
                ? String(localized: "Wait for VM asset installation to finish before starting the USB listener.")
                : String(localized: "Install or select valid VM assets before starting the USB listener.")
            appendEventLog(
                assetProvider.isBusy
                    ? "USB listener start rejected: a VM asset operation is active."
                    : "USB listener start rejected: no valid VM assets are selected.",
                level: .debug,
                category: .usb
            )
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
        if !didRequestLaunchAccessoryMonitoring {
            shouldResumeAccessoryMonitoringAfterOnboarding = true
        }

        guard usbCoordinator.isAccessoryMonitoring else {
            appendEventLog(
                "AccessoryAccess USB listener remains stopped during onboarding.",
                level: .debug,
                category: .usb
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
            appendEventLog(
                "USB listener stop rejected: a USB attachment workflow is active.",
                level: .debug,
                category: .usb
            )
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
            reportMissingEntitlement(
                .accessoryAccessUSB,
                action: "USB listener reload",
                category: .usb
            )
            return
        }

        guard pendingAttachmentAccessoryID == nil else {
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
        usbCoordinator.selectAccessory(id: id)
    }

    func requestAttachAccessory(id accessoryID: UInt64) {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(
                .accessoryAccessUSB,
                action: "USB attach",
                category: .usb
            )
            return
        }

        guard let record = beginAttachmentWorkflow(accessoryID: accessoryID) else {
            return
        }

        prepareWireGuardConnectionForUSBAttachment(record)
    }

    func detachAccessory() {
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
        guard let prompt = usbSession.takeAttachmentPrompt() else {
            return
        }
        promptedAccessoryIDs.remove(prompt.accessory.id)

        if accepted {
            switch prompt.kind {
            case .attach:
                if let record = beginAttachmentWorkflow(accessoryID: prompt.accessory.id) {
                    prepareWireGuardConnectionForUSBAttachment(record)
                }
            case .assetsRequired:
                accessoriesAwaitingAssetSetup.insert(prompt.accessory.id)
            }
        } else {
            appendEventLog(
                "USB attach declined for registry \(prompt.accessory.registryIDText).",
                level: .debug,
                category: .usb
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
                level: .debug,
                category: .wireGuard
            )
            return
        }

        wireGuardConnectionPrompt = nil
        defer { presentNextUSBAttachmentPromptIfNeeded() }

        guard accepted else {
            appendEventLog(
                "Automatic WireGuard connection declined for USB registry " +
                    "\(prompt.accessory.registryIDText).",
                level: .debug,
                category: .wireGuard
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
                level: .debug,
                category: .wireGuard
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
            level: .debug,
            category: .wireGuard
        )
        attemptPendingWireGuardConnectionIfReady()
    }

    func prepareForApplicationTermination(
        disconnectWireGuard: Bool = true
    ) async {
        isPreparingForApplicationTermination = true
        shouldResumeAccessoryMonitoringAfterOnboarding = false
        appendEventLog(
            "Application terminating.",
            level: .debug,
            category: .application
        )
        cancelAutomaticWireGuardConnection(reason: "application termination")
        pendingWireGuardConnectionAccessoryID = nil
        wireGuardConnectionPrompt = nil
        await wireGuardSession.prepareForApplicationTermination(
            disconnectTunnel: disconnectWireGuard
        )
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.invalidate()
        await withCheckedContinuation { continuation in
            usbCoordinator.stopMonitoring(reason: "Application terminating.") {
                continuation.resume()
            }
        }
    }

    func refreshHostWireGuardTunnelStatus() {
        refreshRuntimeEntitlements()
        refreshWireGuardSystemExtensionStatus()
        guard !wireGuardSession.hostTunnelStatus.isTransitioning else {
            appendEventLog(
                "Host WireGuard status refresh skipped during a tunnel transition.",
                level: .debug,
                category: .wireGuard
            )
            return
        }
        guard runtimeEntitlements.packetTunnelProvider else {
            wireGuardSession.updateHostTunnelStatus(.missingPacketTunnelEntitlement)
            appendEventLog(
                "Host WireGuard status not refreshed: missing NetworkExtension entitlement.",
                level: .error,
                category: .wireGuard
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
                action: "network extension activation",
                category: .wireGuard
            )
            wireGuardSession.updateSystemExtensionStatus(
                .failed("System Extension installation entitlement is missing.")
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
        guard !isPreparingForApplicationTermination else {
            return
        }
        wireGuardSession.openSystemExtensionSettings()
    }

    @discardableResult
    func connectHostWireGuardTunnel() -> Bool {
        refreshRuntimeEntitlements()

        guard runtimeState == .running, vmCoordinator.canSendConsoleInput else {
            wireGuardSession.updateHostTunnelStatus(.unconfigured)
            appendEventLog(
                "Host WireGuard tunnel not started: VM is not running.",
                level: .warning,
                category: .wireGuard
            )
            return false
        }
        guard wireGuardSession.validateConnectionInputs() else {
            return false
        }
        guard runtimeEntitlements.packetTunnelProvider else {
            reportMissingEntitlement(
                .packetTunnelProvider,
                action: "Host WireGuard tunnel start",
                category: .wireGuard
            )
            wireGuardSession.updateHostTunnelStatus(.missingPacketTunnelEntitlement)
            return false
        }
        guard runtimeEntitlements.systemExtensionInstall else {
            reportMissingEntitlement(
                .systemExtensionInstall,
                action: "Host WireGuard tunnel start",
                category: .wireGuard
            )
            wireGuardSession.updateHostTunnelStatus(
                .missingSystemExtensionInstallEntitlement
            )
            return false
        }

        return wireGuardSession.connect()
    }

    func connectHostWireGuardTunnelWithAutomaticDummyEthernet() {
        guard canConnectHostWireGuardTunnel else {
            return
        }
        guard let prepareDummyEthernetForWireGuardConnection else {
            connectHostWireGuardTunnel()
            return
        }
        guard automaticWireGuardConnectionTask == nil else {
            return
        }

        appendEventLog(
            "Preparing Dummy Ethernet before starting the Host WireGuard tunnel.",
            level: .debug,
            category: .wireGuard
        )
        automaticWireGuardConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.automaticWireGuardConnectionTask = nil }
            let isDummyEthernetActive =
                await prepareDummyEthernetForWireGuardConnection()

            guard !Task.isCancelled else { return }
            guard isDummyEthernetActive else {
                self.appendEventLog(
                    "Host WireGuard tunnel not started: Dummy Ethernet did not become active.",
                    level: .error,
                    category: .wireGuard
                )
                return
            }

            self.refreshRuntimeEntitlements()
            guard self.canConnectHostWireGuardTunnel else { return }
            guard self.connectHostWireGuardTunnel() else { return }

            for await status in self.wireGuardSession.$hostTunnelStatus.values {
                guard !Task.isCancelled else { return }

                switch status {
                case .connected:
                    self.appendEventLog(
                        "Host WireGuard tunnel connected; stopping automatically prepared Dummy Ethernet.",
                        level: .debug,
                        category: .wireGuard
                    )
                    self.deactivateDummyEthernetAfterWireGuardConnection?()
                    return
                case .failed, .disconnecting:
                    return
                default:
                    continue
                }
            }
        }
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
        appendEventLog(
            "Onboarding completed.",
            level: .info,
            category: .application
        )

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
            appendEventLog(
                "App settings reset rejected: resetInProgress=\(isResettingAppSettings), " +
                    "vmAssetOperationActive=\(assetProvider.isBusy).",
                level: .debug,
                category: .application
            )
            return false
        }

        isResettingAppSettings = true
        defer { isResettingAppSettings = false }

        cancelAutomaticWireGuardConnection(reason: "app settings reset")
        guard await wireGuardSession.disconnectAndWait() else {
            resetStatusMessage = String(
                localized: "Could not stop the WireGuard tunnel before resetting app settings."
            )
            appendEventLog(
                "App settings reset cancelled: Host WireGuard tunnel could not be stopped.",
                level: .error,
                category: .wireGuard
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
            self.appendEventLog(
                "VM stop workflow snapshot: pendingUSB=" +
                    "\(self.pendingAttachmentAccessoryID.map(Self.registryIDText) ?? "none"), " +
                    "startAfterStop=\(self.shouldStartPendingAttachmentAfterStop), " +
                    "restartWillStart=\(self.restartWillStartVM), pendingWireGuard=" +
                    "\(self.pendingWireGuardConnectionAccessoryID.map(Self.registryIDText) ?? "none").",
                level: .debug,
                category: .application
            )
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
        usbCoordinator.onEventLog = { [weak self] message, level in
            self?.appendEventLog(message, level: level, category: .usb)
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
            appendEventLog(
                "Queued WireGuard connection cleared because the provider is already " +
                    "connecting or connected.",
                level: .debug,
                category: .wireGuard
            )
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
            level: .debug,
            category: .wireGuard
        )
        connectHostWireGuardTunnelWithAutomaticDummyEthernet()
    }

    private func cancelPendingWireGuardConnection(reason: String) {
        cancelAutomaticWireGuardConnection(reason: reason)
        guard let accessoryID = pendingWireGuardConnectionAccessoryID
                ?? wireGuardConnectionPrompt?.accessory.id else {
            return
        }

        pendingWireGuardConnectionAccessoryID = nil
        wireGuardConnectionPrompt = nil
        appendEventLog(
            "Pending WireGuard connection cancelled for USB registry " +
                "\(Self.registryIDText(accessoryID)): \(reason).",
            level: .debug,
            category: .wireGuard
        )
    }

    private func cancelAutomaticWireGuardConnection(reason: String) {
        guard let task = automaticWireGuardConnectionTask else {
            return
        }

        task.cancel()
        appendEventLog(
            "Pending automatic Host WireGuard connection cancelled: \(reason).",
            level: .debug,
            category: .wireGuard
        )
    }

    private func offerAttachmentForAvailableAccessory(_ record: USBAccessoryRecord) {
        guard !isOnboardingPresented else {
            appendEventLog(
                "USB attach prompt deferred while onboarding is presented.",
                level: .debug,
                category: .usb
            )
            return
        }

        guard appPreferences.shouldAskToAttachDetectedUSBDevices else {
            appendEventLog(
                "USB attach prompt skipped for registry \(record.registryIDText): " +
                    "asking on device detection is disabled.",
                level: .debug,
                category: .usb
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

    private func beginAttachmentWorkflow(
        accessoryID: UInt64
    ) -> USBAccessoryRecord? {
        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = String(localized: "Wait for the current USB attachment workflow to finish.")
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): another workflow is active.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard !assetProvider.isBusy else {
            statusMessage = String(localized: "Wait for VM asset installation to finish before attaching USB.")
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): a VM asset operation is active.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard !attachmentRequiresVMStopRetry else {
            statusMessage = String(localized: "The VM did not stop cleanly. Retry Stop before attaching a USB accessory.")
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): failed VM cleanup is pending.",
                level: .debug,
                category: .usb
            )
            presentNextUSBAttachmentPromptIfNeeded()
            return nil
        }

        if attachedAccessoryID == accessoryID {
            statusMessage = String(localized: "The selected USB accessory is already attached.")
            appendEventLog(
                "USB attachment workflow ignored for registry " +
                    "\(Self.registryIDText(accessoryID)): accessory is already attached.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard vmSessionAccessoryID == nil else {
            statusMessage = String(localized: "Detach the current USB accessory before attaching another USB accessory.")
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): this VM session already used a USB accessory.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard let record = accessories.first(where: { $0.id == accessoryID }) else {
            statusMessage = String(localized: "The selected USB accessory is no longer available.")
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): accessory is unavailable.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard hasConfiguredVMAssets else {
            enqueueUSBAttachmentPrompt(
                USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
            )
            return nil
        }

        pendingAttachmentAccessoryID = accessoryID
        pendingAttachmentToken = UUID()
        pendingAttachmentStartedVM = false
        shouldStartPendingAttachmentAfterStop = false
        usbCoordinator.selectAccessory(id: accessoryID)
        continuePendingAttachmentIfPossible()
        guard pendingAttachmentAccessoryID == accessoryID
                || attachedAccessoryID == accessoryID else {
            return nil
        }
        return record
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
                        level: .debug,
                        category: .usb
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
            level: .debug,
            category: .usb
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
        appendEventLog(
            "Pending USB attachment cancelled: \(reason).",
            level: .debug,
            category: .usb
        )
        if presentNextPrompt {
            presentNextUSBAttachmentPromptIfNeeded()
        }
    }

    private func startAccessoryMonitoring(reason: String) {
        guard !isOnboardingPresented else {
            shouldResumeAccessoryMonitoringAfterOnboarding = true
            appendEventLog(
                "USB listener start deferred while onboarding is presented: \(reason).",
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

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }
}
