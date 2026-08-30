/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

struct USBDeviceIdentityResolver {
    struct Resolution: Sendable {
        let productName: String?
        let identity: USBAccessoryReconnectIdentity?
    }

    static func resolve(
        registryID: UInt64,
        deviceDescriptorData: Data,
        previousIdentity: USBAccessoryReconnectIdentity?
    ) -> Resolution {
        guard let matching = IORegistryEntryIDMatching(registryID) else {
            return resolutionWithoutRegistry(
                deviceDescriptorData: deviceDescriptorData,
                previousIdentity: previousIdentity
            )
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            return resolutionWithoutRegistry(
                deviceDescriptorData: deviceDescriptorData,
                previousIdentity: previousIdentity
            )
        }
        defer { IOObjectRelease(service) }

        let resolvedIdentity = USBAccessoryReconnectIdentity(
            containerID: containerIDProperty(
                service,
                key: IOUSBHostDevicePropertyKey.containerID.rawValue
            ),
            serialNumber: serialNumberProperty(
                service,
                key: IOUSBHostDevicePropertyKey.serialNumberString.rawValue
            ),
            locationID: locationIDProperty(service),
            deviceDescriptorData: deviceDescriptorData
        )
        return Resolution(
            productName: stringProperty(
                service,
                keys: [kUSBProductString, "USB Product Name"]
            ),
            identity: reconciledIdentity(
                resolvedIdentity,
                previousIdentity: previousIdentity,
                deviceDescriptorData: deviceDescriptorData
            )
        )
    }

    private static func resolutionWithoutRegistry(
        deviceDescriptorData: Data,
        previousIdentity: USBAccessoryReconnectIdentity?
    ) -> Resolution {
        Resolution(
            productName: nil,
            identity: reconciledIdentity(
                nil,
                previousIdentity: previousIdentity,
                deviceDescriptorData: deviceDescriptorData
            )
        )
    }

    private static func reconciledIdentity(
        _ resolvedIdentity: USBAccessoryReconnectIdentity?,
        previousIdentity: USBAccessoryReconnectIdentity?,
        deviceDescriptorData: Data
    ) -> USBAccessoryReconnectIdentity? {
        guard let previousIdentity else {
            return resolvedIdentity
        }
        if let resolvedIdentity {
            return resolvedIdentity == previousIdentity ? resolvedIdentity : nil
        }
        return previousIdentity.deviceDescriptorData == deviceDescriptorData
            ? previousIdentity
            : nil
    }

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

    private static func locationIDProperty(_ service: io_service_t) -> UInt32? {
        guard let number = property(
            service,
            key: IOUSBHostPropertyKeyLocationID
        ) as? NSNumber else {
            return nil
        }
        let value = number.uint64Value
        guard value > 0, value <= UInt64(UInt32.max) else {
            return nil
        }
        return UInt32(value)
    }

    private static func isPlaceholderSerial(_ bytes: Data) -> Bool {
        let lowercasedBytes = bytes.map { byte -> UInt8 in
            guard byte >= 65, byte <= 90 else { return byte }
            return byte + 32
        }
        return lowercasedBytes.allSatisfy { $0 == 48 }
            || lowercasedBytes.allSatisfy { $0 == 102 }
    }

    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

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
