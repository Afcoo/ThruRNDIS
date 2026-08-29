/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation

enum VZNATInterfaceResolverError: LocalizedError {
    case invalidGuestIPv4Address
    case guestIPv4AddressNotPrivate
    case invalidGatewayIPv4Address
    case gatewayIPv4AddressNotPrivate
    case managedSubnetOverlap
    case interfaceEnumerationFailed(Int32)
    case noDirectlyConnectedInterface
    case ambiguousDirectlyConnectedInterfaces([String])

    var errorDescription: String? {
        switch self {
        case .invalidGuestIPv4Address:
            "The guest VZNAT address is not a valid IPv4 address."
        case .guestIPv4AddressNotPrivate:
            "The guest VZNAT address must be in an RFC 1918 private network."
        case .invalidGatewayIPv4Address:
            "The VZNAT gateway is not a valid IPv4 address."
        case .gatewayIPv4AddressNotPrivate:
            "The VZNAT gateway must be in an RFC 1918 private network."
        case .managedSubnetOverlap:
            "The VZNAT network overlaps the managed 192.168.100.0/24 network."
        case .interfaceEnumerationFailed(let code):
            "Could not enumerate host network interfaces (errno \(code))."
        case .noDirectlyConnectedInterface:
            "No active VZNAT bridge has the reported gateway and contains the guest address."
        case .ambiguousDirectlyConnectedInterfaces(let names):
            "The guest VZNAT address matches more than one directly connected host interface: \(names.joined(separator: ", "))."
        }
    }
}

struct VZNATInterfaceResolver: Sendable {
    func resolve(
        guestIPv4Address: String,
        vznatGatewayIPv4Address: String
    ) throws -> String {
        guard let guest = IPv4Value(guestIPv4Address) else {
            throw VZNATInterfaceResolverError.invalidGuestIPv4Address
        }
        guard guest.isRFC1918 else {
            throw VZNATInterfaceResolverError.guestIPv4AddressNotPrivate
        }
        guard let gateway = IPv4Value(vznatGatewayIPv4Address) else {
            throw VZNATInterfaceResolverError.invalidGatewayIPv4Address
        }
        guard gateway.isRFC1918 else {
            throw VZNATInterfaceResolverError.gatewayIPv4AddressNotPrivate
        }

        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0 else {
            throw VZNATInterfaceResolverError.interfaceEnumerationFailed(errno)
        }
        defer { freeifaddrs(interfaceList) }

        // Darwin exposes if_data on the AF_LINK entry. The IPv4 entry for the
        // same interface normally has no ifa_data, so resolve type separately.
        var bridgeInterfaceNames: Set<String> = []
        var typeCursor = interfaceList
        while let current = typeCursor {
            defer { typeCursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard let addressPointer = entry.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_LINK),
                  let interfaceData = entry.ifa_data,
                  interfaceData.assumingMemoryBound(
                    to: if_data.self
                  ).pointee.ifi_type == UInt8(IFT_BRIDGE) else {
                continue
            }
            bridgeInterfaceNames.insert(String(cString: entry.ifa_name))
        }

        var candidates: Set<Candidate> = []
        var cursor = interfaceList
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard let addressPointer = entry.ifa_addr,
                  let netmaskPointer = entry.ifa_netmask,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  netmaskPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0 else {
                continue
            }

            let name = String(cString: entry.ifa_name)
            guard Self.isCanonicalBridgeInterfaceName(name),
                  bridgeInterfaceNames.contains(name),
                  name.utf8.count < Int(IFNAMSIZ),
                  if_nametoindex(name) != 0 else {
                continue
            }

            let host = Self.ipv4Value(from: addressPointer)
            let mask = Self.ipv4Value(from: netmaskPointer)
            guard let prefixLength = Self.prefixLength(for: mask.rawValue),
                  prefixLength <= 30,
                  host == gateway,
                  (host.rawValue & mask.rawValue)
                    == (guest.rawValue & mask.rawValue),
                  host != guest else {
                continue
            }

            let hostBits = ~mask.rawValue
            let network = guest.rawValue & mask.rawValue
            let broadcast = network | hostBits
            guard guest.rawValue != network,
                  guest.rawValue != broadcast,
                  gateway.rawValue != network,
                  gateway.rawValue != broadcast else {
                continue
            }
            try Self.rejectManagedSubnetOverlap(
                network: network,
                broadcast: broadcast
            )

            candidates.insert(
                Candidate(
                    name: name,
                    hostIPv4Address: host.description,
                    prefixLength: prefixLength
                )
            )
        }

        guard let candidate = candidates.first else {
            throw VZNATInterfaceResolverError.noDirectlyConnectedInterface
        }
        guard candidates.count == 1 else {
            throw VZNATInterfaceResolverError
                .ambiguousDirectlyConnectedInterfaces(
                    candidates
                        .map { "\($0.name) (\($0.hostIPv4Address)/\($0.prefixLength))" }
                        .sorted()
                )
        }
        return candidate.name
    }

    private static func rejectManagedSubnetOverlap(
        network: UInt32,
        broadcast: UInt32
    ) throws {
        guard let managedAddress = IPv4Value(
            ThruRNDISNetworkRoute.hostIPv4Address
        ), let managedMask = IPv4Value(ThruRNDISNetworkRoute.subnetMask) else {
            preconditionFailure("The managed network constants must be IPv4 values.")
        }
        let managedNetwork = managedAddress.rawValue & managedMask.rawValue
        let managedBroadcast = managedNetwork | ~managedMask.rawValue
        guard broadcast < managedNetwork || network > managedBroadcast else {
            throw VZNATInterfaceResolverError.managedSubnetOverlap
        }
    }

    private static func isCanonicalBridgeInterfaceName(_ name: String) -> Bool {
        guard name.hasPrefix("bridge") else { return false }
        let unit = name.dropFirst("bridge".count)
        return !unit.isEmpty
            && unit.utf8.allSatisfy { (48 ... 57).contains($0) }
            && UInt(unit).map { String($0) == unit } == true
    }

    private static func ipv4Value(
        from pointer: UnsafePointer<sockaddr>
    ) -> IPv4Value {
        let address = UnsafeRawPointer(pointer).assumingMemoryBound(
            to: sockaddr_in.self
        ).pointee.sin_addr
        return IPv4Value(rawValue: UInt32(bigEndian: address.s_addr))
    }

    private static func prefixLength(for mask: UInt32) -> Int? {
        let inverted = ~mask
        guard inverted == 0 || inverted & (inverted &+ 1) == 0 else {
            return nil
        }
        return mask.nonzeroBitCount
    }

    private struct Candidate: Hashable {
        let name: String
        let hostIPv4Address: String
        let prefixLength: Int
    }
}

private struct IPv4Value: Equatable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init?(_ text: String) {
        var address = in_addr()
        guard text.withCString({
            inet_pton(AF_INET, $0, &address)
        }) == 1 else {
            return nil
        }
        rawValue = UInt32(bigEndian: address.s_addr)
        guard description == text else {
            return nil
        }
    }

    var isRFC1918: Bool {
        (rawValue & 0xFF00_0000) == 0x0A00_0000
            || (rawValue & 0xFFF0_0000) == 0xAC10_0000
            || (rawValue & 0xFFFF_0000) == 0xC0A8_0000
    }

    var description: String {
        [24, 16, 8, 0]
            .map { String((rawValue >> UInt32($0)) & 0xFF) }
            .joined(separator: ".")
    }
}
