/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import SystemConfiguration

struct DummyEthernetSystemConfigurationSnapshot: Sendable {
    let bondInterfaceName: String?
    let memberInterfaceName: String?
    let peerInterfaceName: String?
    let hasConfiguration: Bool
    let hasBond: Bool
    let hasNetworkService: Bool
    let isNetworkServiceEnabled: Bool
    let configuredIPv4Address: String?
}

enum DummyEthernetSystemConfigurationError: Error, LocalizedError {
    case unavailable(String)
    case conflict(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "System network configuration is unavailable: \(detail)"
        case .conflict(let detail):
            "Dummy Ethernet did not modify an ambiguous configuration: \(detail)"
        case .operationFailed(let detail):
            "Could not update System network configuration: \(detail)"
        }
    }
}

/// Owns the Bond and Network Service through SystemConfiguration. The feth
/// pair and runtime Bond membership remain explicit ifconfig operations.
struct DummyEthernetSystemConfigurationService: Sendable {
    func inspect() throws -> DummyEthernetSystemConfigurationSnapshot {
        try withLockedPreferences { preferences in
            snapshot(from: try managedObjects(in: preferences))
        }
    }

    func createDisabledConfiguration(
        _ configuration: DummyEthernetConfiguration
    ) throws -> String {
        try withLockedPreferences { preferences in
            guard try metadata(in: preferences) == nil else {
                throw DummyEthernetSystemConfigurationError.conflict(
                    "A ThruRNDIS ownership record already exists."
                )
            }
            guard let bond = SCBondInterfaceCreate(preferences),
                  SCBondInterfaceSetLocalizedDisplayName(
                    bond,
                    ThruRNDISDummyEthernet.bondHardwarePortName as CFString
                  ),
                  let bondName = interfaceName(of: bond) else {
                throw lastError("create the Ethernet Bond")
            }
            guard let service = SCNetworkServiceCreate(preferences, bond),
                  SCNetworkServiceEstablishDefaultConfiguration(service),
                  SCNetworkServiceSetName(
                    service,
                    ThruRNDISDummyEthernet.networkServiceName as CFString
                  ),
                  let serviceID = SCNetworkServiceGetServiceID(service)
                    as String? else {
                throw lastError("create the Dummy Ethernet Network Service")
            }

            try configureProtocols(for: service, configuration: configuration)
            guard SCNetworkServiceSetEnabled(service, false),
                  let networkSet = SCNetworkSetCopyCurrent(preferences),
                  SCNetworkSetAddService(networkSet, service) else {
                throw lastError("add the disabled Network Service")
            }
            try moveServiceLast(service, in: networkSet)
            try setMetadata(
                bondInterfaceName: bondName,
                networkServiceID: serviceID,
                memberInterfaceName: configuration.memberInterfaceName,
                peerInterfaceName: configuration.peerInterfaceName,
                in: preferences
            )
            try commitAndApply(preferences)
            return bondName
        }
    }

    func enableNetworkService() throws {
        try withLockedPreferences { preferences in
            guard let service = try managedObjects(in: preferences).service else {
                throw DummyEthernetSystemConfigurationError.unavailable(
                    "The Dummy Ethernet Network Service is missing."
                )
            }
            guard SCNetworkServiceSetEnabled(service, true) else {
                throw lastError("enable the Dummy Ethernet Network Service")
            }
            try commitAndApply(preferences)
        }
    }

    func removeConfiguration() throws {
        try withLockedPreferences { preferences in
            let objects = try managedObjects(in: preferences)
            var changed = false
            if let service = objects.service {
                guard SCNetworkServiceRemove(service) else {
                    throw lastError("remove the Dummy Ethernet Network Service")
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
                    ThruRNDISDummyEthernet.systemConfigurationMetadataKey
                        as CFString
                ) else {
                    throw lastError("remove the feth interface metadata")
                }
                changed = true
            }
            if changed {
                try commitAndApply(preferences)
            }
        }
    }

    private func managedObjects(
        in preferences: SCPreferences
    ) throws -> ManagedObjects {
        guard let metadata = try metadata(in: preferences) else {
            return ManagedObjects(bond: nil, service: nil, metadata: nil)
        }
        let bond = ((SCBondInterfaceCopyAll(preferences)
            as? [SCBondInterface]) ?? []).first {
                interfaceName(of: $0) == metadata.bondInterfaceName
            }
        let service = SCNetworkServiceCopy(
            preferences,
            metadata.networkServiceID as CFString
        )
        if let service,
           serviceInterfaceName(of: service)
            != metadata.bondInterfaceName {
            throw DummyEthernetSystemConfigurationError.conflict(
                "The recorded Network Service is not attached to its Bond."
            )
        }

        return ManagedObjects(
            bond: bond,
            service: service,
            metadata: metadata
        )
    }

