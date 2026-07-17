/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import WireGuardKit

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
    static func invalidFields(
        endpoint: String?,
        allowedIPs: String,
        dnsServers: String
    ) -> Set<WireGuardConnectionField> {
        var invalidFields: Set<WireGuardConnectionField> = []

        if !isValidEndpoint(endpoint) {
            invalidFields.insert(.endpoint)
        }

        if !isValidAllowedIPs(allowedIPs) {
            invalidFields.insert(.allowedIPs)
        }

        if !isValidDNSServers(dnsServers) {
            invalidFields.insert(.dnsServers)
        }

        return invalidFields
    }

    static func isValidEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint else {
            return false
        }
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, Endpoint(from: value) != nil else {
            return false
        }

        let host: String
        let port: Substring
        guard value.first != "[",
              let separator = value.lastIndex(of: ":"),
              separator > value.startIndex else {
            return false
        }
        host = String(value[..<separator])
        port = value[value.index(after: separator)...]
        guard !host.contains(":"), isValidEndpointHost(host) else {
            return false
        }

        guard isASCIIUnsignedInteger(port),
              let portNumber = UInt16(port),
              portNumber > 0 else {
            return false
        }
        return true
    }

    static func isValidAllowedIPs(_ allowedIPs: String) -> Bool {
        let entries = allowedIPs.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard !entries.isEmpty else {
            return false
        }

        return entries.allSatisfy { rawEntry in
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else {
                return false
            }
            let components = entry.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard (1...2).contains(components.count),
                  !components[0].isEmpty else {
                return false
            }

            let address = String(components[0])
            guard isValidIPv4Address(address) else {
                return false
            }

            if components.count == 2 {
                guard isASCIIUnsignedInteger(components[1]),
                      let prefixLength = UInt8(components[1]),
                      prefixLength <= 32 else {
                    return false
                }
            }

            return IPAddressRange(from: entry) != nil
        }
    }

    static func isValidDNSServers(_ dnsServers: String) -> Bool {
        let normalizedNewlines = dnsServers
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let entries = normalizedNewlines.components(
            separatedBy: CharacterSet(charactersIn: ",\n")
        )
        guard !entries.isEmpty else {
            return false
        }

        return entries.allSatisfy { rawEntry in
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            return !entry.isEmpty
                && isValidIPAddress(entry)
                && DNSServer(from: entry) != nil
        }
    }

    private static func isValidEndpointHost(_ host: String) -> Bool {
        if isValidIPv4Address(host) {
            return true
        }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            return false
        }

        let name = host.last == "." ? String(host.dropLast()) : host
        guard !name.isEmpty, name.utf8.count <= 253 else {
            return false
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  let first = label.utf8.first,
                  let last = label.utf8.last,
                  isASCIIAlphanumeric(first),
                  isASCIIAlphanumeric(last) else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                isASCIIAlphanumeric(byte) || byte == 45
            }
        }
    }

    private static func isValidIPAddress(_ address: String) -> Bool {
        isValidIPv4Address(address)
    }

    private static func isValidIPv4Address(_ address: String) -> Bool {
        let octets = address.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard octets.count == 4 else {
            return false
        }

        return octets.allSatisfy { octet in
            guard isASCIIUnsignedInteger(octet),
                  octet.count <= 3,
                  octet.count == 1 || octet.first != "0",
                  let value = UInt16(octet) else {
                return false
            }
            return value <= 255
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
