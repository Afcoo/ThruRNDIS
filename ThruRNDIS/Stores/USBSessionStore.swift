/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

struct USBSessionSnapshot: Equatable {
    var accessories: [USBAccessoryRecord] = []
    var isAccessoryMonitoring = false
    var selectedAccessoryID: UInt64?
    var attachedAccessoryID: UInt64?
    var vmSessionAccessoryID: UInt64?
}

@MainActor
final class USBSessionStore: ObservableObject {
    @Published private(set) var snapshot = USBSessionSnapshot()
    @Published private(set) var attachmentPrompt: USBAttachmentPrompt?

    private var queuedAttachmentPrompts: [USBAttachmentPrompt] = []
    private var promptedAccessoryIDs: Set<UInt64> = []
    private var accessoriesAwaitingAssetSetup: Set<UInt64> = []

    var accessories: [USBAccessoryRecord] {
        snapshot.accessories
    }

    var isAccessoryMonitoring: Bool {
        snapshot.isAccessoryMonitoring
    }

    var selectedAccessoryID: UInt64? {
        snapshot.selectedAccessoryID
    }

    var attachedAccessoryID: UInt64? {
        snapshot.attachedAccessoryID
    }

    var vmSessionAccessoryID: UInt64? {
        snapshot.vmSessionAccessoryID
    }

    func apply(_ snapshot: USBSessionSnapshot) {
        guard snapshot != self.snapshot else {
            return
        }
        self.snapshot = snapshot
    }

    func present(_ prompt: USBAttachmentPrompt) {
        attachmentPrompt = prompt
    }

    @discardableResult
    func takeAttachmentPrompt() -> USBAttachmentPrompt? {
        defer {
            if let attachmentPrompt {
                promptedAccessoryIDs.remove(attachmentPrompt.accessory.id)
            }
            attachmentPrompt = nil
        }
        return attachmentPrompt
    }

    func clearAttachmentPrompt() {
        attachmentPrompt = nil
    }

    func enqueueAttachmentPrompt(_ prompt: USBAttachmentPrompt) {
        guard promptedAccessoryIDs.insert(prompt.accessory.id).inserted else {
            return
        }
        queuedAttachmentPrompts.append(prompt)
    }

    func deferAttachmentUntilAssetsAreReady(accessoryID: UInt64) {
        accessoriesAwaitingAssetSetup.insert(accessoryID)
    }

    func removeDeferredAttachment(accessoryID: UInt64) {
        accessoriesAwaitingAssetSetup.remove(accessoryID)
    }

    func discardAttachmentWork(accessoryID: UInt64) {
        queuedAttachmentPrompts.removeAll { $0.accessory.id == accessoryID }
        promptedAccessoryIDs.remove(accessoryID)
        accessoriesAwaitingAssetSetup.remove(accessoryID)
        if attachmentPrompt?.accessory.id == accessoryID {
            attachmentPrompt = nil
        }
    }

    func isAttachmentDeferredUntilAssetsAreReady(accessoryID: UInt64) -> Bool {
        accessoriesAwaitingAssetSetup.contains(accessoryID)
    }

    func resumeAttachmentsAwaitingAssetSetup() {
        let waitingAccessoryIDs = accessoriesAwaitingAssetSetup
        accessoriesAwaitingAssetSetup.removeAll()

        for accessoryID in waitingAccessoryIDs {
            guard let record = accessories.first(where: { $0.id == accessoryID }) else {
                continue
            }
            enqueueAttachmentPrompt(
                USBAttachmentPrompt(accessory: record, kind: .attach)
            )
        }
    }

    func presentNextAttachmentPromptIfPossible(
        hasConfiguredVMAssets: Bool,
        canPresent: Bool
    ) {
        guard canPresent,
              attachmentPrompt == nil,
              vmSessionAccessoryID == nil else {
            return
        }

        guard hasConfiguredVMAssets || accessoriesAwaitingAssetSetup.isEmpty else {
            return
        }

        while let firstPrompt = queuedAttachmentPrompts.first {
            guard let currentRecord = accessories.first(
                where: { $0.id == firstPrompt.accessory.id }
            ), currentRecord.id != attachedAccessoryID else {
                queuedAttachmentPrompts.removeFirst()
                promptedAccessoryIDs.remove(firstPrompt.accessory.id)
                continue
            }

            queuedAttachmentPrompts.removeFirst()
            present(
                USBAttachmentPrompt(
                    accessory: currentRecord,
                    kind: hasConfiguredVMAssets ? .attach : .assetsRequired
                )
            )
            return
        }
    }

    func resetAttachmentWorkflow() {
        queuedAttachmentPrompts.removeAll()
        promptedAccessoryIDs.removeAll()
        accessoriesAwaitingAssetSetup.removeAll()
        attachmentPrompt = nil
    }
}
