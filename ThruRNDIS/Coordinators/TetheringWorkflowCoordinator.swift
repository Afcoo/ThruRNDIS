/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

private struct PendingUSBAttachment: Equatable {
    let accessoryID: UInt64
    let token: UUID
    var startedVM: Bool
}

private enum USBAttachmentWorkflowState: Equatable {
    case idle
    case waitingForVM(PendingUSBAttachment)
    case waitingForVMStop(PendingUSBAttachment)
    case attaching(PendingUSBAttachment)

    var attachment: PendingUSBAttachment? {
        switch self {
        case .idle:
            nil
        case .waitingForVM(let attachment),
             .waitingForVMStop(let attachment),
             .attaching(let attachment):
            attachment
        }
    }

    var isWaitingForVMStop: Bool {
        guard case .waitingForVMStop = self else { return false }
        return true
    }
}

@MainActor
final class TetheringWorkflowCoordinator {
    struct Actions {
        let canPresentUSBAttachmentPrompt: () -> Bool
        let startVirtualMachine: () -> Bool
        let canConnectHostWireGuardTunnel: () -> Bool
        let updateStatusMessage: (String) -> Void
        let workflowStateDidChange: () -> Void
    }

    private let vmCoordinator: VMCoordinator
    private let usbCoordinator: USBAccessoryCoordinator
    private let assetProvider: VMAssetProviding
    private let eventLog: EventLogStore
    private let usbSession: USBSessionStore
    private let wireGuardSession: WireGuardSessionStore
    private let appPreferences: AppPreferencesStore
    private let managedWireGuardConnection: ManagedWireGuardConnectionCoordinator
    private let actions: Actions

    private var runtimeState: VMRuntimeState
    private var attachmentState: USBAttachmentWorkflowState = .idle
    private var pendingWireGuardConnectionAccessoryID: UInt64?

    init(
        assetProvider: VMAssetProviding,
        vmCoordinator: VMCoordinator,
        usbCoordinator: USBAccessoryCoordinator,
        eventLog: EventLogStore,
        usbSession: USBSessionStore,
        wireGuardSession: WireGuardSessionStore,
        appPreferences: AppPreferencesStore,
        managedWireGuardConnection: ManagedWireGuardConnectionCoordinator,
        actions: Actions
    ) {
        self.assetProvider = assetProvider
        self.vmCoordinator = vmCoordinator
        self.usbCoordinator = usbCoordinator
        self.eventLog = eventLog
        self.usbSession = usbSession
        self.wireGuardSession = wireGuardSession
        self.appPreferences = appPreferences
        self.managedWireGuardConnection = managedWireGuardConnection
        self.actions = actions
        self.runtimeState = vmCoordinator.runtimeState
    }

    var hasPendingAttachment: Bool {
        attachmentState != .idle
    }

    var attachmentRequiresVMStopRetry: Bool {
        runtimeState == .failed && vmCoordinator.hasVirtualMachine
    }

    func requestAttachAccessory(id accessoryID: UInt64) {
        guard let record = beginAttachmentWorkflow(accessoryID: accessoryID) else {
            return
        }
        prepareWireGuardConnectionForUSBAttachment(record)
    }

    func resolveUSBAttachmentPrompt(accepted: Bool) {
        guard let prompt = usbSession.takeAttachmentPrompt() else { return }

        if accepted {
            switch prompt.kind {
            case .attach:
                if let record = beginAttachmentWorkflow(
                    accessoryID: prompt.accessory.id
                ) {
                    prepareWireGuardConnectionForUSBAttachment(record)
                }
            case .assetsRequired:
                usbSession.deferAttachmentUntilAssetsAreReady(
                    accessoryID: prompt.accessory.id
                )
            }
        } else {
            appendEventLog(
                "USB attach declined for registry \(prompt.accessory.registryIDText).",
                level: .debug,
                category: .usb
            )
        }

        presentNextUSBAttachmentPromptIfPossible()
    }

