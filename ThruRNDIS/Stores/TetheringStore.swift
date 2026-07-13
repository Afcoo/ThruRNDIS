/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Foundation

private enum AlpineBootDefaults {
    static let initramfsModules = "virtio_pci,virtio_mmio,virtio_console"
    static let initramfsKernelCommandLine = "console=hvc0 rdinit=/sbin/init modules=\(initramfsModules)"
}

private enum VMMemoryDefaults {
    static let minimumMiB = 256
    static let maximumMiB = 16 * 1024
    static let defaultMiB = 1024
    static let stepMiB = 256
}

struct OnboardingPresentationRequest {
    let sequence: Int
    let restart: Bool
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published var diskImageURL: URL? {
        didSet { persistFileURL(diskImageURL, forKey: DefaultsKey.diskImageURLPath) }
    }
    @Published var cpuCount = 1 {
        didSet { UserDefaults.standard.set(cpuCount, forKey: DefaultsKey.cpuCount) }
    }
    @Published var memorySizeMiB = VMMemoryDefaults.defaultMiB {
        didSet { UserDefaults.standard.set(memorySizeMiB, forKey: DefaultsKey.memorySizeMiB) }
    }
    @Published var kernelCommandLine = AlpineBootDefaults.initramfsKernelCommandLine {
        didSet { UserDefaults.standard.set(kernelCommandLine, forKey: DefaultsKey.kernelCommandLine) }
    }

    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private(set) var isRestartingVirtualMachine = false
    @Published private(set) var statusMessage = "Install or select VM assets to begin."
    @Published private(set) var runtimeEntitlements = RuntimeEntitlementSnapshot.current
    @Published private(set) var accessories: [USBAccessoryRecord] = []
    @Published private(set) var isAccessoryMonitoring = false
    @Published var selectedAccessoryID: UInt64? {
        didSet {
            guard !isSyncingUSBState else { return }
            usbCoordinator.selectAccessory(id: selectedAccessoryID)
        }
    }
    @Published private(set) var attachedAccessoryID: UInt64?
    @Published private(set) var vmSessionAccessoryID: UInt64?
    @Published private(set) var usbAttachmentPrompt: USBAttachmentPrompt?
    @Published private(set) var consoleText = ""
    @Published private(set) var consoleOutputData = Data()
    @Published private(set) var consoleOutputSequence = 0
    @Published private(set) var consoleResetSequence = 0
    @Published private(set) var eventLog = ""
    @Published private(set) var wireGuardSettings: WireGuardSettings
    @Published private(set) var wireGuardStatusMessage = "Loading WireGuard configuration from Application Support."
    @Published private(set) var hasCompletedOnboarding = false
    @Published private(set) var onboardingPresentationRequest = OnboardingPresentationRequest(
        sequence: 0,
        restart: false
    )
    @Published private(set) var launchAtLoginSnapshot = LaunchAtLoginService.snapshot()
    @Published private(set) var preferencesStatusMessage = ""

    let guestMACAddress = "02:00:5E:10:00:02"

