/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import IOKit
import IOKit.usb

enum USBDeviceNameResolver {
    static func productName(registryID: UInt64) -> String? {
        guard let matching = IORegistryEntryIDMatching(registryID) else {
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(service) }

        for key in [kUSBProductString, "USB Product Name"] {
            guard let value = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String else {
                continue
            }

            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }

        return nil
    }
}