    func resolveWireGuardConnectionPrompt(
        id promptID: UUID,
        accepted: Bool,
        shouldAutomaticallyConnectNextTime: Bool
    ) {
        guard let prompt = wireGuardSession.takeWireGuardConnectionPrompt(
            id: promptID
        ) else {
            appendEventLog(
                "Ignoring a stale WireGuard connection prompt response.",
                level: .debug,
                category: .wireGuard
            )
            return
        }

        defer { presentNextUSBAttachmentPromptIfPossible() }

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
                || usbSession.attachedAccessoryID == prompt.accessory.id
                || usbSession.vmSessionAccessoryID == prompt.accessory.id else {
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

    func prepareForManualVMRestart(attachedAccessoryID: UInt64?) {
        guard let attachedAccessoryID else { return }
        setAttachmentState(
            .waitingForVMStop(
                PendingUSBAttachment(
                    accessoryID: attachedAccessoryID,
                    token: UUID(),
                    startedVM: false
                )
            )
        )
    }

    func canStartVMForManualRestart() -> Bool {
        guard let accessoryID = pendingAttachmentAccessoryID else {
            return true
        }
        guard usbSession.accessories.contains(where: { $0.id == accessoryID }) else {
            cancelPendingAttachment(
                reason: "target USB accessory disconnected during VM restart"
            )
            actions.updateStatusMessage(
                String(localized: "The USB accessory became unavailable before it could be attached.")
            )
            return false
        }

        if let attachment = attachmentState.attachment {
            setAttachmentState(.waitingForVM(attachment))
        }
        return true
    }

    func markVMStartedForPendingAttachment() {
        updatePendingAttachment { $0.startedVM = true }
    }

    func vmStateDidChange(_ state: VMRuntimeState) {
        runtimeState = state

        switch state {
        case .running:
            continuePendingAttachmentIfPossible()
            attemptPendingWireGuardConnectionIfReady()
            presentNextUSBAttachmentPromptIfPossible()
        case .failed:
            cancelPendingWireGuardConnection(reason: "VM start or runtime failure")
            cancelPendingAttachment(reason: "VM start or runtime failure")
            wireGuardSession.clearDiscoveredEndpoint(reason: "VM failed")
        default:
            break
        }
    }

    func vmDidStop(restartWillStartVM: Bool) {
        appendEventLog(
            "VM stop workflow snapshot: pendingUSB=" +
                "\(pendingAttachmentAccessoryID.map(Self.registryIDText) ?? "none"), " +
                "waitingForStop=\(attachmentState.isWaitingForVMStop), " +
                "restartWillStart=\(restartWillStartVM), pendingWireGuard=" +
                "\(pendingWireGuardConnectionAccessoryID.map(Self.registryIDText) ?? "none").",
            level: .debug,
            category: .application
        )

        let continuingAttachmentID = attachmentState.isWaitingForVMStop
            || restartWillStartVM
            ? pendingAttachmentAccessoryID
            : nil
        cancelWireGuardRequestUnlessContinuing(with: continuingAttachmentID)

        wireGuardSession.clearDiscoveredEndpoint(reason: "VM stopped")
        usbCoordinator.clearAttachmentForStoppedVM()

        if let attachment = attachmentState.attachment,
           !attachmentState.isWaitingForVMStop,
           !restartWillStartVM {
            let pendingRecord = usbSession.accessories.first {
                $0.id == attachment.accessoryID
            }
            cancelPendingAttachment(
                reason: "VM stopped before USB attachment completed",
                presentNextPrompt: false
            )
            if let pendingRecord {
                usbSession.enqueueAttachmentPrompt(
                    USBAttachmentPrompt(
                        accessory: pendingRecord,
                        kind: .attach
                    )
                )
            }
            presentNextUSBAttachmentPromptIfPossible()
            return
        }

        guard let attachment = attachmentState.attachment,
              attachmentState.isWaitingForVMStop,
              !restartWillStartVM else {
            presentNextUSBAttachmentPromptIfPossible()
            return
        }

        setAttachmentState(.waitingForVM(attachment))
        if !actions.startVirtualMachine() {
            cancelPendingAttachment(reason: "VM preflight failed after stop")
        }
    }

    func usbStateDidChange() {
        attemptPendingWireGuardConnectionIfReady()
        presentNextUSBAttachmentPromptIfPossible()
    }

    func accessoryDidBecomeAvailable(_ record: USBAccessoryRecord) {
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
              usbSession.attachedAccessoryID != record.id,
              pendingAttachmentAccessoryID != record.id,
              !usbSession.isAttachmentDeferredUntilAssetsAreReady(
                accessoryID: record.id
              ) else {
            return
        }

        usbSession.enqueueAttachmentPrompt(
            USBAttachmentPrompt(
                accessory: record,
                kind: assetProvider.hasConfiguredAssets ? .attach : .assetsRequired
            )
        )
        presentNextUSBAttachmentPromptIfPossible()
    }

    func accessoryDidBecomeUnavailable(_ accessoryID: UInt64) {
        usbSession.removeDeferredAttachment(accessoryID: accessoryID)
        guard pendingAttachmentAccessoryID == accessoryID else { return }

        let shouldStopVM = pendingAttachmentStartedVM && vmCoordinator.canStop
        cancelPendingAttachment(
            reason: "target USB accessory disconnected",
            presentNextPrompt: !shouldStopVM
        )
        if shouldStopVM {
            stopVMForCancelledAttachment()
        }
    }

    func handleUnexpectedUSBDetach(accessoryID: UInt64, reason: String) -> Bool {
        guard runtimeState == .running || runtimeState == .starting else {
            return false
        }

        appendEventLog(
            "Stopping VM because the USB passthrough lifecycle ended for registry " +
                "\(Self.registryIDText(accessoryID)): \(reason)",
            level: .debug,
            category: .usb
        )
        return true
    }

    func wireGuardReadinessDidChange() {
        attemptPendingWireGuardConnectionIfReady()
    }

    func presentNextUSBAttachmentPromptIfPossible() {
        usbSession.presentNextAttachmentPromptIfPossible(
            hasConfiguredVMAssets: assetProvider.hasConfiguredAssets,
            canPresent: actions.canPresentUSBAttachmentPrompt()
                && attachmentState == .idle
                && wireGuardSession.wireGuardConnectionPrompt == nil
                && !assetProvider.isBusy
        )
    }

    func assetsDidBecomeAvailable() {
        guard assetProvider.hasConfiguredAssets, !assetProvider.isBusy else {
            return
        }
        usbSession.resumeAttachmentsAwaitingAssetSetup()
        presentNextUSBAttachmentPromptIfPossible()
    }

    func cancelWorkflow(reason: String) {
        cancelPendingWireGuardConnection(reason: reason)
        cancelPendingAttachment(reason: reason)
    }

    func cancelPendingWireGuardConnection(reason: String) {
        let accessoryID = pendingWireGuardConnectionAccessoryID
            ?? wireGuardSession.wireGuardConnectionPrompt?.accessory.id
        managedWireGuardConnection.cancel(reason: reason)
        pendingWireGuardConnectionAccessoryID = nil
        guard let accessoryID else { return }

        wireGuardSession.clearWireGuardConnectionPrompt()
        appendEventLog(
            "Pending WireGuard connection cancelled for USB registry " +
                "\(Self.registryIDText(accessoryID)): \(reason).",
            level: .debug,
            category: .wireGuard
        )
    }

    func cancelManagedWireGuardConnection(reason: String) {
        managedWireGuardConnection.cancel(reason: reason)
    }

    func cancelPendingWorkForReset() {
        cancelPendingAttachment(
            reason: "app settings reset",
            presentNextPrompt: false
        )
        cancelPendingWireGuardConnection(reason: "app settings reset")
        usbSession.clearAttachmentPrompt()
        wireGuardSession.clearWireGuardConnectionPrompt()
    }

    func clearDeferredWorkForReset() {
        setAttachmentState(.idle)
        pendingWireGuardConnectionAccessoryID = nil
        usbSession.resetAttachmentWorkflow()
        wireGuardSession.clearWireGuardConnectionPrompt()
    }

    private var pendingAttachmentAccessoryID: UInt64? {
        attachmentState.attachment?.accessoryID
    }

    private var pendingAttachmentStartedVM: Bool {
        attachmentState.attachment?.startedVM == true
    }

    private func beginAttachmentWorkflow(
        accessoryID: UInt64
    ) -> USBAccessoryRecord? {
        guard attachmentState == .idle else {
            actions.updateStatusMessage(
                String(localized: "Wait for the current USB attachment workflow to finish.")
            )
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): another workflow is active.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard !assetProvider.isBusy else {
            actions.updateStatusMessage(
                String(localized: "Wait for VM asset installation to finish before attaching USB.")
            )
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): a VM asset operation is active.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard !attachmentRequiresVMStopRetry else {
            actions.updateStatusMessage(
                String(localized: "The VM did not stop cleanly. Retry Stop before attaching a USB accessory.")
            )
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): failed VM cleanup is pending.",
                level: .debug,
                category: .usb
            )
            presentNextUSBAttachmentPromptIfPossible()
            return nil
        }

        if usbSession.attachedAccessoryID == accessoryID {
            actions.updateStatusMessage(
                String(localized: "The selected USB accessory is already attached.")
            )
            appendEventLog(
                "USB attachment workflow ignored for registry " +
                    "\(Self.registryIDText(accessoryID)): accessory is already attached.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard usbSession.vmSessionAccessoryID == nil else {
            actions.updateStatusMessage(
                String(localized: "Detach the current USB accessory before attaching another USB accessory.")
            )
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): this VM session already used a USB accessory.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard let record = usbSession.accessories.first(
            where: { $0.id == accessoryID }
        ) else {
            actions.updateStatusMessage(
                String(localized: "The selected USB accessory is no longer available.")
            )
            appendEventLog(
                "USB attachment workflow not started for registry " +
                    "\(Self.registryIDText(accessoryID)): accessory is unavailable.",
                level: .debug,
                category: .usb
            )
            return nil
        }

        guard assetProvider.hasConfiguredAssets else {
            usbSession.enqueueAttachmentPrompt(
                USBAttachmentPrompt(accessory: record, kind: .assetsRequired)
            )
            presentNextUSBAttachmentPromptIfPossible()
            return nil
        }

        setAttachmentState(
            .waitingForVM(
                PendingUSBAttachment(
                    accessoryID: accessoryID,
                    token: UUID(),
                    startedVM: false
                )
            )
        )
        usbCoordinator.selectAccessory(id: accessoryID)
        continuePendingAttachmentIfPossible()

        guard pendingAttachmentAccessoryID == accessoryID
                || usbSession.attachedAccessoryID == accessoryID else {
            return nil
        }
        return record
    }

    private func continuePendingAttachmentIfPossible() {
        guard let attachment = attachmentState.attachment else { return }
        if case .attaching = attachmentState { return }

        guard usbSession.accessories.contains(
            where: { $0.id == attachment.accessoryID }
        ) else {
            let shouldStopVM = attachment.startedVM && vmCoordinator.canStop
            cancelPendingAttachment(
                reason: "USB accessory became unavailable",
                presentNextPrompt: !shouldStopVM
            )
            actions.updateStatusMessage(
                String(localized: "The USB accessory became unavailable before it could be attached.")
            )
            if shouldStopVM {
                stopVMForCancelledAttachment()
            }
            return
        }

        switch runtimeState {
        case .running:
            attachAccessory(attachment)
        case .starting:
            setAttachmentState(.waitingForVM(attachment))
        case .stopping:
            setAttachmentState(.waitingForVMStop(attachment))
        case .idle, .stopped, .failed:
            setAttachmentState(.waitingForVM(attachment))
            if actions.startVirtualMachine() {
                if runtimeState == .starting {
                    markVMStartedForPendingAttachment()
                }
            } else {
                cancelPendingAttachment(reason: "VM preflight failed")
            }
        }
    }

    private func attachAccessory(_ attachment: PendingUSBAttachment) {
        setAttachmentState(.attaching(attachment))
        usbCoordinator.attachAccessory(
            id: attachment.accessoryID,
            to: vmCoordinator.virtualMachine
        ) { [weak self] success in
            guard let self,
                  case .attaching(let currentAttachment) = self.attachmentState,
                  currentAttachment.token == attachment.token else {
                return
            }

            self.setAttachmentState(.idle)
            if success {
                self.attemptPendingWireGuardConnectionIfReady()
            } else {
                self.cancelPendingWireGuardConnection(
                    reason: "approved USB attachment failed"
                )
                self.appendEventLog(
                    "Approved USB attach did not complete for registry " +
                        "\(Self.registryIDText(attachment.accessoryID)).",
                    level: .debug,
                    category: .usb
                )
            }
            self.presentNextUSBAttachmentPromptIfPossible()
        }
    }

    private func prepareWireGuardConnectionForUSBAttachment(
        _ accessory: USBAccessoryRecord
    ) {
        if appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches {
            requestWireGuardConnectionAfterUSBAttachment(accessoryID: accessory.id)
        } else {
            wireGuardSession.presentWireGuardConnectionPrompt(for: accessory)
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

        guard usbSession.attachedAccessoryID == accessoryID,
              usbSession.vmSessionAccessoryID == accessoryID,
              wireGuardSession.invalidConnectionFields.isEmpty,
              actions.canConnectHostWireGuardTunnel() else {
            return
        }

        pendingWireGuardConnectionAccessoryID = nil
        appendEventLog(
            "USB and VM are ready; starting the queued WireGuard connection for registry " +
                "\(Self.registryIDText(accessoryID)).",
            level: .debug,
            category: .wireGuard
        )
        managedWireGuardConnection.connect()
    }

    private func cancelWireGuardRequestUnlessContinuing(
        with continuingAttachmentID: UInt64?
    ) {
        let promptedAccessoryID = wireGuardSession
            .wireGuardConnectionPrompt?.accessory.id
        let hasRequest = pendingWireGuardConnectionAccessoryID != nil
            || promptedAccessoryID != nil
        let shouldPreserveRequest = continuingAttachmentID != nil
            && (pendingWireGuardConnectionAccessoryID == nil
                || pendingWireGuardConnectionAccessoryID == continuingAttachmentID)
            && (promptedAccessoryID == nil
                || promptedAccessoryID == continuingAttachmentID)

        if hasRequest, !shouldPreserveRequest {
            cancelPendingWireGuardConnection(reason: "VM stopped")
        }
    }

    private func cancelPendingAttachment(
        reason: String,
        presentNextPrompt: Bool = true
    ) {
        guard attachmentState != .idle else { return }

        cancelPendingWireGuardConnection(
            reason: "USB attachment workflow cancelled: \(reason)"
        )
        setAttachmentState(.idle)
        appendEventLog(
            "Pending USB attachment cancelled: \(reason).",
            level: .debug,
            category: .usb
        )
        if presentNextPrompt {
            presentNextUSBAttachmentPromptIfPossible()
        }
    }

    private func stopVMForCancelledAttachment() {
        usbCoordinator.prepareForIntentionalVMStop()
        vmCoordinator.stop()
    }

    private func updatePendingAttachment(
        _ update: (inout PendingUSBAttachment) -> Void
    ) {
        guard var attachment = attachmentState.attachment else { return }
        update(&attachment)

        switch attachmentState {
        case .idle:
            break
        case .waitingForVM:
            setAttachmentState(.waitingForVM(attachment))
        case .waitingForVMStop:
            setAttachmentState(.waitingForVMStop(attachment))
        case .attaching:
            setAttachmentState(.attaching(attachment))
        }
    }

    private func setAttachmentState(_ state: USBAttachmentWorkflowState) {
        guard attachmentState != state else { return }
        attachmentState = state
        actions.workflowStateDidChange()
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
