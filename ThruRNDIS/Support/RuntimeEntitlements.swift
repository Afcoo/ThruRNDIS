/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import Security

enum RuntimeEntitlement: String, CaseIterable {
    case accessoryAccessUSB = "com.apple.developer.accessory-access.usb"
    case packetTunnelProvider = "com.apple.developer.networking.networkextension"
    case systemExtensionInstall = "com.apple.developer.system-extension.install"
    case virtualization = "com.apple.security.virtualization"

    var label: String {
        switch self {
        case .accessoryAccessUSB:
            return String(localized: "AccessoryAccess USB")
        case .packetTunnelProvider:
            return String(localized: "NetworkExtension Packet Tunnel")
        case .systemExtensionInstall:
            return String(localized: "System Extension Installation")
        case .virtualization:
            return String(localized: "Virtualization")
        }
    }
}

struct RuntimeEntitlementSnapshot: Equatable {
    let accessoryAccessUSB: Bool
    let packetTunnelProvider: Bool
    let systemExtensionInstall: Bool
    let virtualization: Bool

    static var current: RuntimeEntitlementSnapshot {
        RuntimeEntitlementSnapshot(
            accessoryAccessUSB: RuntimeEntitlementReader.has(.accessoryAccessUSB),
            packetTunnelProvider: RuntimeEntitlementReader.networkExtensionEntitlementContains(
                "packet-tunnel-provider"
            ) || RuntimeEntitlementReader.networkExtensionEntitlementContains(
                "packet-tunnel-provider-systemextension"
            ),
            systemExtensionInstall: RuntimeEntitlementReader.has(.systemExtensionInstall),
            virtualization: RuntimeEntitlementReader.has(.virtualization)
        )
    }

    func has(_ entitlement: RuntimeEntitlement) -> Bool {
        switch entitlement {
        case .accessoryAccessUSB:
            return accessoryAccessUSB
        case .packetTunnelProvider:
            return packetTunnelProvider
        case .systemExtensionInstall:
            return systemExtensionInstall
        case .virtualization:
            return virtualization
        }
    }
}

enum RuntimeEntitlementReader {
    static func has(_ entitlement: RuntimeEntitlement) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement.rawValue as CFString, nil) else {
            return false
        }

        return (value as? Bool) == true
    }

    static func networkExtensionEntitlementContains(_ entitlementValue: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                RuntimeEntitlement.packetTunnelProvider.rawValue as CFString,
                nil
              ) else {
            return false
        }

        return (value as? [String])?.contains(entitlementValue) == true
    }
}
