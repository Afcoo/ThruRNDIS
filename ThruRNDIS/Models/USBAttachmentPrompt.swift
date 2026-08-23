/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct USBAttachmentPrompt: Identifiable {
    enum Kind {
        case attach
        case assetsRequired
    }

    let id = UUID()
    let accessory: USBAccessoryRecord
    let kind: Kind

    var title: String {
        switch kind {
        case .attach:
            return String(localized: "Attach USB Device?")
        case .assetsRequired:
            return String(localized: "VM Assets Required")
        }
    }

    var message: String {
        switch kind {
        case .attach:
            return String(localized: "\(accessory.deviceName) has been connected.\nStart the VM and attach this device?")
        case .assetsRequired:
            return String(localized: "\(accessory.deviceName) has been connected, but VM assets have not been configured.\nOpen Settings to install VM Assets.")
        }
    }

    var primaryButtonTitle: String {
        switch kind {
        case .attach:
            return String(localized: "Attach")
        case .assetsRequired:
            return String(localized: "Open Settings")
        }
    }
}
