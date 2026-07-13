/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct USBAttachmentPrompt: Identifiable {
    enum Kind {
        case attach
        case replace(previousAccessoryID: UInt64, previousUSBIDText: String, isCurrentlyAttached: Bool)
        case assetsRequired
    }

    let id = UUID()
    let accessory: USBAccessoryRecord
    let kind: Kind

    var title: String {
        switch kind {
        case .attach:
            return "Attach USB Device?"
        case .replace:
            return "Replace USB Device?"
        case .assetsRequired:
            return "VM Assets Required"
        }
    }

    var message: String {
        switch kind {
        case .attach:
            return "USB device \(accessory.usbIDText) is available to ThruRNDIS. Start the VM if needed and attach this device?"
        case .replace(_, let previousUSBIDText, let isCurrentlyAttached):
            let previousState = isCurrentlyAttached ? "is attached" : "was already used in this VM session"
            return "USB device \(previousUSBIDText) \(previousState). ThruRNDIS will detach it if needed, restart the VM, and attach \(accessory.usbIDText). Continue?"
        case .assetsRequired:
            return "USB device \(accessory.usbIDText) is ready, but VM assets have not been configured. Open onboarding to install the latest release or select an extracted vm_assets folder."
        }
    }

    var primaryButtonTitle: String {
        switch kind {
        case .attach:
            return "Attach"
        case .replace:
            return "Replace & Restart"
        case .assetsRequired:
            return "Open Onboarding"
        }
    }
}
