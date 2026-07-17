// SPDX-License-Identifier: MIT
// Copyright (C) 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import WireGuardKit

extension TunnelConfiguration {
    enum WgQuickParserState {
        case inInterfaceSection
        case inPeerSection
        case notInASection
    }

    enum WgQuickParseError: Error {
        case invalidLine(String.SubSequence)
        case noInterface
        case multipleInterfaces
        case interfaceHasNoPrivateKey
        case interfaceHasInvalidPrivateKey(String)
        case interfaceHasInvalidListenPort(String)
        case interfaceHasInvalidAddress(String)
        case interfaceHasInvalidMTU(String)
        case interfaceHasUnrecognizedKey(String)
        case peerHasNoPublicKey
        case peerHasInvalidPublicKey(String)
        case peerHasInvalidPreSharedKey(String)
        case peerHasInvalidAllowedIP(String)
        case peerHasInvalidEndpoint(String)
        case peerHasInvalidPersistentKeepAlive(String)
        case peerHasUnrecognizedKey(String)
        case multiplePeersWithSamePublicKey
        case multipleEntriesForKey(String)
    }

    convenience init(fromWgQuickConfig wgQuickConfig: String, called name: String? = nil) throws {
        var interfaceConfiguration: InterfaceConfiguration?
        var peerConfigurations = [PeerConfiguration]()
        let lines = wgQuickConfig.split { $0.isNewline }
        var parserState = WgQuickParserState.notInASection
        var attributes = [String: String]()

        for (lineIndex, line) in lines.enumerated() {
            var trimmedLine: String
            if let commentRange = line.range(of: "#") {
                trimmedLine = String(line[..<commentRange.lowerBound])
            } else {
                trimmedLine = String(line)
            }

            trimmedLine = trimmedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = trimmedLine.lowercased()

            if !trimmedLine.isEmpty {
                if let equalsIndex = trimmedLine.firstIndex(of: "=") {
                    let keyWithCase = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = keyWithCase.lowercased()
                    let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let keysWithMultipleEntriesAllowed: Set<String> = ["address", "allowedips", "dns"]
                    if let presentValue = attributes[key] {
                        if keysWithMultipleEntriesAllowed.contains(key) {
                            attributes[key] = presentValue + "," + value
                        } else {
                            throw WgQuickParseError.multipleEntriesForKey(keyWithCase)
                        }
                    } else {
                        attributes[key] = value
                    }

                    let interfaceSectionKeys: Set<String> = ["privatekey", "listenport", "address", "dns", "mtu"]
                    let peerSectionKeys: Set<String> = [
                        "publickey",
                        "presharedkey",
                        "allowedips",
                        "endpoint",
                        "persistentkeepalive"
                    ]

                    if parserState == .inInterfaceSection {
                        guard interfaceSectionKeys.contains(key) else {
                            throw WgQuickParseError.interfaceHasUnrecognizedKey(keyWithCase)
                        }
                    } else if parserState == .inPeerSection {
                        guard peerSectionKeys.contains(key) else {
                            throw WgQuickParseError.peerHasUnrecognizedKey(keyWithCase)
                        }
                    }
                } else if lowercasedLine != "[interface]" && lowercasedLine != "[peer]" {
                    throw WgQuickParseError.invalidLine(line)
                }
            }

            let isLastLine = lineIndex == lines.count - 1
            if isLastLine || lowercasedLine == "[interface]" || lowercasedLine == "[peer]" {
                if parserState == .inInterfaceSection {
                    let interface = try TunnelConfiguration.collate(interfaceAttributes: attributes)
                    guard interfaceConfiguration == nil else { throw WgQuickParseError.multipleInterfaces }
                    interfaceConfiguration = interface
                } else if parserState == .inPeerSection {
                    let peer = try TunnelConfiguration.collate(peerAttributes: attributes)
                    peerConfigurations.append(peer)
                }
            }

            if lowercasedLine == "[interface]" {
                parserState = .inInterfaceSection
                attributes.removeAll()
            } else if lowercasedLine == "[peer]" {
                parserState = .inPeerSection
                attributes.removeAll()
            }
        }

        let peerPublicKeysArray = peerConfigurations.map { $0.publicKey }
        let peerPublicKeysSet = Set<PublicKey>(peerPublicKeysArray)
        guard peerPublicKeysArray.count == peerPublicKeysSet.count else {
            throw WgQuickParseError.multiplePeersWithSamePublicKey
        }

        guard let interfaceConfiguration else {
            throw WgQuickParseError.noInterface
        }

        self.init(name: name, interface: interfaceConfiguration, peers: peerConfigurations)
    }

