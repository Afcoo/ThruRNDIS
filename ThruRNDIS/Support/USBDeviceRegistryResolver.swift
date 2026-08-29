/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

struct USBDeviceRegistryProperties: Sendable {
    let productName: String?
    let serialNumber: Data?
    let containerID: UUID?
    let locationID: UInt32?
}

enum USBDeviceRegistryResolver {
    static func properties(registryID: UInt64) -> USBDeviceRegistryProperties {
        guard let matching = IORegistryEntryIDMatching(registryID) else {
            return emptyProperties
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            return emptyProperties
        }
        defer { IOObjectRelease(service) }

        return USBDeviceRegistryProperties(
            productName: stringProperty(
                service,
                keys: [kUSBProductString, "USB Product Name"]
            ),
            serialNumber: serialNumberProperty(
                service,
                key: IOUSBHostDevicePropertyKey.serialNumberString.rawValue
            ),
            containerID: containerIDProperty(
                service,
                key: IOUSBHostDevicePropertyKey.containerID.rawValue
            ),
            locationID: unsignedIntegerProperty(
                service,
                keys: [IOUSBHostPropertyKeyLocationID]
            ).flatMap { value in
                guard value > 0, value <= UInt64(UInt32.max) else {
                    return nil
                }
                return UInt32(value)
            }
        )
    }

    private static let emptyProperties = USBDeviceRegistryProperties(
        productName: nil,
        serialNumber: nil,
        containerID: nil,
        locationID: nil
    )

    private static func stringProperty(
        _ service: io_service_t,
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = property(service, key: key) as? String else {
                continue
            }

            let normalized = value
                .precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return nil
    }

    private static func serialNumberProperty(
        _ service: io_service_t,
        key: String
    ) -> Data? {
        guard let value = property(service, key: key) as? String,
              !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              let bytes = value.data(using: .utf8),
              !bytes.isEmpty,
              !isPlaceholderSerial(bytes) else {
            return nil
        }

        return bytes
    }

    private static func containerIDProperty(
        _ service: io_service_t,
        key: String
    ) -> UUID? {
        guard let value = property(service, key: key) as? String,
              let identifier = UUID(uuidString: value),
              identifier != zeroUUID else {
            return nil
        }

        return identifier
    }

    private static func isPlaceholderSerial(_ bytes: Data) -> Bool {
        let lowercasedBytes = bytes.map { byte -> UInt8 in
            guard byte >= 65, byte <= 90 else { return byte }
            return byte + 32
        }
        return lowercasedBytes.allSatisfy { $0 == 48 }
            || lowercasedBytes.allSatisfy { $0 == 102 }
    }

    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private static func unsignedIntegerProperty(
        _ service: io_service_t,
        keys: [String]
    ) -> UInt64? {
        for key in keys {
            if let number = property(service, key: key) as? NSNumber {
                return number.uint64Value
            }
        }

        return nil
    }

    private static func property(
        _ service: io_service_t,
        key: String
    ) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }
}
