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
        let updateStatusMessage: (String) -> Void
        let workflowStateDidChange: () -> Void
    }

    private let vmCoordinator: VMCoordinator
    private let usbCoordinator: USBAccessoryCoordinator
    private let assetProvider: VMAssetProviding
    private let eventLog: EventLogStore
    private let usbSession: USBSessionStore
    private let actions: Actions

    private var runtimeState: VMRuntimeState
    private var attachmentState: USBAttachmentWorkflowState = .idle

    init(
        assetProvider: VMAssetProviding,
        vmCoordinator: VMCoordinator,
        usbCoordinator: USBAccessoryCoordinator,
        eventLog: EventLogStore,
        usbSession: USBSessionStore,
        actions: Actions
    ) {
        self.assetProvider = assetProvider
        self.vmCoordinator = vmCoordinator
        self.usbCoordinator = usbCoordinator
        self.eventLog = eventLog
        self.usbSession = usbSession
        self.actions = actions
        runtimeState = vmCoordinator.runtimeState
    }

    var hasPendingAttachment: Bool {
        attachmentState != .idle
    }

    var attachmentRequiresVMStopRetry: Bool {
        runtimeState == .failed && vmCoordinator.hasVirtualMachine
    }

    func requestAttachAccessory(id accessoryID: UInt64) {
        _ = beginAttachmentWorkflow(accessoryID: accessoryID)
    }

    func resolveUSBAttachmentPrompt(accepted: Bool) {
        guard let prompt = usbSession.takeAttachmentPrompt() else { return }

        if accepted {
            switch prompt.kind {
            case .attach:
                _ = beginAttachmentWorkflow(accessoryID: prompt.accessory.id)
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

    func prepareForVMRestart(attachingAccessoryID: UInt64?) {
        guard let attachingAccessoryID else { return }
        setAttachmentState(
            .waitingForVMStop(
                PendingUSBAttachment(
                    accessoryID: attachingAccessoryID,
                    token: UUID(),
                    startedVM: false
                )
            )
        )
    }

    func preparePendingAttachmentForRestartedVM(
        expectedAccessoryID: UInt64?
    ) -> Bool {
        guard let expectedAccessoryID else {
            guard attachmentState == .idle else {
                cancelPendingAttachment(
                    reason: "unexpected pending USB attachment during targetless VM restart"
                )
                return false
            }
            return true
        }

        guard pendingAttachmentAccessoryID == expectedAccessoryID,
              let attachment = attachmentState.attachment,
              usbSession.accessories.contains(
                where: { $0.id == expectedAccessoryID }
              ) else {
            cancelPendingAttachment(
                reason: "expected USB accessory unavailable during VM restart"
            )
            actions.updateStatusMessage(
                String(localized: "The USB accessory became unavailable before it could be attached.")
            )
            return false
        }

        setAttachmentState(.waitingForVM(attachment))
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
            presentNextUSBAttachmentPromptIfPossible()
        case .failed:
            cancelPendingAttachment(reason: "VM start or runtime failure")
        default:
            break
        }
    }

    func vmDidStop(restartWillStartVM: Bool) {
        appendEventLog(
            "VM stop workflow snapshot: pendingUSB=" +
                "\(pendingAttachmentAccessoryID.map(Self.registryIDText) ?? "none"), " +
                "waitingForStop=\(attachmentState.isWaitingForVMStop), " +
                "restartWillStart=\(restartWillStartVM).",
            level: .debug,
            category: .application
        )

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
        presentNextUSBAttachmentPromptIfPossible()
    }

    func accessoryDidBecomeAvailable(_ record: USBAccessoryRecord) {
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

    func presentNextUSBAttachmentPromptIfPossible() {
        usbSession.presentNextAttachmentPromptIfPossible(
            hasConfiguredVMAssets: assetProvider.hasConfiguredAssets,
            canPresent: actions.canPresentUSBAttachmentPrompt()
                && attachmentState == .idle
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
        cancelPendingAttachment(reason: reason)
    }

    func cancelPendingWorkForReset() {
        cancelPendingAttachment(
            reason: "app settings reset",
            presentNextPrompt: false
        )
        usbSession.clearAttachmentPrompt()
    }

    func clearDeferredWorkForReset() {
        setAttachmentState(.idle)
        usbSession.resetAttachmentWorkflow()
    }

    private var pendingAttachmentAccessoryID: UInt64? {
        attachmentState.attachment?.accessoryID
    }

    private var pendingAttachmentStartedVM: Bool {
        attachmentState.attachment?.startedVM == true
    }

    @discardableResult
    private func beginAttachmentWorkflow(
        accessoryID: UInt64
    ) -> USBAccessoryRecord? {
        guard attachmentState == .idle else {
            actions.updateStatusMessage(
                String(localized: "Wait for the current USB attachment workflow to finish.")
            )
            return nil
        }
        guard !assetProvider.isBusy else {
            actions.updateStatusMessage(
                String(localized: "Wait for VM asset installation to finish before attaching USB.")
            )
            return nil
        }
        guard !attachmentRequiresVMStopRetry else {
            actions.updateStatusMessage(
                String(localized: "The VM did not stop cleanly. Retry Stop before attaching a USB accessory.")
            )
            presentNextUSBAttachmentPromptIfPossible()
            return nil
        }
        guard usbSession.attachedAccessoryID != accessoryID else {
            actions.updateStatusMessage(
                String(localized: "The selected USB accessory is already attached.")
            )
            return nil
        }
        guard usbSession.vmSessionAccessoryID == nil else {
            actions.updateStatusMessage(
                String(localized: "Detach the current USB accessory before attaching another USB accessory.")
            )
            return nil
        }
        guard let record = usbSession.accessories.first(
            where: { $0.id == accessoryID }
        ) else {
            actions.updateStatusMessage(
                String(localized: "The selected USB accessory is no longer available.")
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
            if !success {
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

    private func cancelPendingAttachment(
        reason: String,
        presentNextPrompt: Bool = true
    ) {
        guard attachmentState != .idle else { return }
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
