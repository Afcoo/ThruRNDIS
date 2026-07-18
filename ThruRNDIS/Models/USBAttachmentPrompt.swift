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
            return String(localized: "\(accessory.deviceName) has been connected.\nStart the VM and attach this device?")
        case .replace(_, let previousDeviceName, _):
            return String(localized: "Disconnect \(previousDeviceName) and attach \(accessory.deviceName)?\nThe VM will restart.")
        case .assetsRequired:
            return String(localized: "\(accessory.deviceName) has been connected, but VM assets have not been configured.\nOpen Settings to install VM Assets.")
        }
    }

    var primaryButtonTitle: String {
        switch kind {
        case .attach:
            return String(localized: "Attach")
        case .replace:
            return String(localized: "Replace & Restart")
        case .assetsRequired:
            return String(localized: "Open Settings")
        }
    }
}
