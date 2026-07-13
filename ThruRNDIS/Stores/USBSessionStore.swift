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
        defer { attachmentPrompt = nil }
        return attachmentPrompt
    }

    func clearAttachmentPrompt() {
        attachmentPrompt = nil
    }
}
