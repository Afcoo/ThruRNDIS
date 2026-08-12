/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import Network

enum WireGuardConnectionField: CaseIterable, Hashable {
    case endpoint
    case allowedIPs
    case dnsServers

    var displayName: String {
        switch self {
        case .endpoint:
            return "Endpoint"
        case .allowedIPs:
            return "Allowed IPs"
        case .dnsServers:
            return "DNS Servers"
        }
    }
}

struct WireGuardConnectionValidator {
    static func endpoint(from endpoint: String) -> String? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.first != "[",
              let separator = value.lastIndex(of: ":"),
              separator > value.startIndex else {
            return nil
        }

        let host = String(value[..<separator])
        let portText = value[value.index(after: separator)...]
        guard !host.contains(":"),
              isValidEndpointHost(host),
              isASCIIUnsignedInteger(portText),
              let port = UInt16(portText),
              port > 0 else {
            return nil
        }
        return "\(host):\(port)"
    }

    static func allowedIPRanges(from allowedIPs: String) -> [String]? {
        let entries = allowedIPs.split(separator: ",", omittingEmptySubsequences: false)
        guard !entries.isEmpty else {
            return nil
        }

        var ranges: [String] = []
        ranges.reserveCapacity(entries.count)
        for entry in entries {
            guard let range = normalizedIPRange(String(entry)) else {
                return nil
            }
            ranges.append(range)
        }
        return ranges
    }

    static func dnsServerAddresses(from dnsServers: String) -> [String]? {
        let entries = dnsServers
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
        guard !entries.isEmpty else {
            return nil
        }

        let addresses = entries.compactMap { rawEntry -> String? in
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let address = IPv4Address(entry) else {
                return nil
            }
            return String(describing: address)
        }
        return addresses.count == entries.count ? addresses : nil
    }

    private static func normalizedIPRange(_ rawValue: String) -> String? {
        let entry = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              let address = IPv4Address(String(components[0])) else {
            return nil
        }

        let prefixLength: UInt8
        if components.count == 2 {
            guard isASCIIUnsignedInteger(components[1]),
                  let value = UInt8(components[1]),
                  value <= 32 else {
                return nil
            }
            prefixLength = value
        } else {
            prefixLength = 32
        }
        return "\(address)/\(prefixLength)"
    }

    private static func isValidEndpointHost(_ host: String) -> Bool {
        if IPv4Address(host) != nil {
            return true
        }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            return false
        }

        let name = host.last == "." ? String(host.dropLast()) : host
        guard !name.isEmpty, name.utf8.count <= 253 else {
            return false
        }
        return name.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                guard !label.isEmpty,
                      label.utf8.count <= 63,
                      let first = label.utf8.first,
                      let last = label.utf8.last,
                      isASCIIAlphanumeric(first),
                      isASCIIAlphanumeric(last) else {
                    return false
                }
                return label.utf8.allSatisfy {
                    isASCIIAlphanumeric($0) || $0 == 45
                }
            }
    }

    private static func isASCIIUnsignedInteger<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
    }
}
