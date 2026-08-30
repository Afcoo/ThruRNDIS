/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

private struct PendingUSBAttachment: Equatable {
    let accessoryID: UInt64
    let token: UUID
    let allowsAutomaticNetworkRoutingStart: Bool
    var startedVM: Bool
}

private struct PendingUSBAutoConnectRequest: Equatable {
    let accessoryID: UInt64
    let reconnectIdentity: USBAccessoryReconnectIdentity
    let token: UUID
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

private enum VMRestartWorkflowState: Equatable {
    case idle
    case stopping
    case starting
}

private enum VMRestartWorkflowRequest {
    case manual
    case accessoryReplacement(accessoryID: UInt64)

    var reason: String {
        switch self {
        case .manual:
            "VM restart"
        case .accessoryReplacement:
            "USB accessory replacement"
        }
    }

    var suppressesReleasedAccessoryPrompt: Bool {
        switch self {
        case .manual:
            false
        case .accessoryReplacement:
            true
        }
    }
}

@MainActor
final class TetheringWorkflowCoordinator {
    struct Actions {
        let canPresentUSBAttachmentPrompt: () -> Bool
        let canBeginAutoConnect: () -> Bool
        let isAutoConnectEnabled: (USBAccessoryReconnectIdentity) -> Bool
        let canContinueVMRestart: () -> Bool
        let stopNetworkRouting: (String) async -> Bool
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
    private var vmRestartState: VMRestartWorkflowState = .idle
    private var pendingAutoConnectRequest: PendingUSBAutoConnectRequest?

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

    var isRestartingVirtualMachine: Bool {
        vmRestartState != .idle
    }

    var isStoppingForVMRestart: Bool {
        vmRestartState == .stopping
    }

    var allowsAutomaticNetworkRoutingStart: Bool {
        attachmentState.attachment?.allowsAutomaticNetworkRoutingStart == true
    }

    func requestAttachAccessory(id accessoryID: UInt64) {
        _ = beginAttachmentWorkflow(
            accessoryID: accessoryID,
            allowsAutomaticNetworkRoutingStart: false
        )
    }