    private static func collate(interfaceAttributes attributes: [String: String]) throws -> InterfaceConfiguration {
        guard let privateKeyString = attributes["privatekey"] else {
            throw WgQuickParseError.interfaceHasNoPrivateKey
        }
        guard let privateKey = PrivateKey(base64Key: privateKeyString) else {
            throw WgQuickParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        if let listenPortString = attributes["listenport"] {
            guard let listenPort = UInt16(listenPortString) else {
                throw WgQuickParseError.interfaceHasInvalidListenPort(listenPortString)
            }
            interface.listenPort = listenPort
        }
        if let addressesString = attributes["address"] {
            var addresses = [IPAddressRange]()
            for addressString in commaSeparatedValues(in: addressesString) {
                guard let address = IPAddressRange(from: addressString) else {
                    throw WgQuickParseError.interfaceHasInvalidAddress(addressString)
                }
                addresses.append(address)
            }
            interface.addresses = addresses
        }
        if let dnsString = attributes["dns"] {
            var dnsServers = [DNSServer]()
            var dnsSearch = [String]()
            for dnsServerString in commaSeparatedValues(in: dnsString) {
                if let dnsServer = DNSServer(from: dnsServerString) {
                    dnsServers.append(dnsServer)
                } else {
                    dnsSearch.append(dnsServerString)
                }
            }
            interface.dns = dnsServers
            interface.dnsSearch = dnsSearch
        }
        if let mtuString = attributes["mtu"] {
            guard let mtu = UInt16(mtuString) else {
                throw WgQuickParseError.interfaceHasInvalidMTU(mtuString)
            }
            interface.mtu = mtu
        }
        return interface
    }

    private static func collate(peerAttributes attributes: [String: String]) throws -> PeerConfiguration {
        guard let publicKeyString = attributes["publickey"] else {
            throw WgQuickParseError.peerHasNoPublicKey
        }
        guard let publicKey = PublicKey(base64Key: publicKeyString) else {
            throw WgQuickParseError.peerHasInvalidPublicKey(publicKeyString)
        }

        var peer = PeerConfiguration(publicKey: publicKey)
        if let preSharedKeyString = attributes["presharedkey"] {
            guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
                throw WgQuickParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
            }
            peer.preSharedKey = preSharedKey
        }
        if let allowedIPsString = attributes["allowedips"] {
            var allowedIPs = [IPAddressRange]()
            for allowedIPString in commaSeparatedValues(in: allowedIPsString) {
                guard let allowedIP = IPAddressRange(from: allowedIPString) else {
                    throw WgQuickParseError.peerHasInvalidAllowedIP(allowedIPString)
                }
                allowedIPs.append(allowedIP)
            }
            peer.allowedIPs = allowedIPs
        }
        if let endpointString = attributes["endpoint"] {
            guard let endpoint = Endpoint(from: endpointString) else {
                throw WgQuickParseError.peerHasInvalidEndpoint(endpointString)
            }
            peer.endpoint = endpoint
        }
        if let persistentKeepAliveString = attributes["persistentkeepalive"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw WgQuickParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            peer.persistentKeepAlive = persistentKeepAlive
        }
        return peer
    }

    private static func commaSeparatedValues(in value: String) -> [String] {
        value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
