/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation
import SystemConfiguration

struct NetworkRouteSystemConfigurationSnapshot: Sendable {
    let configuration: NetworkRouteConfiguration?
    let bondInterfaceName: String?
    let hasBond: Bool
    let hasNetworkService: Bool
    let isNetworkServiceEnabled: Bool
    let configuredHostIPv4Address: String?
    let configuredRouterIPv4Address: String?
    let configuredDNSServerAddresses: [String]
}

enum NetworkRouteSystemConfigurationError: Error, LocalizedError {
    case unavailable(String)
    case conflict(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "System network configuration is unavailable: \(detail)"
        case .conflict(let detail):
            "The Network Helper did not modify an ambiguous configuration: \(detail)"
        case .operationFailed(let detail):
            "Could not update System network configuration: \(detail)"
        }
    }
}

/// Owns the exact Bond and Network Service recorded in one SCPreferences
/// transaction. Runtime feth and VM-bridge membership remain explicit,
/// fixed-argument ifconfig operations in NetworkRouteController.
struct NetworkRouteSystemConfigurationService: Sendable {
    func inspect() throws -> NetworkRouteSystemConfigurationSnapshot {
        try withLockedPreferences { preferences in
            snapshot(from: try managedObjects(in: preferences))
        }
    }

    func createDisabledConfiguration(
        _ configuration: NetworkRouteConfiguration
    ) throws -> String {
        try withLockedPreferences { preferences in
            guard try metadata(in: preferences) == nil else {
                throw NetworkRouteSystemConfigurationError.conflict(
                    "A ThruRNDIS ownership record already exists."
                )
            }
            guard let bond = SCBondInterfaceCreate(preferences),
                  SCBondInterfaceSetLocalizedDisplayName(
                    bond,
                    ThruRNDISNetworkRoute.bondHardwarePortName as CFString
                  ),
                  let bondName = interfaceName(of: bond),
                  isCanonicalBondInterfaceName(bondName) else {
                throw lastError("create the Ethernet Bond")
            }
            guard let service = SCNetworkServiceCreate(preferences, bond),
                  SCNetworkServiceEstablishDefaultConfiguration(service),
                  SCNetworkServiceSetName(
                    service,
                    ThruRNDISNetworkRoute.networkServiceName as CFString
                  ),
                  let serviceID = SCNetworkServiceGetServiceID(service)
                    as String? else {
                throw lastError("create the ThruRNDIS Network Service")
            }

            var bondOptions = (SCBondInterfaceGetOptions(bond)
                as? [String: Any]) ?? [:]
            bondOptions[BondOptionKey.ownershipToken] = serviceID
            guard SCBondInterfaceSetOptions(
                bond,
                bondOptions as CFDictionary
            ) else {
                throw lastError("mark the Ethernet Bond as owned")
            }

            try configureProtocols(for: service)
            guard SCNetworkServiceSetEnabled(service, false),
                  let networkSet = SCNetworkSetCopyCurrent(preferences),
                  SCNetworkSetAddService(networkSet, service) else {
                throw lastError("add the disabled Network Service")
            }
            try moveServiceLast(service, in: networkSet)
            try setMetadata(
                bondInterfaceName: bondName,
                networkServiceID: serviceID,
                configuration: configuration,
                in: preferences
            )
            try commitAndApply(preferences)
            return bondName
        }
    }

    func enableNetworkService() throws {
        try setNetworkServiceEnabled(true)
    }

    func disableNetworkService() throws {
        try setNetworkServiceEnabled(false)
    }

    func withOwnedBondInterface(
        _ operation: (String) throws -> Void
    ) throws {
        try withLockedPreferences { preferences in
            guard let bond = try managedObjects(in: preferences).bond,
                  let bondInterfaceName = interfaceName(of: bond) else {
                return
            }
            try operation(bondInterfaceName)
        }
    }

    func removeConfiguration() throws {
        try withLockedPreferences { preferences in
            let objects = try managedObjects(in: preferences)
            var changed = false
            if let service = objects.service {
                guard SCNetworkServiceRemove(service) else {
                    throw lastError("remove the ThruRNDIS Network Service")
                }
                changed = true
            }
            if let bond = objects.bond {
                guard SCBondInterfaceRemove(bond) else {
                    throw lastError("remove the Ethernet Bond")
                }
                changed = true
            }
            if objects.metadata != nil {
                guard SCPreferencesRemoveValue(
                    preferences,
                    ThruRNDISNetworkRoute.systemConfigurationMetadataKey
                        as CFString
                ) else {
                    throw lastError("remove the network ownership metadata")
                }
                changed = true
            }
            if changed {
                try commitAndApply(preferences)
            }
        }
    }

