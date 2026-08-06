/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation

enum DummyEthernetConfigurationError: Error, Equatable, LocalizedError {
    case invalidIPv4Address
    case addressIsNotPrivate
    case invalidHostAddress
    case invalidInterfaceName
    case duplicateInterfaceNames

    var errorDescription: String? {
        switch self {
        case .invalidIPv4Address:
            String(localized: "Enter an IPv4 address.")
        case .addressIsNotPrivate:
            String(localized: "Use a private IPv4 address.")
        case .invalidHostAddress:
            String(localized: "Enter an IPv4 address.")
        case .invalidInterfaceName:
            String(localized: "Use fethX interface names.")
        case .duplicateInterfaceNames:
            String(localized: "The Bond member and router peer must use different feth interface names.")
        }
    }
}

enum DummyEthernetConfigurationValidator {
    static func validate(
        _ configuration: DummyEthernetConfiguration
    ) throws -> DummyEthernetConfiguration {
        let octets = try validatedOctets(
            from: configuration.hostIPv4Address
        )
        guard isRFC1918Address(octets) else {
            throw DummyEthernetConfigurationError.addressIsNotPrivate
        }
        guard (2 ... 254).contains(Int(octets[3])) else {
            throw DummyEthernetConfigurationError.invalidHostAddress
        }
        let interfaceNames = try validatedInterfaceNames(
            memberInterfaceName: configuration.memberInterfaceName,
            peerInterfaceName: configuration.peerInterfaceName
        )

        return DummyEthernetConfiguration(
            hostIPv4Address: octets.map(String.init).joined(separator: "."),
            memberInterfaceName: interfaceNames.member,
            peerInterfaceName: interfaceNames.peer
        )
    }

    static func validatedInterfaceNames(
        memberInterfaceName: String,
        peerInterfaceName: String
    ) throws -> (member: String, peer: String) {
        let member = try validatedInterfaceName(memberInterfaceName)
        let peer = try validatedInterfaceName(peerInterfaceName)
        guard member != peer else {
            throw DummyEthernetConfigurationError.duplicateInterfaceNames
        }
        return (member, peer)
    }

    private static func validatedOctets(
        from hostIPv4Address: String
    ) throws -> [UInt8] {
        let trimmedAddress = hostIPv4Address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var address = in_addr()
        guard trimmedAddress.withCString({
            inet_pton(AF_INET, $0, &address)
        }) == 1 else {
            throw DummyEthernetConfigurationError.invalidIPv4Address
        }
        let value = UInt32(bigEndian: address.s_addr)
        return [24, 16, 8, 0].map {
            UInt8(truncatingIfNeeded: value >> $0)
        }
    }

    private static func isRFC1918Address(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _):
            true
        case (172, 16 ... 31):
            true
        case (192, 168):
            true
        default:
            false
        }
    }

    private static func validatedInterfaceName(
        _ interfaceName: String
    ) throws -> String {
        let trimmedName = interfaceName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmedName.utf8.count
                <= ThruRNDISDummyEthernet.maximumInterfaceNameUTF8ByteCount,
              trimmedName.hasPrefix("feth") else {
            throw DummyEthernetConfigurationError.invalidInterfaceName
        }

        let unit = trimmedName.dropFirst("feth".count)
        guard !unit.isEmpty,
              unit.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let numericUnit = UInt(unit),
              String(numericUnit) == unit else {
            throw DummyEthernetConfigurationError.invalidInterfaceName
        }
        return trimmedName
    }
}
