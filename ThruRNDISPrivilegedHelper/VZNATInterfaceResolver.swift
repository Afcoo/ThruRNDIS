/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation

struct VZNATInterfaceSnapshot: Equatable, Sendable {
    let name: String
    let hostIPv4Address: String
    let prefixLength: Int
}

enum VZNATInterfaceResolverError: LocalizedError {
    case invalidGuestIPv4Address
    case guestIPv4AddressNotPrivate
    case interfaceEnumerationFailed(Int32)
    case noDirectlyConnectedInterface
    case ambiguousDirectlyConnectedInterfaces([String])

    var errorDescription: String? {
        switch self {
        case .invalidGuestIPv4Address:
            "The guest VZNAT address is not a valid IPv4 address."
        case .guestIPv4AddressNotPrivate:
            "The guest VZNAT address must be in an RFC 1918 private network."
        case .interfaceEnumerationFailed(let code):
            "Could not enumerate host network interfaces (errno \(code))."
        case .noDirectlyConnectedInterface:
            "No active, directly connected host interface contains the guest VZNAT address."
        case .ambiguousDirectlyConnectedInterfaces(let names):
            "The guest VZNAT address matches more than one directly connected host interface: \(names.joined(separator: ", "))."
        }
    }
}

struct VZNATInterfaceResolver: Sendable {
    func validateGuestIPv4Address(_ guestIPv4Address: String) throws {
        guard let guest = IPv4Value(guestIPv4Address) else {
            throw VZNATInterfaceResolverError.invalidGuestIPv4Address
        }
        guard guest.isRFC1918 else {
            throw VZNATInterfaceResolverError.guestIPv4AddressNotPrivate
        }
    }

    func resolve(guestIPv4Address: String) throws -> VZNATInterfaceSnapshot {
        try validateGuestIPv4Address(guestIPv4Address)
        guard let guest = IPv4Value(guestIPv4Address) else {
            throw VZNATInterfaceResolverError.invalidGuestIPv4Address
        }

        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0 else {
            throw VZNATInterfaceResolverError.interfaceEnumerationFailed(errno)
        }
        defer { freeifaddrs(interfaceList) }

        var candidates: [VZNATInterfaceSnapshot] = []
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
            guard !name.isEmpty,
                  name.utf8.count < Int(IFNAMSIZ),
                  if_nametoindex(name) != 0 else {
                continue
            }

            let host = Self.ipv4Value(from: addressPointer)
            let mask = Self.ipv4Value(from: netmaskPointer)
            guard let prefixLength = Self.prefixLength(for: mask.rawValue),
                  prefixLength <= 30,
                  (host.rawValue & mask.rawValue)
                    == (guest.rawValue & mask.rawValue),
                  host != guest else {
                continue
            }

            let hostBits = ~mask.rawValue
            let network = guest.rawValue & mask.rawValue
            let broadcast = network | hostBits
            guard guest.rawValue != network,
                  guest.rawValue != broadcast else {
                continue
            }

            candidates.append(
                VZNATInterfaceSnapshot(
                    name: name,
                    hostIPv4Address: host.description,
                    prefixLength: prefixLength
                )
            )
        }

        let uniqueCandidates = Array(Set(candidates.map {
            CandidateKey(
                name: $0.name,
                hostIPv4Address: $0.hostIPv4Address,
                prefixLength: $0.prefixLength
            )
        })).map {
            VZNATInterfaceSnapshot(
                name: $0.name,
                hostIPv4Address: $0.hostIPv4Address,
                prefixLength: $0.prefixLength
            )
        }

        guard !uniqueCandidates.isEmpty else {
            throw VZNATInterfaceResolverError.noDirectlyConnectedInterface
        }
        guard uniqueCandidates.count == 1 else {
            throw VZNATInterfaceResolverError
                .ambiguousDirectlyConnectedInterfaces(
                    uniqueCandidates
                        .map { "\($0.name) (\($0.hostIPv4Address)/\($0.prefixLength))" }
                        .sorted()
                )
        }
        return uniqueCandidates[0]
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

    private struct CandidateKey: Hashable {
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