    private func configureProtocols(
        for service: SCNetworkService,
        configuration: DummyEthernetConfiguration
    ) throws {
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
                [configuration.hostIPv4Address],
            kSCPropNetIPv4SubnetMasks as String:
                [ThruRNDISDummyEthernet.subnetMask],
            kSCPropNetIPv4Router as String:
                configuration.routerIPv4Address
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
        if let dns = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeDNS
        ), (!SCNetworkProtocolSetConfiguration(dns, nil)
            || !SCNetworkProtocolSetEnabled(dns, false)) {
            throw lastError("disable the DNS service protocol")
        }
    }

    private func snapshot(
        from objects: ManagedObjects
    ) -> DummyEthernetSystemConfigurationSnapshot {
        return DummyEthernetSystemConfigurationSnapshot(
            bondInterfaceName: objects.metadata?.bondInterfaceName,
            memberInterfaceName: objects.metadata?.memberInterfaceName,
            peerInterfaceName: objects.metadata?.peerInterfaceName,
            hasConfiguration: objects.metadata != nil,
            hasBond: objects.bond != nil,
            hasNetworkService: objects.service != nil,
            isNetworkServiceEnabled: objects.service.map(
                SCNetworkServiceGetEnabled
            ) ?? false,
            configuredIPv4Address: objects.service.flatMap(
                configuredIPv4Address
            )
        )
    }

    private func moveServiceLast(
        _ service: SCNetworkService,
        in networkSet: SCNetworkSet
    ) throws {
        guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
            throw DummyEthernetSystemConfigurationError.unavailable(
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
            ThruRNDISDummyEthernet.systemConfigurationMetadataKey as CFString
        ) else {
            return nil
        }
        guard let values = value as? [String: String],
              let bondInterfaceName = values[MetadataKey.bondInterfaceName],
              let networkServiceID = values[MetadataKey.networkServiceID],
              let memberInterfaceName = values[MetadataKey.memberInterfaceName],
              let peerInterfaceName = values[MetadataKey.peerInterfaceName]
        else {
            throw DummyEthernetSystemConfigurationError.conflict(
                "The stored Dummy Ethernet ownership metadata is malformed."
            )
        }
        guard isCanonicalBondInterfaceName(bondInterfaceName),
              !networkServiceID.isEmpty else {
            throw DummyEthernetSystemConfigurationError.conflict(
                "The stored Bond or Network Service identifier is invalid."
            )
        }
        guard let names = try? DummyEthernetConfigurationValidator
            .validatedInterfaceNames(
                memberInterfaceName: memberInterfaceName,
                peerInterfaceName: peerInterfaceName
            ), names.member == memberInterfaceName,
              names.peer == peerInterfaceName else {
            throw DummyEthernetSystemConfigurationError.conflict(
                "The stored feth interface names are invalid."
            )
        }
        return OwnershipMetadata(
            bondInterfaceName: bondInterfaceName,
            networkServiceID: networkServiceID,
            memberInterfaceName: memberInterfaceName,
            peerInterfaceName: peerInterfaceName
        )
    }

    private func setMetadata(
        bondInterfaceName: String,
        networkServiceID: String,
        memberInterfaceName: String,
        peerInterfaceName: String,
        in preferences: SCPreferences
    ) throws {
        let metadata = [
            MetadataKey.bondInterfaceName: bondInterfaceName,
            MetadataKey.networkServiceID: networkServiceID,
            MetadataKey.memberInterfaceName: memberInterfaceName,
            MetadataKey.peerInterfaceName: peerInterfaceName,
        ]
        guard SCPreferencesSetValue(
            preferences,
            ThruRNDISDummyEthernet.systemConfigurationMetadataKey as CFString,
            metadata as CFDictionary
        ) else {
            throw lastError("store the feth interface metadata")
        }
    }

    private func configuredIPv4Address(
        for service: SCNetworkService
    ) -> String? {
        guard let ipv4 = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeIPv4
        ), let configuration = SCNetworkProtocolGetConfiguration(ipv4)
            as? [String: Any],
            let addresses = configuration[kSCPropNetIPv4Addresses as String]
                as? [String] else {
            return nil
        }
        return addresses.first
    }

    private func interfaceName(
        of interface: SCNetworkInterface
    ) -> String? {
        SCNetworkInterfaceGetBSDName(interface) as String?
    }

    private func serviceInterfaceName(
        of service: SCNetworkService
    ) -> String? {
        SCNetworkServiceGetInterface(service).flatMap(interfaceName)
    }

    private func isCanonicalBondInterfaceName(_ name: String) -> Bool {
        guard name.utf8.count
                <= ThruRNDISDummyEthernet.maximumInterfaceNameUTF8ByteCount,
              name.hasPrefix("bond") else {
            return false
        }
        let unit = name.dropFirst("bond".count)
        return !unit.isEmpty
            && unit.utf8.allSatisfy { (48 ... 57).contains($0) }
            && UInt(unit).map { String($0) == unit } == true
    }

    private func withLockedPreferences<Result>(
        operation: (SCPreferences) throws -> Result
    ) throws -> Result {
        guard let preferences = SCPreferencesCreate(
            nil,
            "ThruRNDISPrivilegedHelper" as CFString,
            nil
        ) else {
            throw DummyEthernetSystemConfigurationError.unavailable(
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
    ) -> DummyEthernetSystemConfigurationError {
        .operationFailed(
            "\(operation): \(String(cString: SCErrorString(SCError())))"
        )
    }

    private struct OwnershipMetadata {
        let bondInterfaceName: String
        let networkServiceID: String
        let memberInterfaceName: String
        let peerInterfaceName: String
    }

    private enum MetadataKey {
        static let bondInterfaceName = "BondInterfaceName"
        static let networkServiceID = "NetworkServiceID"
        static let memberInterfaceName = "MemberInterfaceName"
        static let peerInterfaceName = "PeerInterfaceName"
    }

    private struct ManagedObjects {
        let bond: SCBondInterface?
        let service: SCNetworkService?
        let metadata: OwnershipMetadata?
    }
}
