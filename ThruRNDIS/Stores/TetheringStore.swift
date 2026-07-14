/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Foundation

struct OnboardingPresentationRequest {
    let sequence: Int
    let restart: Bool
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private(set) var isRestartingVirtualMachine = false
    @Published private(set) var statusMessage = "Install or select VM assets to begin."
    @Published private(set) var runtimeEntitlements = RuntimeEntitlementSnapshot.current
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
    let consoleSession: ConsoleSessionStore
    let usbSession: USBSessionStore
    let vmConfiguration: VMConfigurationStore

    private let vmCoordinator: any VMCoordinating
    private let usbCoordinator: USBAccessoryCoordinator
    private let assetProvider: VMAssetProviding
    private let wireGuardConfStore: any WireGuardConfigurationStoring
    private let wireGuardConfBuilder: WireGuardConfBuilder
    private var wireGuardKeyMaterial: WireGuardKeyMaterial?
    private var didRequestLaunchAccessoryMonitoring = false
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

    init(
        assetProvider: VMAssetProviding,
        vmCoordinator: any VMCoordinating,
        usbCoordinator: USBAccessoryCoordinator,
        wireGuardConfStore: any WireGuardConfigurationStoring,
        wireGuardConfBuilder: WireGuardConfBuilder,
        consoleSession: ConsoleSessionStore,
        usbSession: USBSessionStore,
        vmConfiguration: VMConfigurationStore
    ) {
        self.assetProvider = assetProvider
        self.vmCoordinator = vmCoordinator
        self.usbCoordinator = usbCoordinator
        self.wireGuardConfStore = wireGuardConfStore
        self.wireGuardConfBuilder = wireGuardConfBuilder
        self.consoleSession = consoleSession
        self.usbSession = usbSession
        self.vmConfiguration = vmConfiguration
        self.wireGuardSettings = wireGuardConfBuilder.settings()
        configureCoordinators()
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

        let bootCommandLine = vmConfiguration.normalizedBootCommandLine()
        if bootCommandLine != vmConfiguration.kernelCommandLine {
            vmConfiguration.kernelCommandLine = bootCommandLine
            appendEvent("Adjusted kernel arguments for initramfs-only boot.")
        }

        let input = VMCoordinatorStartInput(
            kernelURL: bootAssets.kernelURL,
            initialRamdiskURL: bootAssets.initialRamdiskURL,
            diskImageURL: vmConfiguration.diskImageURL,
            wireGuardConfigurationDirectoryURL: wireGuardConfStore.sharedDirectoryURL,
            cpuCount: vmConfiguration.cpuCount,
            memorySizeMiB: vmConfiguration.memorySizeMiB,
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

    func selectAccessory(id: UInt64?) {
        usbCoordinator.selectAccessory(id: id)
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
                        previousDeviceName: previousRecord?.deviceName ?? "USB Device",
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
        guard let prompt = usbSession.takeAttachmentPrompt() else {
            return
        }
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
        consoleSession.clear()
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        vmCoordinator.sendConsoleBytes(data)
    }

    func clearEventLog() {
        consoleSession.clearEventLog()
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
        usbSession.clearAttachmentPrompt()

        vmConfiguration.reset()

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
            usbSession.present(attachmentPrompt(for: currentRecord))
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
                    previousDeviceName: previousRecord?.deviceName ?? "USB Device",
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
                        previousDeviceName: previousRecord?.deviceName ?? "USB Device",
                        isCurrentlyAttached: attachedAccessoryID == sessionAccessoryID
                    )
                )
            )
            return
        }

        usbCoordinator.selectAccessory(id: accessoryID)
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

    private func restoreOnboardingState() {
        let defaults = UserDefaults.standard
        let completedVersion = defaults.integer(forKey: DefaultsKey.onboardingVersion)

        hasCompletedOnboarding = completedVersion >= Self.currentOnboardingVersion
    }

    private func appendScratchDiskSelectionSummaryIfNeeded() {
        if let diskImageURL = vmConfiguration.diskImageURL {
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

    private func updateWireGuardEndpoint(_ endpoint: String) {
        guard endpoint != wireGuardSettings.endpoint else {
            return
        }

        var settings = wireGuardSettings
        settings.endpoint = endpoint
        wireGuardSettings = settings
        wireGuardStatusMessage = "WireGuard guest address discovered: \(endpoint)."
        appendEvent("WireGuard guest address discovered from guest console: \(endpoint).")
    }

    private func clearConsoleForVMStart() {
        consoleSession.clear()
    }

    private func appendConsole(_ data: Data) {
        if let endpoint = consoleSession.append(data) {
            updateWireGuardEndpoint(endpoint)
        }
    }

    private func appendEvent(_ message: String) {
        consoleSession.appendEvent(message)
    }

    private static let currentOnboardingVersion = 2

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }

    private enum DefaultsKey {
        static let onboardingVersion = "Onboarding.completedVersion"
    }
}