    private func setNetworkServiceEnabled(_ enabled: Bool) throws {
        try withLockedPreferences { preferences in
            guard let service = try managedObjects(in: preferences).service else {
                throw NetworkRouteSystemConfigurationError.unavailable(
                    "The ThruRNDIS Network Service is missing."
                )
            }
            guard SCNetworkServiceSetEnabled(service, enabled) else {
                throw lastError(
                    enabled ? "enable the Network Service" : "disable the Network Service"
                )
            }
            try commitAndApply(preferences)
        }
    }

    private func managedObjects(
        in preferences: SCPreferences
    ) throws -> ManagedObjects {
        guard let metadata = try metadata(in: preferences) else {
            return ManagedObjects(bond: nil, service: nil, metadata: nil)
        }
        let matchingBonds = ((SCBondInterfaceCopyAll(preferences)
            as? [SCBondInterface]) ?? []).filter {
                interfaceName(of: $0) == metadata.bondInterfaceName
            }
        guard matchingBonds.count <= 1 else {
            throw NetworkRouteSystemConfigurationError.conflict(
                "More than one Ethernet Bond uses the recorded BSD name."
            )
        }
        let bond = matchingBonds.first
        if let bond,
           bondOwnershipToken(of: bond) != metadata.networkServiceID {
            throw NetworkRouteSystemConfigurationError.conflict(
                "The Ethernet Bond using the recorded BSD name does not carry the recorded ownership token."
            )
        }

        let service = SCNetworkServiceCopy(
            preferences,
            metadata.networkServiceID as CFString
        )
        if let service {
            guard let serviceInterface = SCNetworkServiceGetInterface(service),
                  interfaceName(of: serviceInterface)
                    == metadata.bondInterfaceName,
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(
                    serviceInterface
                  ),
                  CFEqual(interfaceType, kSCNetworkInterfaceTypeBond) else {
                throw NetworkRouteSystemConfigurationError.conflict(
                    "The recorded Network Service is not attached to the recorded Ethernet Bond."
                )
            }
            if let bond, !CFEqual(serviceInterface, bond) {
                throw NetworkRouteSystemConfigurationError.conflict(
                    "The recorded Network Service and Ethernet Bond do not identify the same object."
                )
            }
        }
        return ManagedObjects(
            bond: bond,
            service: service,
            metadata: metadata
        )
    }

    private func configureProtocols(for service: SCNetworkService) throws {
        guard let ipv4 = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeIPv4
        ) else {
            throw lastError("resolve the IPv4 service protocol")
        }
        let ipv4Configuration: [String: Any] = [
            kSCPropNetIPv4ConfigMethod as String:
                kSCValNetIPv4ConfigMethodManual,
            kSCPropNetIPv4Addresses as String:
                [ThruRNDISNetworkRoute.hostIPv4Address],
            kSCPropNetIPv4SubnetMasks as String:
                [ThruRNDISNetworkRoute.subnetMask],
            kSCPropNetIPv4Router as String:
                ThruRNDISNetworkRoute.routerIPv4Address,
        ]
        guard SCNetworkProtocolSetConfiguration(
            ipv4,
            ipv4Configuration as CFDictionary
        ), SCNetworkProtocolSetEnabled(ipv4, true) else {
            throw lastError("configure the IPv4 service protocol")
        }