    private let vmCoordinator = VMCoordinator()
    private let usbCoordinator = USBAccessoryCoordinator()
    private let assetProvider: VMAssetProviding
    private let wireGuardConfStore: WireGuardConfStore
    private let wireGuardConfBuilder: WireGuardConfBuilder
    private var wireGuardKeyMaterial: WireGuardKeyMaterial?
    private var didRequestLaunchAccessoryMonitoring = false
    private var isSyncingUSBState = false
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
            && wireGuardSettings.hasKeyMaterial
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
        canEditVMConfiguration && !assetProvider.isBusy
    }

    var hasConfiguredVMAssets: Bool {
        assetProvider.hasConfiguredAssets
    }

    var shouldPresentOnboardingOnLaunch: Bool {
        !hasCompletedOnboarding
    }

    var memorySizeRangeMiB: ClosedRange<Int> {
        VMMemoryDefaults.minimumMiB...VMMemoryDefaults.maximumMiB
    }

    var memorySizeStepMiB: Int {
        VMMemoryDefaults.stepMiB
    }

    var memorySizeLabel: String {
        guard memorySizeMiB >= 1024 else {
            return "\(memorySizeMiB) MiB"
        }

        let wholeGiB = memorySizeMiB / 1024
        let remainderMiB = memorySizeMiB % 1024

        switch remainderMiB {
        case 0:
            return "\(wholeGiB) GiB"
        case 256:
            return "\(wholeGiB).25 GiB"
        case 512:
            return "\(wholeGiB).5 GiB"
        case 768:
            return "\(wholeGiB).75 GiB"
        default:
            return "\(memorySizeMiB) MiB"
        }
    }

    var canStartAccessoryMonitoring: Bool {
        hasConfiguredVMAssets
            && !assetProvider.isBusy
            && runtimeEntitlements.accessoryAccessUSB
            && usbCoordinator.canStartMonitoring
    }

    var canStopAccessoryMonitoring: Bool {
        pendingAttachmentAccessoryID == nil && usbCoordinator.canStopMonitoring
    }

    var canReloadAccessoryMonitoring: Bool {
        pendingAttachmentAccessoryID == nil
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
        guard hasConfiguredVMAssets,
              !assetProvider.isBusy,
              pendingAttachmentAccessoryID == nil,
              !attachmentRequiresVMStopRetry,
              let selectedAccessoryID else {
            return false
        }

        return usbCoordinator.canRequestAttachment(for: selectedAccessoryID)
    }

    var canDetachAccessory: Bool {
        usbCoordinator.canDetachAccessory(runtimeState: runtimeState)
    }

    func canRequestAttachment(for accessoryID: UInt64) -> Bool {
        pendingAttachmentAccessoryID == nil
            && usbAttachmentPrompt == nil
            && !attachmentRequiresVMStopRetry
            && hasConfiguredVMAssets
            && !assetProvider.isBusy
            && usbCoordinator.canRequestAttachment(for: accessoryID)
    }

    func canChooseAccessoryForAttachment(_ accessoryID: UInt64) -> Bool {
        pendingAttachmentAccessoryID == nil
            && usbAttachmentPrompt == nil
            && !attachmentRequiresVMStopRetry
            && !assetProvider.isBusy
            && usbCoordinator.canRequestAttachment(for: accessoryID)
    }

    var canExportWireGuardConfiguration: Bool {
        wireGuardSettings.hasKeyMaterial && wireGuardSettings.endpoint != nil
    }

    var wireGuardHostConfiguration: String {
        guard let wireGuardKeyMaterial else {
            return """
            # WireGuard key material is unavailable in Application Support.
            """
        }

        return wireGuardConfBuilder.clientConfiguration(
            keyMaterial: wireGuardKeyMaterial,
            endpoint: wireGuardSettings.endpoint
        )
    }

    init(assetProvider: VMAssetProviding) {
        let wireGuardConfStore = WireGuardConfStore()
        let wireGuardConfBuilder = WireGuardConfBuilder(elements: .defaults)
        self.assetProvider = assetProvider
        self.wireGuardConfStore = wireGuardConfStore
        self.wireGuardConfBuilder = wireGuardConfBuilder
        self.wireGuardSettings = wireGuardConfBuilder.settings()
        configureCoordinators()
        restoreDiskImageSelection()
        restoreVMSettings()
        prepareWireGuardConfiguration()
        restoreOnboardingState()
        appendRuntimeEntitlementSummary()
        appendScratchDiskSelectionSummaryIfNeeded()
    }

    func startAccessoryMonitoring() {
        guard hasConfiguredVMAssets, !assetProvider.isBusy else {
            statusMessage = assetProvider.isBusy
                ? "Wait for VM asset installation to finish before starting the USB listener."
                : "Install or select valid VM assets before starting the USB listener."
            return
        }

        startAccessoryMonitoring(reason: "manual request")
    }

    func startAccessoryMonitoringOnLaunch() {
        guard !didRequestLaunchAccessoryMonitoring else {
            return
        }

        didRequestLaunchAccessoryMonitoring = true
        startAccessoryMonitoring(reason: "app launch")
    }

    func stopAccessoryMonitoring() {
        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = "Wait for the current USB attachment workflow before stopping the listener."
            return
        }
        usbCoordinator.stopMonitoring(reason: "User stopped USB listener.")
    }

    func reloadAccessoryMonitoring() {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB listener reload")
            return
        }

        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = "Wait for the current USB attachment workflow before reloading the listener."
            return
        }

        usbCoordinator.reloadMonitoring(reason: "user request")
    }

    @discardableResult
    func startVirtualMachine() -> Bool {
        refreshRuntimeEntitlements()

        guard !assetProvider.isBusy else {
            statusMessage = "Wait for VM asset installation to finish before starting the VM."
            return false
        }

        let bootAssets: VMAssetBootAssets
        do {
            bootAssets = try assetProvider.validatedBootAssets()
        } catch {
            statusMessage = error.localizedDescription
            appendEvent("VM asset validation failed before VM start: \(error.localizedDescription)")
            return false
        }

        guard wireGuardSettings.hasKeyMaterial else {
            statusMessage = "Fix the WireGuard configuration error before starting the VM."
            return false
        }

        guard vmCoordinator.canStart else {
            statusMessage = "Wait for the current VM transition to finish."
            return false
        }

        guard runtimeEntitlements.virtualization else {
            reportMissingEntitlement(.virtualization, action: "VM start")
            return false
        }

        guard reloadWireGuardConfigurationFromApplicationSupport(
            reason: "VM starting",
            requireExisting: true
        ) else {
            statusMessage = "Fix the WireGuard configuration error before starting the VM."
            return false
        }

        clearWireGuardEndpoint(reason: "VM starting")
        clearConsoleForVMStart()
        usbCoordinator.resetForVMStart()
        syncUSBState()

        let bootCommandLine = normalizedBootCommandLine()
        if bootCommandLine != kernelCommandLine {
            kernelCommandLine = bootCommandLine
            appendEvent("Adjusted kernel arguments for initramfs-only boot.")
        }

        let input = VMCoordinatorStartInput(
            kernelURL: bootAssets.kernelURL,
            initialRamdiskURL: bootAssets.initialRamdiskURL,
            diskImageURL: diskImageURL,
            wireGuardConfigurationDirectoryURL: wireGuardConfStore.sharedDirectoryURL,
            cpuCount: cpuCount,
            memorySizeMiB: memorySizeMiB,
            bootCommandLine: bootCommandLine,
            guestMACAddress: guestMACAddress
        )

        appendEvent("Kernel asset: \(bootAssets.kernelURL.path)")
        appendEvent("Initramfs asset: \(bootAssets.initialRamdiskURL.path)")
        appendEvent("Kernel arguments: \(bootCommandLine)")
        vmCoordinator.start(input: input)
        return true
    }

    func stopVirtualMachine() {
        isRestartingVirtualMachine = false
        cancelPendingAttachment(reason: "VM stop requested by user")
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
            statusMessage = "Select a USB accessory."
            return
        }

        requestAttachAccessory(id: selectedAccessoryID)
    }

    func requestAttachAccessory(id accessoryID: UInt64) {
        refreshRuntimeEntitlements()

        guard !assetProvider.isBusy else {
            statusMessage = "Wait for VM asset installation to finish before attaching USB."
            return
        }

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB attach")
            return
        }

        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = "Wait for the current USB attachment workflow to finish."
            return
        }

        guard !attachmentRequiresVMStopRetry else {
            statusMessage = "The VM did not stop cleanly. Retry Stop before attaching a USB accessory."
            return
        }

        guard let record = accessories.first(where: { $0.id == accessoryID }) else {
            statusMessage = "The selected USB accessory is no longer available."
            return
        }

        guard hasConfiguredVMAssets else {
            enqueueUSBAttachmentPrompt(
                USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
            )
            return
        }

        if let sessionAccessoryID = vmSessionAccessoryID,
           sessionAccessoryID != accessoryID,
           runtimeState == .running || runtimeState == .starting || runtimeState == .stopping {
            let previousRecord = accessories.first { $0.id == sessionAccessoryID }
            enqueueUSBAttachmentPrompt(
                USBAttachmentPrompt(
                    accessory: record,
                    kind: .replace(
                        previousAccessoryID: sessionAccessoryID,
                        previousUSBIDText: previousRecord?.usbIDText ?? Self.registryIDText(sessionAccessoryID),
                        isCurrentlyAttached: attachedAccessoryID == sessionAccessoryID
                    )
                )
            )
            return
        }

        beginAttachmentWorkflow(accessoryID: accessoryID, requiresRestart: false)
    }

    func detachAccessory() {
        usbCoordinator.detachAccessory(from: vmCoordinator.virtualMachine)
    }

    func resolveUSBAttachmentPrompt(accepted: Bool) {
        guard let prompt = usbAttachmentPrompt else {
            return
        }

        usbAttachmentPrompt = nil
        promptedAccessoryIDs.remove(prompt.accessory.id)

        if accepted {
            switch prompt.kind {
            case .attach:
                beginAttachmentWorkflow(accessoryID: prompt.accessory.id, requiresRestart: false)
            case .replace:
                beginAttachmentWorkflow(accessoryID: prompt.accessory.id, requiresRestart: true)
            case .assetsRequired:
                accessoriesAwaitingAssetSetup.insert(prompt.accessory.id)
                requestOnboardingPresentation(restart: false)
            }
        } else {
            appendEvent("USB attach declined for registry \(prompt.accessory.registryIDText).")
        }

        presentNextUSBAttachmentPromptIfNeeded()
    }

    func prepareForApplicationTermination() {
        appendEvent("Application terminating.")
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.invalidate()
        usbCoordinator.stopMonitoring(reason: "Application terminating.")
    }

    func reloadWireGuardConfiguration() {
        _ = reloadWireGuardConfigurationFromApplicationSupport(
            reason: "manual request",
            requireExisting: true
        )
    }

    func openWireGuardConfigurationFolder() {
        let directoryURL = wireGuardConfStore.files.wireGuardDirectoryURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            wireGuardStatusMessage = "WireGuard configuration folder was not found."
            appendEvent("WireGuard configuration folder not opened because it does not exist: \(directoryURL.path)")
            return
        }

        guard NSWorkspace.shared.open(directoryURL) else {
            wireGuardStatusMessage = "Could not open the WireGuard configuration folder."
            appendEvent("WireGuard configuration folder open failed: \(directoryURL.path)")
            return
        }

        wireGuardStatusMessage = "Opened the WireGuard configuration folder."
        appendEvent("Opened WireGuard configuration folder: \(directoryURL.path)")
    }

    func copyWireGuardConfiguration() {
        guard canExportWireGuardConfiguration else {
            wireGuardStatusMessage = "Wait for THRURNDIS_WG_ENDPOINT before copying the host configuration."
            appendEvent("WireGuard configuration not copied: VM endpoint is unknown.")
            return
        }

        Clipboard.copy(wireGuardHostConfiguration)
        wireGuardStatusMessage = "WireGuard host configuration copied."
        appendEvent("WireGuard host configuration copied to clipboard.")
    }

    func saveWireGuardConfiguration() {
        guard canExportWireGuardConfiguration else {
            wireGuardStatusMessage = "Wait for THRURNDIS_WG_ENDPOINT before saving the host configuration."
            appendEvent("WireGuard configuration not saved: VM endpoint is unknown.")
            return
        }

        guard let url = FilePicker.chooseSaveFile(
            title: "Save WireGuard Configuration",
            defaultName: "thrurndis.conf"
        ) else {
            return
        }

        do {
            try wireGuardHostConfiguration.write(to: url, atomically: true, encoding: .utf8)
            wireGuardStatusMessage = "WireGuard host configuration saved."
            appendEvent("WireGuard host configuration saved to \(url.path).")
        } catch {
            wireGuardStatusMessage = error.localizedDescription
            appendEvent("WireGuard configuration save failed: \(error.localizedDescription)")
        }
    }

    func clearWireGuardEndpoint() {
        clearWireGuardEndpoint(reason: "manual request")
    }

    func clearConsole() {
        consoleText = ""
        consoleOutputData = Data()
        consoleOutputSequence = 0
        consoleResetSequence &+= 1
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        vmCoordinator.sendConsoleBytes(data)
    }

    func clearEventLog() {
        eventLog = ""
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            launchAtLoginSnapshot = try LaunchAtLoginService.setEnabled(isEnabled)
            preferencesStatusMessage = launchAtLoginSnapshot.statusText
        } catch {
            launchAtLoginSnapshot = LaunchAtLoginService.snapshot()
            preferencesStatusMessage = "Could not update Launch at Login: \(error.localizedDescription)"
            appendEvent(preferencesStatusMessage)
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginSnapshot = LaunchAtLoginService.snapshot()
        preferencesStatusMessage = ""
    }

    func openLoginItemsSettings() {
        LaunchAtLoginService.openSystemSettings()
    }

    func requestOnboardingPresentation(restart: Bool = true) {
        onboardingPresentationRequest = OnboardingPresentationRequest(
            sequence: onboardingPresentationRequest.sequence + 1,
            restart: restart
        )
    }

    func completeOnboarding() {
        guard hasConfiguredVMAssets, !assetProvider.isBusy else {
            statusMessage = "Install or select valid VM assets before finishing onboarding."
            return
        }

        UserDefaults.standard.set(Self.currentOnboardingVersion, forKey: DefaultsKey.onboardingVersion)
        hasCompletedOnboarding = true
        appendEvent("Onboarding completed.")

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

        presentNextUSBAttachmentPromptIfNeeded()
    }

    @discardableResult
    func resetAppSettings() -> Bool {
        guard canResetAppSettings else {
            preferencesStatusMessage = "Stop the VM before resetting app settings."
            return false
        }

        do {
            try wireGuardConfStore.removeConfigurationDirectory()
        } catch {
            preferencesStatusMessage = "Could not remove WireGuard configuration: \(error.localizedDescription)"
            wireGuardStatusMessage = preferencesStatusMessage
            appendEvent("App settings reset cancelled: \(preferencesStatusMessage)")
            return false
        }

        cancelPendingAttachment(reason: "app settings reset")
        queuedUSBAttachmentPrompts.removeAll()
        promptedAccessoryIDs.removeAll()
        accessoriesAwaitingAssetSetup.removeAll()
        usbAttachmentPrompt = nil

        diskImageURL = nil
        cpuCount = 1
        memorySizeMiB = VMMemoryDefaults.defaultMiB
        kernelCommandLine = AlpineBootDefaults.initramfsKernelCommandLine

        UserDefaults.standard.removeObject(forKey: DefaultsKey.diskImageURLPath)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.cpuCount)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.memorySizeMiB)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.kernelCommandLine)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.onboardingVersion)

        hasCompletedOnboarding = false
        wireGuardKeyMaterial = nil
        wireGuardSettings = wireGuardConfBuilder.settings()
        wireGuardStatusMessage = "WireGuard configuration removed; new keys will be created after restart."
        statusMessage = "App settings reset. Install or select VM assets to continue."

        do {
            launchAtLoginSnapshot = try LaunchAtLoginService.setEnabled(false)
            preferencesStatusMessage = "App settings were reset."
        } catch {
            launchAtLoginSnapshot = LaunchAtLoginService.snapshot()
            preferencesStatusMessage = "Settings reset, but Launch at Login could not be disabled: \(error.localizedDescription)"
        }

        appendEvent("App settings and WireGuard configuration were reset; VM asset files were not deleted.")
        return true
    }

    func recordVMAssetEvent(_ message: String) {
        appendEvent(message)
    }

    func assetAvailabilityDidChange() {
        objectWillChange.send()
        presentNextUSBAttachmentPromptIfNeeded()
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
                self.presentNextUSBAttachmentPromptIfNeeded()
            case .failed:
                self.restartWillStartVM = false
                self.cancelPendingAttachment(reason: "VM start or runtime failure")
            default:
                break
            }
        }
        vmCoordinator.onEvent = { [weak self] message in
            self?.appendEvent(message)
        }
        vmCoordinator.onConsoleOutput = { [weak self] data in
            self?.appendConsole(data)
        }
        vmCoordinator.onUSBPassthroughDisconnect = { [weak self] device in
            self?.usbCoordinator.handlePassthroughDisconnect(device: device)
        }
        vmCoordinator.onStopped = { [weak self] in
            guard let self else { return }
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
            self.presentNextUSBAttachmentPromptIfNeeded()
        }
        usbCoordinator.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }
        usbCoordinator.onEvent = { [weak self] message in
            self?.appendEvent(message)
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

    private func offerAttachmentForAvailableAccessory(_ record: USBAccessoryRecord) {
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
        guard usbAttachmentPrompt == nil,
              pendingAttachmentAccessoryID == nil,
              !restartWillStartVM,
              !assetProvider.isBusy,
              !usbCoordinator.isDetachPending else {
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
            usbAttachmentPrompt = attachmentPrompt(for: currentRecord)
            return
        }
    }

    private func attachmentPrompt(for record: USBAccessoryRecord) -> USBAttachmentPrompt {
        guard hasConfiguredVMAssets else {
            return USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
        }

        if let sessionAccessoryID = vmSessionAccessoryID,
           sessionAccessoryID != record.id,
           runtimeState == .running || runtimeState == .starting || runtimeState == .stopping {
            let previousRecord = accessories.first { $0.id == sessionAccessoryID }
            return USBAttachmentPrompt(
                accessory: record,
                kind: .replace(
                    previousAccessoryID: sessionAccessoryID,
                    previousUSBIDText: previousRecord?.usbIDText ?? Self.registryIDText(sessionAccessoryID),
                    isCurrentlyAttached: attachedAccessoryID == sessionAccessoryID
                )
            )
        }

        return USBAttachmentPrompt(accessory: record, kind: .attach)
    }

    private func beginAttachmentWorkflow(accessoryID: UInt64, requiresRestart: Bool) {
        guard pendingAttachmentAccessoryID == nil else {
            statusMessage = "Wait for the current USB attachment workflow to finish."
            return
        }

        guard !assetProvider.isBusy else {
            statusMessage = "Wait for VM asset installation to finish before attaching USB."
            return
        }

        guard !attachmentRequiresVMStopRetry else {
            statusMessage = "The VM did not stop cleanly. Retry Stop before attaching a USB accessory."
            presentNextUSBAttachmentPromptIfNeeded()
            return
        }

        guard hasConfiguredVMAssets else {
            if let record = accessories.first(where: { $0.id == accessoryID }) {
                enqueueUSBAttachmentPrompt(
                    USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
                )
            }
            return
        }

        guard accessories.contains(where: { $0.id == accessoryID }) else {
            statusMessage = "The selected USB accessory is no longer available."
            return
        }

        if attachedAccessoryID == accessoryID {
            statusMessage = "The selected USB accessory is already attached."
            return
        }

        let activeSessionUsesDifferentAccessory = vmSessionAccessoryID.map { $0 != accessoryID } == true
            && (runtimeState == .running || runtimeState == .starting || runtimeState == .stopping)

        if activeSessionUsesDifferentAccessory, !requiresRestart,
           let record = accessories.first(where: { $0.id == accessoryID }),
           let sessionAccessoryID = vmSessionAccessoryID {
            let previousRecord = accessories.first { $0.id == sessionAccessoryID }
            enqueueUSBAttachmentPrompt(
                USBAttachmentPrompt(
                    accessory: record,
                    kind: .replace(
                        previousAccessoryID: sessionAccessoryID,
                        previousUSBIDText: previousRecord?.usbIDText ?? Self.registryIDText(sessionAccessoryID),
                        isCurrentlyAttached: attachedAccessoryID == sessionAccessoryID
                    )
                )
            )
            return
        }

        selectedAccessoryID = accessoryID
        pendingAttachmentAccessoryID = accessoryID
        pendingAttachmentToken = UUID()
        pendingAttachmentStartedVM = false
        shouldStartPendingAttachmentAfterStop = false

        guard requiresRestart && activeSessionUsesDifferentAccessory else {
            continuePendingAttachmentIfPossible()
            return
        }

        switch runtimeState {
        case .running, .starting:
            if attachedAccessoryID != nil {
                let workflowToken = pendingAttachmentToken
                usbCoordinator.detachAccessory(from: vmCoordinator.virtualMachine) { [weak self] success in
                    guard let self,
                          self.pendingAttachmentToken == workflowToken else {
                        return
                    }

                    guard success else {
                        self.cancelPendingAttachment(reason: "USB replacement detach failed")
                        return
                    }

                    self.usbCoordinator.prepareForIntentionalVMStop()
                    self.restartVirtualMachine(
                        reason: "USB replacement",
                        requiresPendingAttachment: true
                    )
                }
            } else {
                usbCoordinator.prepareForIntentionalVMStop()
                restartVirtualMachine(
                    reason: "USB replacement after a prior device in this VM session",
                    requiresPendingAttachment: true
                )
            }
        case .stopping:
            shouldStartPendingAttachmentAfterStop = true
        case .idle, .stopped, .failed:
            continuePendingAttachmentIfPossible()
        }
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
            statusMessage = "The USB accessory became unavailable before it could be attached."
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

                if !success {
                    self.appendEvent("Approved USB attach did not complete for registry \(Self.registryIDText(accessoryID)).")
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

    private func restartVirtualMachine(
        reason: String,
        requiresPendingAttachment: Bool = false
    ) {
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

            if requiresPendingAttachment, self.pendingAttachmentAccessoryID == nil {
                self.isRestartingVirtualMachine = false
                self.statusMessage = "USB target disconnected; VM restart cancelled."
                self.presentNextUSBAttachmentPromptIfNeeded()
                return
            }

            if requiresPendingAttachment {
                self.pendingAttachmentStartedVM = true
            }
            if !self.startVirtualMachine() {
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

        if pendingAttachmentAccessoryID != nil {
            appendEvent("Replacing the pending USB attachment after an unexpected USB detach.")
        }
        pendingAttachmentAccessoryID = accessories.contains(where: { $0.id == accessoryID })
            ? accessoryID
            : nil
        pendingAttachmentToken = pendingAttachmentAccessoryID == nil ? nil : UUID()
        pendingAttachmentStartedVM = false
        shouldStartPendingAttachmentAfterStop = false
        usbCoordinator.prepareForIntentionalVMStop()
        restartVirtualMachine(
            reason: reason,
            requiresPendingAttachment: false
        )
    }

    private func cancelPendingAttachment(
        reason: String,
        presentNextPrompt: Bool = true
    ) {
        guard pendingAttachmentAccessoryID != nil || shouldStartPendingAttachmentAfterStop else {
            return
        }

        pendingAttachmentAccessoryID = nil
        pendingAttachmentToken = nil
        pendingAttachmentStartedVM = false
        shouldStartPendingAttachmentAfterStop = false
        appendEvent("Pending USB attachment cancelled: \(reason).")
        if presentNextPrompt {
            presentNextUSBAttachmentPromptIfNeeded()
        }
    }

    private func startAccessoryMonitoring(reason: String) {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB listener")
            return
        }

        usbCoordinator.startMonitoring(reason: reason)
    }

    private func syncUSBState() {
        isSyncingUSBState = true
        accessories = usbCoordinator.accessories
        isAccessoryMonitoring = usbCoordinator.isAccessoryMonitoring
        selectedAccessoryID = usbCoordinator.selectedAccessoryID
        attachedAccessoryID = usbCoordinator.attachedAccessoryID
        vmSessionAccessoryID = usbCoordinator.vmSessionAccessoryID
        isSyncingUSBState = false
    }

    private func restoreDiskImageSelection() {
        if let restoredDiskURL = restoredFileURL(forKey: DefaultsKey.diskImageURLPath),
           restoredDiskURL.pathExtension.localizedCaseInsensitiveCompare("iso") != .orderedSame {
            diskImageURL = restoredDiskURL
        } else {
            diskImageURL = nil
        }
    }

    private func restoreVMSettings() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: DefaultsKey.cpuCount) != nil {
            cpuCount = min(max(defaults.integer(forKey: DefaultsKey.cpuCount), 1), 8)
        }

        if defaults.object(forKey: DefaultsKey.memorySizeMiB) != nil {
            let restoredMemory = defaults.integer(forKey: DefaultsKey.memorySizeMiB)
            let clampedMemory = min(max(restoredMemory, VMMemoryDefaults.minimumMiB), VMMemoryDefaults.maximumMiB)
            memorySizeMiB = (clampedMemory / VMMemoryDefaults.stepMiB) * VMMemoryDefaults.stepMiB
        }

        if let restoredCommandLine = defaults.string(forKey: DefaultsKey.kernelCommandLine),
           !restoredCommandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kernelCommandLine = restoredCommandLine
        }
    }

    private func restoreOnboardingState() {
        let defaults = UserDefaults.standard
        let completedVersion = defaults.integer(forKey: DefaultsKey.onboardingVersion)

        if completedVersion >= Self.currentOnboardingVersion {
            hasCompletedOnboarding = true
            return
        }

        if completedVersion == 0, hasConfiguredVMAssets {
            defaults.set(Self.currentOnboardingVersion, forKey: DefaultsKey.onboardingVersion)
            hasCompletedOnboarding = true
            appendEvent("Existing VM asset selection migrated past first-run onboarding.")
            return
        }

        hasCompletedOnboarding = false
    }

    private func normalizedBootCommandLine() -> String {
        let blockedKeys: Set<String> = [
            "alpine_repo",
            "ip",
            "modules",
            "panic",
            "pkgs",
            "quiet",
            "ro",
            "root",
            "rootflags",
            "rootfstype",
            "rw"
        ]

        var tokens = kernelCommandLine
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                let key = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                return !blockedKeys.contains(key) && key != "rdinit"
            }

        if !tokens.contains(where: { $0.hasPrefix("console=") }) {
            tokens.insert("console=hvc0", at: 0)
        }

        let rdinitInsertIndex = min(tokens.lastIndex(where: { $0.hasPrefix("console=") }).map { $0 + 1 } ?? 0, tokens.count)
        tokens.insert("rdinit=/sbin/init", at: rdinitInsertIndex)

        let moduleToken = "modules=\(AlpineBootDefaults.initramfsModules)"
        let insertIndex = min(
            tokens.lastIndex(where: { $0.hasPrefix("console=") || $0.hasPrefix("rdinit=") }).map { $0 + 1 } ?? tokens.count,
            tokens.count
        )
        tokens.insert(moduleToken, at: insertIndex)

        return tokens.joined(separator: " ")
    }

    private func appendScratchDiskSelectionSummaryIfNeeded() {
        if let diskImageURL {
            appendEvent("Restored optional scratch disk selection: \(diskImageURL.path).")
        }
    }

    private func prepareWireGuardConfiguration() {
        do {
            let prepared = try wireGuardConfStore.prepareConfigurationIfNeeded(
                builder: wireGuardConfBuilder
            )
            wireGuardKeyMaterial = prepared.keyMaterial
            wireGuardSettings = wireGuardConfBuilder.settings(
                keyMaterial: prepared.keyMaterial,
                endpoint: wireGuardSettings.endpoint
            )
            wireGuardStatusMessage = "WireGuard configuration is ready."
            appendEvent("Prepared WireGuard configuration from Application Support keys: \(prepared.files.wireGuardDirectoryURL.path).")
        } catch {
            wireGuardKeyMaterial = nil
            wireGuardSettings = wireGuardConfBuilder.settings(
                endpoint: wireGuardSettings.endpoint
            )
            wireGuardStatusMessage = error.localizedDescription
            appendEvent("WireGuard key/configuration initialization failed without replacing existing keys: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func reloadWireGuardConfigurationFromApplicationSupport(
        reason: String,
        requireExisting: Bool
    ) -> Bool {
        do {
            let prepared = requireExisting
                ? try wireGuardConfStore.requireExistingConfiguration(
                    builder: wireGuardConfBuilder
                )
                : try wireGuardConfStore.prepareConfigurationIfNeeded(
                    builder: wireGuardConfBuilder
                )
            wireGuardKeyMaterial = prepared.keyMaterial
            wireGuardSettings = wireGuardConfBuilder.settings(
                keyMaterial: prepared.keyMaterial,
                endpoint: wireGuardSettings.endpoint
            )
            wireGuardStatusMessage = "Generated WireGuard configuration from Application Support keys."
            appendEvent("Regenerated WireGuard configuration from keys in \(prepared.files.wireGuardDirectoryURL.path): \(reason).")
            return true
        } catch {
            wireGuardKeyMaterial = nil
            wireGuardSettings = wireGuardConfBuilder.settings(
                endpoint: wireGuardSettings.endpoint
            )
            wireGuardStatusMessage = error.localizedDescription
            appendEvent("WireGuard configuration load failed: \(error.localizedDescription)")
            return false
        }
    }

    private func restoredFileURL(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func persistFileURL(_ url: URL?, forKey key: String) {
        if let path = url?.standardizedFileURL.path {
            UserDefaults.standard.set(path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func refreshRuntimeEntitlements() {
        let snapshot = RuntimeEntitlementSnapshot.current
        if snapshot != runtimeEntitlements {
            runtimeEntitlements = snapshot
            appendRuntimeEntitlementSummary()
        }
    }

    private func appendRuntimeEntitlementSummary() {
        let summary = RuntimeEntitlement.allCases.map { entitlement in
            "\(entitlement.rawValue)=\(runtimeEntitlements.has(entitlement) ? "present" : "missing")"
        }
        appendEvent("Runtime entitlements: \(summary.joined(separator: ", ")).")
    }

    private func reportMissingEntitlement(_ entitlement: RuntimeEntitlement, action: String) {
        statusMessage = "\(entitlement.label) entitlement missing."
        appendEvent("\(action) not started: missing \(entitlement.rawValue). The default ThruRNDIS scheme is for local UI builds; run the ThruRNDIS Runtime scheme with an approved provisioning profile to exercise this runtime path.")
    }

    private func clearWireGuardEndpoint(reason: String) {
        guard wireGuardSettings.endpoint != nil else {
            return
        }

        var settings = wireGuardSettings
        settings.endpoint = nil
        wireGuardSettings = settings
        wireGuardStatusMessage = "Waiting for THRURNDIS_WG_ENDPOINT from guest."
        appendEvent("WireGuard endpoint cleared: \(reason).")
    }

    private func updateWireGuardEndpoint(from text: String) {
        let marker = "THRURNDIS_WG_ENDPOINT="
        guard let markerRange = text.range(of: marker, options: [.backwards]) else {
            return
        }

        let suffix = text[markerRange.upperBound...]
        guard let token = suffix.split(whereSeparator: \.isWhitespace).first else {
            return
        }

        let endpoint = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard endpoint.contains(":"),
              endpoint != wireGuardSettings.endpoint else {
            return
        }

        var settings = wireGuardSettings
        settings.endpoint = endpoint
        wireGuardSettings = settings
        wireGuardStatusMessage = "WireGuard guest address discovered: \(endpoint)."
        appendEvent("WireGuard guest address discovered from guest console: \(endpoint).")
    }

    private func clearConsoleForVMStart() {
        consoleText = ""
        consoleOutputData = Data()
        consoleOutputSequence = 0
        consoleResetSequence &+= 1
    }

    private func appendConsole(_ data: Data) {
        appendConsoleOutputData(data)

        if let text = String(data: data, encoding: .utf8) {
            consoleText.append(text)
            updateWireGuardEndpoint(from: consoleText)
        } else {
            consoleText.append(data.map { String(format: "%02X", $0) }.joined(separator: " "))
            consoleText.append("\n")
        }
        trimConsoleIfNeeded()
    }

    private func appendEvent(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        eventLog.append("[\(timestamp)] \(message)\n")
        trimEventLogIfNeeded()
    }

    private func trimConsoleIfNeeded() {
        let maximumCharacters = 200_000
        if consoleText.count > maximumCharacters {
            consoleText.removeFirst(consoleText.count - maximumCharacters)
        }
    }

    private func appendConsoleOutputData(_ data: Data) {
        var outputData = consoleOutputData
        outputData.append(data)

        let maximumBytes = 4_000_000
        if outputData.count > maximumBytes {
            outputData.removeFirst(outputData.count - maximumBytes)
            consoleResetSequence &+= 1
        }

        consoleOutputData = outputData
        consoleOutputSequence &+= 1
    }

    private func trimEventLogIfNeeded() {
        let maximumCharacters = 60_000
        if eventLog.count > maximumCharacters {
            eventLog.removeFirst(eventLog.count - maximumCharacters)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let currentOnboardingVersion = 1

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }

    private enum DefaultsKey {
        static let diskImageURLPath = "VMAssets.diskImageURLPath"
        static let cpuCount = "VM.cpuCount"
        static let memorySizeMiB = "VM.memorySizeMiB"
        static let kernelCommandLine = "VM.kernelCommandLine"
        static let onboardingVersion = "Onboarding.completedVersion"
    }
}