    func resolveUSBAttachmentPrompt(accepted: Bool) {
        guard let prompt = usbSession.takeAttachmentPrompt() else { return }

        if accepted {
            switch prompt.kind {
            case .attach:
                _ = beginAttachmentWorkflow(
                    accessoryID: prompt.accessory.id,
                    allowsAutomaticNetworkRoutingStart: true
                )
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

    func restartVirtualMachine() {
        restartVirtualMachine(for: .manual)
    }

    func replaceAttachedAccessory(
        with accessoryID: UInt64,
        prerequisitesSatisfied: Bool
    ) {
        guard prerequisitesSatisfied else {
            rejectAccessoryReplacement(
                accessoryID,
                reason: "replacement prerequisites are no longer satisfied"
            )
            return
        }

        restartVirtualMachine(
            for: .accessoryReplacement(accessoryID: accessoryID)
        )
    }

    private func restartVirtualMachine(
        for request: VMRestartWorkflowRequest
    ) {
        guard vmRestartState == .idle,
              attachmentState == .idle,
              vmCoordinator.canRestart else {
            return
        }

        setVMRestartState(.stopping)
        actions.updateStatusMessage(
            String(localized: "Stopping Network Routing before restarting the VM.")
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            let didStopVMNetwork = await self.actions.stopNetworkRouting(
                request.reason
            )
            guard didStopVMNetwork else {
                self.appendEventLog(
                    "VM restart was cancelled because Network Routing cleanup failed.",
                    level: .error,
                    category: .network
                )
                self.actions.updateStatusMessage(
                    String(localized: "Could not stop Network Routing. Retry Restart after resolving the Network Routing error.")
                )
                self.setVMRestartState(.idle)
                return
            }
            guard self.actions.canContinueVMRestart(),
                  self.vmRestartState == .stopping,
                  self.vmCoordinator.canRestart else {
                self.setVMRestartState(.idle)
                return
            }
            self.usbCoordinator.prepareForIntentionalVMStop(
                suppressReenumerationPrompt: request.suppressesReleasedAccessoryPrompt
            )
            self.vmCoordinator.restart(
                reason: request.reason
            ) { [weak self] in
                guard let self else { return }
                self.setVMRestartState(.starting)
                guard self.continueVMRestart(request) else {
                    self.setVMRestartState(.idle)
                    return
                }
            }
        }
    }

    private func continueVMRestart(
        _ request: VMRestartWorkflowRequest
    ) -> Bool {
        switch request {
        case .manual:
            guard attachmentState == .idle else {
                cancelPendingAttachment(
                    reason: "unexpected pending USB attachment during targetless VM restart"
                )
                return false
            }
            return actions.startVirtualMachine()
        case .accessoryReplacement(let accessoryID):
            guard beginAttachmentWorkflow(
                accessoryID: accessoryID,
                allowsAutomaticNetworkRoutingStart: false
            ) != nil else {
                appendEventLog(
                    "USB accessory replacement failed for registry " +
                        Self.registryIDText(accessoryID) +
                        ": attachment could not start after the previous VM stopped.",
                    level: .warning,
                    category: .usb
                )
                return false
            }
            return true
        }
    }

    private func markVMStartedForPendingAttachment() {
        updatePendingAttachment { $0.startedVM = true }
    }

    private func rejectAccessoryReplacement(
        _ accessoryID: UInt64,
        reason: String
    ) {
        actions.updateStatusMessage(
            String(localized: "Unable to replace the USB device.")
        )
        appendEventLog(
            "USB accessory replacement rejected for registry " +
                Self.registryIDText(accessoryID) +
                ": \(reason).",
            level: .warning,
            category: .usb
        )
    }

    func vmStateDidChange(_ state: VMRuntimeState) {
        if state == .running || state == .failed {
            setVMRestartState(.idle)
        }
        runtimeState = state
        switch state {
        case .running:
            continuePendingAttachmentIfPossible()
            presentNextUSBAttachmentPromptIfPossible()
        case .failed:
            cancelPendingAttachment(reason: "VM start or runtime failure")
            presentNextUSBAttachmentPromptIfPossible()
        default:
            break
        }
    }

    func vmDidStop() {
        let restartWillStartVM = isStoppingForVMRestart
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

    func autoConnectAccessoryDidBecomeAvailable(_ record: USBAccessoryRecord) {
        guard let reconnectIdentity = record.reconnectIdentity,
              actions.isAutoConnectEnabled(reconnectIdentity),
              pendingAutoConnectRequest == nil else {
            return
        }

        let request = PendingUSBAutoConnectRequest(
            accessoryID: record.id,
            reconnectIdentity: reconnectIdentity,
            token: UUID()
        )
        pendingAutoConnectRequest = request

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.pendingAutoConnectRequest == request else {
                return
            }
            self.pendingAutoConnectRequest = nil
            self.attemptAutoConnect(request)
        }
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
                && !isStoppingForVMRestart
                && runtimeState != .starting
                && runtimeState != .stopping
                && !attachmentRequiresVMStopRetry
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
        pendingAutoConnectRequest = nil
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

    private func attemptAutoConnect(_ request: PendingUSBAutoConnectRequest) {
        guard actions.isAutoConnectEnabled(request.reconnectIdentity),
              usbSession.isAccessoryMonitoring,
              let accessory = usbSession.uniqueAccessory(
                matching: request.reconnectIdentity
              ),
              accessory.id == request.accessoryID else {
            appendEventLog(
                "USB Auto Connect ignored because its remembered identity " +
                    "is unavailable or ambiguous.",
                level: .debug,
                category: .usb
            )
            return
        }

        usbSession.discardAttachmentWork(accessoryID: request.accessoryID)

        guard usbSession.attachedAccessoryID == nil,
              usbSession.vmSessionAccessoryID == nil,
              attachmentState == .idle,
              vmRestartState == .idle,
              assetProvider.hasConfiguredAssets,
              !assetProvider.isBusy,
              !attachmentRequiresVMStopRetry,
              actions.canBeginAutoConnect(),
              usbCoordinator.canRequestAttachment(for: request.accessoryID) else {
            appendEventLog(
                "USB Auto Connect ignored for registry " +
                    "\(accessory.registryIDText) because attachment is not " +
                    "currently available.",
                level: .debug,
                category: .usb
            )
            return
        }

        usbSession.deferPresentedAttachmentPrompt()
        guard beginAttachmentWorkflow(
            accessoryID: request.accessoryID,
            allowsAutomaticNetworkRoutingStart: false
        ) != nil else {
            return
        }
        appendEventLog(
            "USB Auto Connect started for registry \(accessory.registryIDText).",
            level: .info,
            category: .usb
        )
    }

    @discardableResult
    private func beginAttachmentWorkflow(
        accessoryID: UInt64,
        allowsAutomaticNetworkRoutingStart: Bool
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
                    allowsAutomaticNetworkRoutingStart:
                        allowsAutomaticNetworkRoutingStart,
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

    private func setVMRestartState(_ state: VMRestartWorkflowState) {
        guard vmRestartState != state else { return }
        vmRestartState = state
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