        if let ipv6 = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeIPv6
        ), !SCNetworkProtocolSetEnabled(ipv6, false) {
            throw lastError("disable the IPv6 service protocol")
        }

        if SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeDNS
        ) == nil,
           !SCNetworkServiceAddProtocolType(
            service,
            kSCNetworkProtocolTypeDNS
           ) {
            throw lastError("add the DNS service protocol")
        }
        guard let dns = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeDNS
        ) else {
            throw lastError("resolve the DNS service protocol")
        }
        let dnsConfiguration: [String: Any] = [
            kSCPropNetDNSServerAddresses as String:
                [ThruRNDISNetworkRoute.routerIPv4Address],
        ]
        guard SCNetworkProtocolSetConfiguration(
            dns,
            dnsConfiguration as CFDictionary
        ), SCNetworkProtocolSetEnabled(dns, true) else {
            throw lastError("configure the DNS service protocol")
        }
    }

    private func snapshot(
        from objects: ManagedObjects
    ) -> NetworkRouteSystemConfigurationSnapshot {
        let protocols = objects.service.map(protocolSnapshot)
        return NetworkRouteSystemConfigurationSnapshot(
            configuration: objects.metadata?.configuration,
            bondInterfaceName: objects.metadata?.bondInterfaceName,
            hasBond: objects.bond != nil,
            hasNetworkService: objects.service != nil,
            isNetworkServiceEnabled: objects.service.map(
                SCNetworkServiceGetEnabled
            ) ?? false,
            configuredHostIPv4Address: protocols?.hostIPv4Address,
            configuredRouterIPv4Address: protocols?.routerIPv4Address,
            configuredDNSServerAddresses:
                protocols?.dnsServerAddresses ?? []
        )
    }

    private func protocolSnapshot(
        for service: SCNetworkService
    ) -> ProtocolSnapshot {
        let ipv4Configuration = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeIPv4
        ).flatMap(SCNetworkProtocolGetConfiguration) as? [String: Any]
        let dnsConfiguration = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeDNS
        ).flatMap(SCNetworkProtocolGetConfiguration) as? [String: Any]
        return ProtocolSnapshot(
            hostIPv4Address: (ipv4Configuration?[
                kSCPropNetIPv4Addresses as String
            ] as? [String])?.first,
            routerIPv4Address: ipv4Configuration?[
                kSCPropNetIPv4Router as String
            ] as? String,
            dnsServerAddresses: dnsConfiguration?[
                kSCPropNetDNSServerAddresses as String
            ] as? [String] ?? []
        )
    }

    private func moveServiceLast(
        _ service: SCNetworkService,
        in networkSet: SCNetworkSet
    ) throws {
        guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
            throw NetworkRouteSystemConfigurationError.unavailable(
                "The new Network Service has no identifier."
            )
        }
        let allServiceIDs = ((SCNetworkSetCopyServices(networkSet)
            as? [SCNetworkService]) ?? []).compactMap {
                SCNetworkServiceGetServiceID($0) as String?
            }
        var order = (SCNetworkSetGetServiceOrder(networkSet) as? [String]) ?? []
        for identifier in allServiceIDs where !order.contains(identifier) {
            order.append(identifier)
        }
        order.removeAll { $0 == serviceID }
        order.append(serviceID)
        guard SCNetworkSetSetServiceOrder(networkSet, order as CFArray) else {
            throw lastError("move the Network Service to the end of service order")
        }
    }

    private func metadata(
        in preferences: SCPreferences
    ) throws -> OwnershipMetadata? {
        guard let value = SCPreferencesGetValue(
            preferences,
            ThruRNDISNetworkRoute.systemConfigurationMetadataKey as CFString
        ) else {
            return nil
        }
        guard let values = value as? [String: String],
              let bondInterfaceName = values[MetadataKey.bondInterfaceName],
              let networkServiceID = values[MetadataKey.networkServiceID],
              let guestIPv4Address = values[MetadataKey.guestIPv4Address],
              let vznatGatewayIPv4Address = values[
                MetadataKey.vznatGatewayIPv4Address
              ],
              let bridgeInterfaceName = values[MetadataKey.bridgeInterfaceName]
        else {
            throw NetworkRouteSystemConfigurationError.conflict(
                "The stored network ownership metadata is malformed."
            )
        }
        guard isCanonicalBondInterfaceName(bondInterfaceName),
              isCanonicalBridgeInterfaceName(bridgeInterfaceName),
              !networkServiceID.isEmpty,
              isCanonicalIPv4Address(guestIPv4Address),
              isCanonicalIPv4Address(vznatGatewayIPv4Address),
              guestIPv4Address != vznatGatewayIPv4Address else {
            throw NetworkRouteSystemConfigurationError.conflict(
                "The stored network ownership metadata contains invalid values."
            )
        }
        return OwnershipMetadata(
            bondInterfaceName: bondInterfaceName,
            networkServiceID: networkServiceID,
            configuration: NetworkRouteConfiguration(
                guestIPv4Address: guestIPv4Address,
                vznatGatewayIPv4Address: vznatGatewayIPv4Address,
                bridgeInterfaceName: bridgeInterfaceName
            )
        )
    }

    private func setMetadata(
        bondInterfaceName: String,
        networkServiceID: String,
        configuration: NetworkRouteConfiguration,
        in preferences: SCPreferences
    ) throws {
        let metadata = [
            MetadataKey.bondInterfaceName: bondInterfaceName,
            MetadataKey.networkServiceID: networkServiceID,
            MetadataKey.guestIPv4Address: configuration.guestIPv4Address,
            MetadataKey.vznatGatewayIPv4Address:
                configuration.vznatGatewayIPv4Address,
            MetadataKey.bridgeInterfaceName:
                configuration.bridgeInterfaceName,
        ]
        guard SCPreferencesSetValue(
            preferences,
            ThruRNDISNetworkRoute.systemConfigurationMetadataKey as CFString,
            metadata as CFDictionary
        ) else {
            throw lastError("store the network ownership metadata")
        }
    }

    private func interfaceName(
        of interface: SCNetworkInterface
    ) -> String? {
        SCNetworkInterfaceGetBSDName(interface) as String?
    }

    private func bondOwnershipToken(
        of bond: SCBondInterface
    ) -> String? {
        let options = SCBondInterfaceGetOptions(bond) as? [String: Any]
        return options?[BondOptionKey.ownershipToken] as? String
    }

    private func isCanonicalBondInterfaceName(_ name: String) -> Bool {
        isCanonicalInterfaceName(name, prefix: "bond")
    }

    private func isCanonicalBridgeInterfaceName(_ name: String) -> Bool {
        isCanonicalInterfaceName(name, prefix: "bridge")
    }

    private func isCanonicalInterfaceName(
        _ name: String,
        prefix: String
    ) -> Bool {
        guard name.utf8.count < Int(IFNAMSIZ),
              name.hasPrefix(prefix) else {
            return false
        }
        let unit = name.dropFirst(prefix.count)
        return !unit.isEmpty
            && unit.utf8.allSatisfy { (48 ... 57).contains($0) }
            && UInt(unit).map { String($0) == unit } == true
    }

    private func isCanonicalIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return false
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(
            AF_INET,
            &address,
            &buffer,
            socklen_t(INET_ADDRSTRLEN)
        ) != nil else {
            return false
        }
        return String(cString: buffer) == value
    }

    private func withLockedPreferences<Result>(
        operation: (SCPreferences) throws -> Result
    ) throws -> Result {
        guard let preferences = SCPreferencesCreate(
            nil,
            "ThruRNDISPrivilegedHelper" as CFString,
            nil
        ) else {
            throw NetworkRouteSystemConfigurationError.unavailable(
                "SCPreferencesCreate failed."
            )
        }
        guard SCPreferencesLock(preferences, false) else {
            throw lastError("lock System network preferences")
        }
        defer { SCPreferencesUnlock(preferences) }
        SCPreferencesSynchronize(preferences)
        return try operation(preferences)
    }

    private func commitAndApply(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences),
              SCPreferencesApplyChanges(preferences) else {
            throw lastError("commit and apply System network preferences")
        }
    }

    private func lastError(
        _ operation: String
    ) -> NetworkRouteSystemConfigurationError {
        .operationFailed(
            "\(operation): \(String(cString: SCErrorString(SCError())))"
        )
    }

    private struct OwnershipMetadata {
        let bondInterfaceName: String
        let networkServiceID: String
        let configuration: NetworkRouteConfiguration
    }

    private enum MetadataKey {
        static let bondInterfaceName = "BondInterfaceName"
        static let networkServiceID = "NetworkServiceID"
        static let guestIPv4Address = "GuestIPv4Address"
        static let vznatGatewayIPv4Address = "VZNATGatewayIPv4Address"
        static let bridgeInterfaceName = "BridgeInterfaceName"
    }

    private enum BondOptionKey {
        static let ownershipToken =
            "ThruRNDIS.NetworkRoute.OwnershipToken"
    }

    private struct ManagedObjects {
        let bond: SCBondInterface?
        let service: SCNetworkService?
        let metadata: OwnershipMetadata?
    }

    private struct ProtocolSnapshot {
        let hostIPv4Address: String?
        let routerIPv4Address: String?
        let dnsServerAddresses: [String]
    }
}
