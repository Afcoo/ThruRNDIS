/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation

enum NetworkRoutePolicy: Equatable, Sendable {
    case defaultRoute
    case selectedSubnets([IPv4Subnet])

    /// Only an absent specification selects the default route. An empty or
    /// malformed list must also fail closed when received by the helper.
    init(selectedSubnets: String?) throws {
        guard let selectedSubnets else {
            self = .defaultRoute
            return
        }
        // Bound the configuration processed by the privileged helper and configd.
        guard !selectedSubnets.isEmpty else { throw SubnetValidationError.invalidCIDR }
        guard selectedSubnets.utf8.count <= 16 * 1024 else {
            throw SubnetValidationError.tooLong
        }
        let entries = selectedSubnets.split(separator: ",", omittingEmptySubsequences: false)
        let subnets = try entries.map { entry in
            try IPv4Subnet(entry.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let sorted = Set(subnets).sorted {
            ($0.network.rawValue, $0.prefixLength) < ($1.network.rawValue, $1.prefixLength)
        }
        // A list can express a default route as several prefixes, e.g. two /1s.
        var firstUncovered: UInt64 = 0
        for subnet in sorted {
            if UInt64(subnet.network.rawValue) > firstUncovered { break }
            let last = subnet.network.rawValue | ~subnet.subnetMask.rawValue
            firstUncovered = max(firstUncovered, UInt64(last) + 1)
        }
        guard firstUncovered <= UInt64(UInt32.max) else {
            throw SubnetValidationError.defaultRoute
        }
        self = .selectedSubnets(sorted)
    }

    var subnetSpecification: String? {
        guard case .selectedSubnets(let subnets) = self else { return nil }
        return subnets.map { "\($0.network)/\($0.prefixLength)" }.joined(separator: ",")
    }
}

struct IPv4Subnet: Hashable, Sendable {
    let network: IPv4Value
    let prefixLength: Int

    var subnetMask: IPv4Value {
        IPv4Value(rawValue: UInt32.max << (32 - prefixLength))
    }

    fileprivate init(_ specification: String) throws {
        let parts = specification.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = IPv4Value(String(parts[0])),
              let prefix = Int(parts[1]), String(prefix) == parts[1],
              (0...32).contains(prefix) else {
            throw SubnetValidationError.invalidCIDR
        }
        guard prefix > 0 else { throw SubnetValidationError.defaultRoute }
        network = address
        prefixLength = prefix
        let base = address.rawValue & subnetMask.rawValue
        guard base == address.rawValue else {
            throw SubnetValidationError.hostBits("\(IPv4Value(rawValue: base))/\(prefix)")
        }
        // A route inside the directly connected Bond subnet could route its
        // own next hop back through the guest.
        if let host = IPv4Value(ThruRNDISNetworkRoute.hostIPv4Address),
           let mask = IPv4Value(ThruRNDISNetworkRoute.subnetMask),
           prefix >= mask.rawValue.nonzeroBitCount,
           base & mask.rawValue == host.rawValue & mask.rawValue {
            throw SubnetValidationError.managedSubnet
        }
    }
}

private enum SubnetValidationError: LocalizedError {
    case invalidCIDR
    case tooLong
    case defaultRoute
    case hostBits(String)
    case managedSubnet

    var errorDescription: String? {
        switch self {
        case .invalidCIDR:
            String(localized: "Enter comma-separated IPv4 networks in CIDR notation.")
        case .tooLong:
            String(localized: "The IPv4 subnet list exceeds 16 KB.")
        case .defaultRoute:
            String(localized: "Use Default route to send all IPv4 traffic.")
        case .hostBits(let network):
            String(localized: "Use the network address \(network).")
        case .managedSubnet:
            String(localized: "192.168.100.0/24 is reserved for the link to the guest.")
        }
    }
}

struct IPv4Value: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init?(_ text: String) {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        rawValue = UInt32(bigEndian: address.s_addr)
        guard description == text else { return nil }
    }

    var description: String {
        [24, 16, 8, 0]
            .map { String((rawValue >> UInt32($0)) & 0xFF) }
            .joined(separator: ".")
    }
}
