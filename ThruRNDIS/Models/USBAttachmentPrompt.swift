/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct USBAttachmentPrompt: Identifiable {
    enum Kind {
        case attach
        case replace(previousAccessoryID: UInt64, previousDeviceName: String, isCurrentlyAttached: Bool)
        case assetsRequired
    }

    let id = UUID()
    let accessory: USBAccessoryRecord
    let kind: Kind

    var title: String {
        switch kind {
        case .attach:
            return String(localized: "Attach USB Device?")
        case .replace:
            return String(localized: "Replace USB Device?")
        case .assetsRequired:
            return String(localized: "VM Assets Required")
        }
    }

    var message: String {
        switch kind {
        case .attach:
            return String(localized: "USB device \(accessory.deviceName) is available to ThruRNDIS. Start the VM if needed and attach this device?")
        case .replace(_, let previousDeviceName, let isCurrentlyAttached):
            if isCurrentlyAttached {
                return String(localized: "USB device \(previousDeviceName) is attached. ThruRNDIS will detach it if needed, restart the VM, and attach \(accessory.deviceName). Continue?")
            }
            return String(localized: "USB device \(previousDeviceName) was already used in this VM session. ThruRNDIS will detach it if needed, restart the VM, and attach \(accessory.deviceName). Continue?")
        case .assetsRequired:
            return String(localized: "USB device \(accessory.deviceName) is ready, but VM assets have not been configured. Open onboarding to install the latest release or select an extracted vm_assets folder.")
        }
    }

    var primaryButtonTitle: String {
        switch kind {
        case .attach:
            return String(localized: "Attach")
        case .replace:
            return String(localized: "Replace & Restart")
        case .assetsRequired:
            return String(localized: "Open Onboarding")
        }
    }
}
