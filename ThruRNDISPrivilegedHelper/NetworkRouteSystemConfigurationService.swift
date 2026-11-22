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
    let hasExpectedProtocolConfiguration: Bool
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
    private let preferencesTransaction =
        SystemConfigurationPreferencesTransaction()

    func inspect() throws -> NetworkRouteSystemConfigurationSnapshot {
        try preferencesTransaction.withLockedPreferences { preferences in
            let objects = try managedObjects(in: preferences)
            return snapshot(from: objects)
        }
    }

    func createDisabledConfiguration(
        _ configuration: NetworkRouteConfiguration
    ) throws -> String {
        try preferencesTransaction.withLockedPreferences { preferences in
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
                throw preferencesTransaction.error("create the Ethernet Bond")
            }
            guard let service = SCNetworkServiceCreate(preferences, bond),
                  SCNetworkServiceEstablishDefaultConfiguration(service),
                  SCNetworkServiceSetName(
                    service,
                    ThruRNDISNetworkRoute.networkServiceName as CFString
                  ),
                  let serviceID = SCNetworkServiceGetServiceID(service)
                    as String? else {
                throw preferencesTransaction.error(
                    "create the ThruRNDIS Network Service"
                )
            }

            var bondOptions = (SCBondInterfaceGetOptions(bond)
                as? [String: Any]) ?? [:]
            bondOptions[BondOptionKey.ownershipToken] = serviceID
            guard SCBondInterfaceSetOptions(
                bond,
                bondOptions as CFDictionary
            ) else {
                throw preferencesTransaction.error(
                    "mark the Ethernet Bond as owned"
                )
            }

            try configureProtocols(for: service, policy: configuration.policy)
            guard SCNetworkServiceSetEnabled(service, false),
                  let networkSet = SCNetworkSetCopyCurrent(preferences),
                  SCNetworkSetAddService(networkSet, service) else {
                throw preferencesTransaction.error(
                    "add the disabled Network Service"
                )
            }
            try setMetadata(
                bondInterfaceName: bondName,
                networkServiceID: serviceID,
                configuration: configuration,
                in: preferences
            )
            try preferencesTransaction.commitAndApply(preferences)
            return bondName
        }
    }

    func activateNetworkService() throws {
        let initial = try inspect()
        guard initial.hasNetworkService,
              !initial.isNetworkServiceEnabled,
              initial.hasExpectedProtocolConfiguration else {
            throw NetworkRouteSystemConfigurationError.conflict(
                "The owned Network Service does not have the expected disabled IPv4 and DNS configuration."
            )
        }

        do {
            try setNetworkServiceEnabled(true)
            let activated = try inspect()
            guard activated.isNetworkServiceEnabled,
                  activated.hasExpectedProtocolConfiguration else {
                throw NetworkRouteSystemConfigurationError.operationFailed(
                    "The Network Service did not retain its IPv4 and DNS configuration."
                )
            }
        } catch {
            var rollbackFailure: Error?
            do {
                try setNetworkServiceEnabled(false)
            } catch {
                rollbackFailure = error
            }
            guard let rollbackFailure else { throw error }
            throw NetworkRouteSystemConfigurationError.operationFailed(
                "Network Service activation failed: \(error.localizedDescription); "
                    + "SystemConfiguration rollback failed: "
                    + rollbackFailure.localizedDescription
            )
        }
    }

    func deactivateNetworkService() throws {
        let initial = try inspect()
        if initial.hasNetworkService {
            try setNetworkServiceEnabled(false)
        }
        let disabled = try inspect()
        guard !disabled.isNetworkServiceEnabled else {
            throw NetworkRouteSystemConfigurationError.operationFailed(
                "The Network Service remained enabled."
            )
        }
    }

    func withOwnedBondInterface(
        _ operation: (String) throws -> Void
    ) throws {
        try preferencesTransaction.withLockedPreferences { preferences in
            guard let bond = try managedObjects(in: preferences).bond,
                  let bondInterfaceName = interfaceName(of: bond) else {
                return
            }
            try operation(bondInterfaceName)
        }
    }

    func removeConfiguration() throws {
        try preferencesTransaction.withLockedPreferences { preferences in
            let objects = try managedObjects(in: preferences)
            if let service = objects.service,
               SCNetworkServiceGetEnabled(service) {
                throw NetworkRouteSystemConfigurationError.conflict(
                    "The owned Network Service is still enabled."
                )
            }
            var changed = false
            if let service = objects.service {
                guard SCNetworkServiceRemove(service) else {
                    throw preferencesTransaction.error(
                        "remove the ThruRNDIS Network Service"
                    )
                }
                changed = true
            }
            if let bond = objects.bond {
                guard SCBondInterfaceRemove(bond) else {
                    throw preferencesTransaction.error(
                        "remove the Ethernet Bond"
                    )
                }
                changed = true
            }
            if objects.metadata != nil {
                guard SCPreferencesRemoveValue(
                    preferences,
                    ThruRNDISNetworkRoute.systemConfigurationMetadataKey
                        as CFString
                ) else {
                    throw preferencesTransaction.error(
                        "remove the network ownership metadata"
                    )
                }
                changed = true
            }
            if changed {
                try preferencesTransaction.commitAndApply(preferences)
            }
        }
    }

    private func setNetworkServiceEnabled(_ enabled: Bool) throws {
        try preferencesTransaction.withLockedPreferences { preferences in
            let objects = try managedObjects(in: preferences)
            guard let service = objects.service else {
                throw NetworkRouteSystemConfigurationError.unavailable(
                    "The ThruRNDIS Network Service is missing."
                )
            }
            if enabled, !hasExpectedProtocolConfiguration(in: objects) {
                throw NetworkRouteSystemConfigurationError.conflict(
                    "The owned Network Service configuration changed before activation."
                )
            }
            guard SCNetworkServiceSetEnabled(service, enabled) else {
                throw preferencesTransaction.error(
                    enabled ? "enable the Network Service" : "disable the Network Service"
                )
            }
            try preferencesTransaction.commitAndApply(preferences)
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

    private func ipv4Configuration(for policy: NetworkRoutePolicy) -> [String: Any] {
        var configuration: [String: Any] = [
            kSCPropNetIPv4ConfigMethod as String:
                kSCValNetIPv4ConfigMethodManual,
            kSCPropNetIPv4Addresses as String:
                [ThruRNDISNetworkRoute.hostIPv4Address],
            kSCPropNetIPv4SubnetMasks as String:
                [ThruRNDISNetworkRoute.subnetMask],
        ]
        let gateway = ThruRNDISNetworkRoute.routerIPv4Address
        switch policy {
        case .defaultRoute:
            configuration[kSCPropNetIPv4Router as String] = gateway
        case .selectedSubnets(let subnets):
            // IPMonitor associates these service routes with the Bond's ifindex.
            // The AdditionalRoutes schema is absent from the public SDK.
            configuration["AdditionalRoutes"] = subnets.map {
                [
                    "DestinationAddress": $0.network.description,
                    "SubnetMask": $0.subnetMask.description,
                    "GatewayAddress": gateway,
                ]
            }
        }
        return configuration
    }

    private func configureProtocols(for service: SCNetworkService, policy: NetworkRoutePolicy) throws {
        guard let ipv4 = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeIPv4
        ) else {
            throw preferencesTransaction.error("resolve the IPv4 service protocol")
        }
        guard SCNetworkProtocolSetConfiguration(
            ipv4,
            ipv4Configuration(for: policy) as CFDictionary
        ), SCNetworkProtocolSetEnabled(ipv4, true) else {
            throw preferencesTransaction.error("configure the IPv4 service protocol")
        }

        if let ipv6 = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeIPv6
        ), !SCNetworkProtocolSetEnabled(ipv6, false) {
            throw preferencesTransaction.error("disable the IPv6 service protocol")
        }

        if SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeDNS
        ) == nil,
           !SCNetworkServiceAddProtocolType(
            service,
            kSCNetworkProtocolTypeDNS
           ) {
            throw preferencesTransaction.error("add the DNS service protocol")
        }
        guard let dns = SCNetworkServiceCopyProtocol(
            service,
            kSCNetworkProtocolTypeDNS
        ) else {
            throw preferencesTransaction.error("resolve the DNS service protocol")
        }
        let providesDNS = policy == .defaultRoute
        let dnsConfiguration: [String: [String]] = providesDNS
            ? [kSCPropNetDNSServerAddresses as String: [ThruRNDISNetworkRoute.routerIPv4Address]]
            : [:]
        guard SCNetworkProtocolSetConfiguration(
            dns,
            dnsConfiguration as CFDictionary
        ), SCNetworkProtocolSetEnabled(dns, providesDNS) else {
            throw preferencesTransaction.error("configure the DNS service protocol")
        }
    }

    private func snapshot(
        from objects: ManagedObjects
    ) -> NetworkRouteSystemConfigurationSnapshot {
        return NetworkRouteSystemConfigurationSnapshot(
            configuration: objects.metadata?.configuration,
            bondInterfaceName: objects.metadata?.bondInterfaceName,
            hasBond: objects.bond != nil,
            hasNetworkService: objects.service != nil,
            isNetworkServiceEnabled: objects.service.map(
                SCNetworkServiceGetEnabled
            ) ?? false,
            hasExpectedProtocolConfiguration: hasExpectedProtocolConfiguration(in: objects)
        )
    }

    private func hasExpectedProtocolConfiguration(in objects: ManagedObjects) -> Bool {
        guard let service = objects.service, let policy = objects.metadata?.configuration.policy,
              let ipv4 = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4),
              SCNetworkProtocolGetEnabled(ipv4),
              let settings = SCNetworkProtocolGetConfiguration(ipv4),
              CFEqual(settings, ipv4Configuration(for: policy) as CFDictionary) else {
            return false
        }
        // Preserve the default mode's existing IPv4 readiness check. Selected
        // subnets additionally require the service to keep its DNS disabled.
        if policy == .defaultRoute { return true }
        guard let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
            return false
        }
        return !SCNetworkProtocolGetEnabled(dns)
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
              IPv4Value(guestIPv4Address) != nil,
              IPv4Value(vznatGatewayIPv4Address) != nil,
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
                bridgeInterfaceName: bridgeInterfaceName,
                policy: try NetworkRoutePolicy(selectedSubnets: values[MetadataKey.selectedSubnets])
            )
        )
    }

    private func setMetadata(
        bondInterfaceName: String,
        networkServiceID: String,
        configuration: NetworkRouteConfiguration,
        in preferences: SCPreferences
    ) throws {
        var metadata = [
            MetadataKey.bondInterfaceName: bondInterfaceName,
            MetadataKey.networkServiceID: networkServiceID,
            MetadataKey.guestIPv4Address: configuration.guestIPv4Address,
            MetadataKey.vznatGatewayIPv4Address:
                configuration.vznatGatewayIPv4Address,
            MetadataKey.bridgeInterfaceName:
                configuration.bridgeInterfaceName,
        ]
        // Records created before subnet selection use the default route.
        metadata[MetadataKey.selectedSubnets] = configuration.policy.subnetSpecification
        guard SCPreferencesSetValue(
            preferences,
            ThruRNDISNetworkRoute.systemConfigurationMetadataKey as CFString,
            metadata as CFDictionary
        ) else {
            throw preferencesTransaction.error(
                "store the network ownership metadata"
            )
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
        static let selectedSubnets = "SelectedSubnets"
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

}
