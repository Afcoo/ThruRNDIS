/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation

enum NetworkRouteControllerError: LocalizedError {
    case configurationConflict(String)
    case couldNotRemoveConfiguration([String])
    case routeLeaseOwnedByAnotherConnection
    case routeVerificationFailed([String])

    var errorDescription: String? {
        switch self {
        case .configurationConflict(let detail):
            "The Network Helper did not modify an ambiguous configuration: \(detail)"
        case .couldNotRemoveConfiguration(let failures):
            "Could not remove the managed network configuration: \(failures.joined(separator: "; "))"
        case .routeLeaseOwnedByAnotherConnection:
            "The managed network is leased by another live app connection."
        case .routeVerificationFailed(let failures):
            "The managed IPv4 routes did not match the expected configuration after installation: \(failures.joined(separator: "; "))"
        }
    }
}

/// Serializes the VM bridge -> feth pair -> Bond -> Network Service -> route
/// lifecycle. The VM-created bridge is only inspected and given the exact
/// recorded feth peer; it is never created, addressed, or destroyed here.
final class NetworkRouteController: @unchecked Sendable {
    typealias Completion = @Sendable (Result<NetworkRouteSnapshot, Error>) -> Void

    private let queue = DispatchQueue(label: "ThruRNDIS.NetworkRouteController")
    private let resolver = VZNATInterfaceResolver()
    private let interfaceRunner = NetworkInterfaceCommandRunner()
    private let routeRunner = RouteCommandRunner()
    private let systemConfiguration = NetworkRouteSystemConfigurationService()
    private var ownedConfiguration: OwnedConfiguration?
    private var leaseOwnerIdentifier: UUID?

    func status(completion: @escaping Completion) {
        queue.async { [self] in
            completion(Result { try currentSnapshot() })
        }
    }

    func start(
        guestIPv4Address: String,
        vznatGatewayIPv4Address: String,
        leaseOwnerIdentifier: UUID,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            completion(Result {
                try startNow(
                    guestIPv4Address: guestIPv4Address,
                    vznatGatewayIPv4Address: vznatGatewayIPv4Address,
                    leaseOwnerIdentifier: leaseOwnerIdentifier
                )
            })
        }
    }

    func stop(
        leaseOwnerIdentifier: UUID?,
        releaseLeaseAfterAttempt: Bool,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            let result = Result {
                try stopNow(leaseOwnerIdentifier: leaseOwnerIdentifier)
            }
            if releaseLeaseAfterAttempt,
               let leaseOwnerIdentifier,
               self.leaseOwnerIdentifier == leaseOwnerIdentifier {
                self.leaseOwnerIdentifier = nil
            }
            completion(result)
        }
    }

    private func startNow(
        guestIPv4Address: String,
        vznatGatewayIPv4Address: String,
        leaseOwnerIdentifier: UUID
    ) throws -> NetworkRouteSnapshot {
        if let currentLeaseOwnerIdentifier = self.leaseOwnerIdentifier,
           currentLeaseOwnerIdentifier != leaseOwnerIdentifier {
            throw NetworkRouteControllerError.routeLeaseOwnedByAnotherConnection
        }

        let bridgeInterfaceName = try resolver.resolve(
            guestIPv4Address: guestIPv4Address,
            vznatGatewayIPv4Address: vznatGatewayIPv4Address
        )
        let requested = NetworkRouteConfiguration(
            guestIPv4Address: guestIPv4Address,
            vznatGatewayIPv4Address: vznatGatewayIPv4Address,
            bridgeInterfaceName: bridgeInterfaceName
        )

        let existingSystemConfiguration = try systemConfiguration.inspect()
        if existingSystemConfiguration.configuration != nil {
            guard let existing = ownedConfiguration(
                from: existingSystemConfiguration
            ) else {
                throw NetworkRouteControllerError.configurationConflict(
                    "The ownership record is incomplete."
                )
            }
            let current = try snapshot(
                for: existing,
                systemConfiguration: existingSystemConfiguration
            ).snapshot
            if existing.network == requested, current.state == .active {
                ownedConfiguration = existing
                self.leaseOwnerIdentifier = leaseOwnerIdentifier
                return current
            }
            try removeManagedConfiguration(existing)
            ownedConfiguration = nil
            self.leaseOwnerIdentifier = nil
        }
        try rejectExistingRoutesWithoutOwnershipMetadata()

        for name in [
            ThruRNDISNetworkRoute.memberInterfaceName,
            ThruRNDISNetworkRoute.peerInterfaceName,
        ] where interfaceExists(name) {
            throw NetworkRouteControllerError.configurationConflict(
                "\(name) already exists without a ThruRNDIS ownership record."
            )
        }

        try createFethPair()
        var bondInterfaceName: String?
        do {
            let bondName = try systemConfiguration
                .createDisabledConfiguration(requested)
            bondInterfaceName = bondName
            try waitForInterface(bondName, timeout: 3)
            try interfaceRunner.run([bondName, "bondmode", "static"])
            try interfaceRunner.run([
                bondName,
                "bonddev",
                ThruRNDISNetworkRoute.memberInterfaceName,
            ])

            // Resolve again immediately before mutating membership. A VM
            // restart can replace bridgeN while SCPreferences is being applied.
            let currentBridge = try resolver.resolve(
                guestIPv4Address: requested.guestIPv4Address,
                vznatGatewayIPv4Address: requested.vznatGatewayIPv4Address
            )
            guard currentBridge == requested.bridgeInterfaceName else {
                throw NetworkRouteControllerError.configurationConflict(
                    "The VM-created bridge changed during network setup."
                )
            }
            try interfaceRunner.run([
                requested.bridgeInterfaceName,
                "addm",
                ThruRNDISNetworkRoute.peerInterfaceName,
            ])
            guard try interfaceRunner.bridgeMembers(
                interfaceName: requested.bridgeInterfaceName
            ).contains(ThruRNDISNetworkRoute.peerInterfaceName) else {
                throw NetworkRouteControllerError.configurationConflict(
                    "The managed feth peer did not become a member of \(requested.bridgeInterfaceName)."
                )
            }

            try systemConfiguration.enableNetworkService()
            let owned = OwnedConfiguration(
                network: requested,
                bondInterfaceName: bondName
            )
            try waitForIPv4Address(
                ThruRNDISNetworkRoute.hostIPv4Address,
                on: bondName,
                timeout: 3
            )
            try installRoutes(for: routeAnchor(for: owned))

            let evaluation = try snapshot(
                for: owned,
                systemConfiguration: try systemConfiguration.inspect()
            )
            guard evaluation.snapshot.state == .active else {
                let detail = evaluation.failures.isEmpty
                    ? "no failed readiness check was recorded"
                    : evaluation.failures.joined(separator: ", ")
                throw NetworkRouteControllerError.configurationConflict(
                    "The managed bridge, Bond, service, and routes did not reach their active state: \(detail)."
                )
            }
            ownedConfiguration = owned
            self.leaseOwnerIdentifier = leaseOwnerIdentifier
            return evaluation.snapshot
        } catch {
            let cleanupFailure = rollbackFailedStart(
                configuration: requested,
                bondInterfaceName: bondInterfaceName
            )
            guard let cleanupFailure else { throw error }
            throw NetworkRouteControllerError.couldNotRemoveConfiguration([
                "network setup failed: \(error.localizedDescription)",
                "rollback failed: \(cleanupFailure)",
            ])
        }
    }

    private func stopNow(
        leaseOwnerIdentifier requestedLeaseOwnerIdentifier: UUID?
    ) throws -> NetworkRouteSnapshot {
        if ownedConfiguration == nil {
            ownedConfiguration = try ownedConfiguration(
                from: systemConfiguration.inspect()
            )
        }
        if let leaseOwnerIdentifier {
            guard requestedLeaseOwnerIdentifier == leaseOwnerIdentifier else {
                throw NetworkRouteControllerError.routeLeaseOwnedByAnotherConnection
            }
        }

        if let ownedConfiguration {
            try removeManagedConfiguration(ownedConfiguration)
        }

        ownedConfiguration = nil
        leaseOwnerIdentifier = nil
        return .inactive
    }

    private func currentSnapshot() throws -> NetworkRouteSnapshot {
        let systemSnapshot = try systemConfiguration.inspect()
        if ownedConfiguration == nil {
            ownedConfiguration = ownedConfiguration(from: systemSnapshot)
        }
        if let ownedConfiguration {
            return try snapshot(
                for: ownedConfiguration,
                systemConfiguration: systemSnapshot
            ).snapshot
        }
        return .inactive
    }

    private func snapshot(
        for owned: OwnedConfiguration,
        systemConfiguration systemSnapshot:
            NetworkRouteSystemConfigurationSnapshot
    ) throws -> (snapshot: NetworkRouteSnapshot, failures: [String]) {
        let routes = try inspectRoutes(for: routeAnchor(for: owned))
        let network = owned.network
        let member = ThruRNDISNetworkRoute.memberInterfaceName
        let peer = ThruRNDISNetworkRoute.peerInterfaceName
        let missingInterfaces = [
            owned.bondInterfaceName,
            member,
            peer,
            network.bridgeInterfaceName,
        ].filter { !interfaceExists($0) }
        let runtimeInterfacesReady = missingInterfaces.isEmpty
        let bridgeIdentityReady = (try? resolver.resolve(
            guestIPv4Address: network.guestIPv4Address,
            vznatGatewayIPv4Address: network.vznatGatewayIPv4Address
        )) == network.bridgeInterfaceName
        let bridgeMembers = try? interfaceRunner.bridgeMembers(
            interfaceName: network.bridgeInterfaceName
        )
        let bridgeMembershipReady = runtimeInterfacesReady
            && bridgeIdentityReady
            && bridgeMembers?.contains(peer) == true
        let bondRuntime = try? interfaceRunner.bondRuntime(
            interfaceName: owned.bondInterfaceName
        )
        let bondRuntimeReady = bondRuntime?.mode == "static"
            && bondRuntime?.members == Set([member])
        let memberPeer = try? interfaceRunner.fethPeer(
            interfaceName: member
        )
        let peerPeer = try? interfaceRunner.fethPeer(
            interfaceName: peer
        )
        let fethPairReady = memberPeer == peer && peerPeer == member
        let systemConfigurationReady =
            systemSnapshot.configuration == network
            && systemSnapshot.bondInterfaceName == owned.bondInterfaceName
            && systemSnapshot.hasBond
            && systemSnapshot.hasNetworkService
            && systemSnapshot.isNetworkServiceEnabled
            && systemSnapshot.configuredHostIPv4Address
                == ThruRNDISNetworkRoute.hostIPv4Address
            && systemSnapshot.configuredRouterIPv4Address
                == ThruRNDISNetworkRoute.routerIPv4Address
            && systemSnapshot.configuredDNSServerAddresses
                == [ThruRNDISNetworkRoute.routerIPv4Address]
        let routesReady = routes.count == ManagedIPv4Route.all.count
            && routes.allSatisfy { $0.value == .owned }

        var readinessFailures: [String] = []
        if !runtimeInterfacesReady {
            readinessFailures.append(
                "missing runtime interfaces [\(missingInterfaces.joined(separator: ", "))]"
            )
        }
        if !bridgeIdentityReady {
            readinessFailures.append("VM bridge identity changed")
        }
        if !bridgeMembershipReady {
            let members = bridgeMembers?.sorted().joined(separator: ", ")
                ?? "unavailable"
            readinessFailures.append(
                "bridge members [\(members)] do not contain \(peer)"
            )
        }
        if !bondRuntimeReady {
            let mode = bondRuntime?.mode ?? "unavailable"
            let members = bondRuntime?.members.sorted().joined(separator: ", ")
                ?? "unavailable"
            readinessFailures.append(
                "Bond runtime mode=\(mode), members=[\(members)]"
            )
        }
        if !fethPairReady {
            readinessFailures.append(
                "feth peers \(member)->\(memberPeer ?? "unavailable"), \(peer)->\(peerPeer ?? "unavailable")"
            )
        }
        if !systemConfigurationReady {
            readinessFailures.append(
                "SystemConfiguration bond=\(systemSnapshot.hasBond), service=\(systemSnapshot.hasNetworkService), enabled=\(systemSnapshot.isNetworkServiceEnabled), host=\(systemSnapshot.configuredHostIPv4Address ?? "missing"), router=\(systemSnapshot.configuredRouterIPv4Address ?? "missing"), DNS=\(systemSnapshot.configuredDNSServerAddresses.joined(separator: ","))"
            )
        }
        if !routesReady {
            let states = ManagedIPv4Route.all.map { route in
                let state = routes[route]?.diagnosticName ?? "missing"
                return "\(route.diagnosticName(interfaceName: owned.bondInterfaceName))=\(state)"
            }
            readinessFailures.append(
                "routes [\(states.joined(separator: ", "))]"
            )
        }
        let snapshot = NetworkRouteSnapshot(
            state: systemConfigurationReady
                && runtimeInterfacesReady
                && bridgeIdentityReady
                && bridgeMembershipReady
                && bondRuntimeReady
                && fethPairReady
                && routesReady ? .active : .degraded,
            guestIPv4Address: network.guestIPv4Address,
            vznatGatewayIPv4Address: network.vznatGatewayIPv4Address,
            bridgeInterfaceName: network.bridgeInterfaceName,
            bondInterfaceName: owned.bondInterfaceName,
            installedPrefixes: installedPrefixes(from: routes)
        )
        return (snapshot, readinessFailures)
    }

    private func createFethPair() throws {
        let member = ThruRNDISNetworkRoute.memberInterfaceName
        let peer = ThruRNDISNetworkRoute.peerInterfaceName
        try interfaceRunner.run([member, "create"])
        do {
            try interfaceRunner.run([peer, "create"])
        } catch {
            try? interfaceRunner.run([member, "destroy"])
            throw error
        }
        do {
            try interfaceRunner.run([member, "peer", peer])
            try interfaceRunner.run([member, "up"])
            // The peer is an unaddressed layer-2 port. The guest owns the
            // 192.168.100.1 router address on eth0.
            try interfaceRunner.run([peer, "up"])
        } catch {
            try? removeFethPair(member: member, peer: peer)
            throw error
        }
    }

    private func rollbackFailedStart(
        configuration: NetworkRouteConfiguration,
        bondInterfaceName: String?
    ) -> String? {
        if let bondInterfaceName {
            do {
                try removeManagedConfiguration(
                    OwnedConfiguration(
                        network: configuration,
                        bondInterfaceName: bondInterfaceName
                    ),
                    failOnRouteConflict: false
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        do {
            let committed = try systemConfiguration.inspect()
            if committed.configuration != nil {
                guard let recovered = ownedConfiguration(from: committed),
                      recovered.network == configuration else {
                    return "A committed SystemConfiguration ownership record did not exactly match the failed start request and was retained."
                }
                do {
                    try removeManagedConfiguration(
                        recovered,
                        failOnRouteConflict: false
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        } catch {
            return "Could not inspect SystemConfiguration after the failed start: \(error.localizedDescription)"
        }

        var failures: [String] = []
        do {
            try detachPeerFromBridgeIfPresent(configuration)
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try removeFethPair(
                member: ThruRNDISNetworkRoute.memberInterfaceName,
                peer: ThruRNDISNetworkRoute.peerInterfaceName
            )
        } catch {
            failures.append(error.localizedDescription)
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func removeManagedConfiguration(
        _ owned: OwnedConfiguration,
        failOnRouteConflict: Bool = true
    ) throws {
        // Routes are removed first so no new host traffic can enter a topology
        // while its bridge and Bond are being dismantled.
        try removeRoutes(
            for: routeAnchor(for: owned),
            failOnConflict: failOnRouteConflict
        )
        try? systemConfiguration.disableNetworkService()
        try detachPeerFromBridgeIfPresent(owned.network)

        let member = ThruRNDISNetworkRoute.memberInterfaceName
        let peer = ThruRNDISNetworkRoute.peerInterfaceName
        try? systemConfiguration.withOwnedBondInterface { bondInterfaceName in
            guard interfaceExists(bondInterfaceName),
                  interfaceExists(member) else {
                return
            }
            try interfaceRunner.run([
                bondInterfaceName,
                "-bonddev",
                member,
            ])
        }
        do {
            try removeFethPair(member: member, peer: peer)
        } catch {
            throw NetworkRouteControllerError.couldNotRemoveConfiguration([
                "The owned feth pair could not be removed; its SystemConfiguration ownership record was retained: \(error.localizedDescription)",
            ])
        }
        do {
            try systemConfiguration.removeConfiguration()
        } catch {
            throw NetworkRouteControllerError.couldNotRemoveConfiguration([
                error.localizedDescription,
            ])
        }
    }

    private func detachPeerFromBridgeIfPresent(
        _ configuration: NetworkRouteConfiguration
    ) throws {
        let peer = ThruRNDISNetworkRoute.peerInterfaceName
        guard interfaceExists(configuration.bridgeInterfaceName),
              interfaceExists(peer) else {
            // Virtualization may already have destroyed bridgeN after an
            // unexpected VM stop. In that case kernel membership is gone.
            return
        }
        let members = try interfaceRunner.bridgeMembers(
            interfaceName: configuration.bridgeInterfaceName
        )
        guard members.contains(peer) else { return }
        try interfaceRunner.run([
            configuration.bridgeInterfaceName,
            "deletem",
            peer,
        ])
    }

    private func removeFethPair(
        member: String,
        peer: String
    ) throws {
        if interfaceExists(member) {
            try? interfaceRunner.run([member, "-peer"])
        }
        var failures: [String] = []
        for name in [peer, member] where interfaceExists(name) {
            try? interfaceRunner.run([name, "down"])
            do {
                try interfaceRunner.run([name, "destroy"])
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        guard failures.isEmpty else {
            throw NetworkRouteControllerError.couldNotRemoveConfiguration(failures)
        }
    }

    private func installRoutes(for anchor: RouteAnchor) throws {
        let inspections = try inspectRoutes(for: anchor)
        if inspections.contains(where: { $0.value == .conflicting }) {
            let route = inspections.first { $0.value == .conflicting }!.key
            throw RouteCommandRunnerError.conflictingRoute(
                route.diagnosticName(interfaceName: anchor.interfaceName)
            )
        }
        for route in ManagedIPv4Route.removalOrder
        where inspections[route] == .owned {
            try routeRunner.delete(
                route,
                gateway: anchor.gateway,
                interfaceName: anchor.interfaceName
            )
        }

        var added: [ManagedIPv4Route] = []
        do {
            for route in ManagedIPv4Route.installationOrder {
                try routeRunner.add(
                    route,
                    gateway: anchor.gateway,
                    interfaceName: anchor.interfaceName
                )
                added.append(route)
            }
            let installed = try inspectRoutes(for: anchor)
            guard installed.allSatisfy({ $0.value == .owned }) else {
                let failures = ManagedIPv4Route.installationOrder.compactMap {
                    route -> String? in
                    guard installed[route] != .owned else { return nil }
                    return route.diagnosticName(
                        interfaceName: anchor.interfaceName
                    )
                }
                throw NetworkRouteControllerError.routeVerificationFailed(failures)
            }
        } catch {
            for route in added.reversed() {
                try? routeRunner.delete(
                    route,
                    gateway: anchor.gateway,
                    interfaceName: anchor.interfaceName
                )
            }
            throw error
        }
    }

    private func removeRoutes(
        for anchor: RouteAnchor,
        failOnConflict: Bool = true
    ) throws {
        var failures: [String] = []
        for route in ManagedIPv4Route.removalOrder {
            do {
                switch try routeRunner.inspection(
                    of: route,
                    gateway: anchor.gateway,
                    interfaceName: anchor.interfaceName
                ) {
                case .absent:
                    continue
                case .owned:
                    try routeRunner.delete(
                        route,
                        gateway: anchor.gateway,
                        interfaceName: anchor.interfaceName
                    )
                case .conflicting:
                    if failOnConflict {
                        failures.append(
                            route.diagnosticName(
                                interfaceName: anchor.interfaceName
                            ) + " no longer has the ThruRNDIS ownership signature"
                        )
                    }
                }
            } catch {
                failures.append(
                    "\(route.diagnosticName(interfaceName: anchor.interfaceName)): \(error.localizedDescription)"
                )
            }
        }
        guard failures.isEmpty else {
            throw NetworkRouteControllerError.couldNotRemoveConfiguration(failures)
        }
    }

    private func rejectExistingRoutesWithoutOwnershipMetadata() throws {
        for route in ManagedIPv4Route.global {
            let records = try routeRunner.records(matching: route)
            guard !records.isEmpty else {
                continue
            }
            throw RouteCommandRunnerError.conflictingRoute(
                "\(route.prefix) without SystemConfiguration ownership metadata"
            )
        }
    }

    private func inspectRoutes(
        for anchor: RouteAnchor
    ) throws -> [ManagedIPv4Route: ManagedRouteInspection] {
        var result: [ManagedIPv4Route: ManagedRouteInspection] = [:]
        for route in ManagedIPv4Route.all {
            result[route] = try routeRunner.inspection(
                of: route,
                gateway: anchor.gateway,
                interfaceName: anchor.interfaceName
            )
        }
        for route in ManagedIPv4Route.all
        where route.scope == .interfaceScoped {
            let hasUnexpectedScope = try routeRunner
                .records(matching: route)
                .contains {
                    $0.isInterfaceScoped
                        && $0.interfaceName != anchor.interfaceName
                }
            if hasUnexpectedScope {
                result[route] = .conflicting
            }
        }
        return result
    }

    private func installedPrefixes(
        from inspections: [ManagedIPv4Route: ManagedRouteInspection]
    ) -> [String] {
        ManagedIPv4Route.prefixes.filter { prefix in
            ManagedIPv4Route.entries(for: prefix).allSatisfy { route in
                inspections[route] == .owned
            }
        }
    }

    private func ownedConfiguration(
        from snapshot: NetworkRouteSystemConfigurationSnapshot
    ) -> OwnedConfiguration? {
        guard let network = snapshot.configuration,
              let bondInterfaceName = snapshot.bondInterfaceName else {
            return nil
        }
        return OwnedConfiguration(
            network: network,
            bondInterfaceName: bondInterfaceName
        )
    }

    private func routeAnchor(for owned: OwnedConfiguration) -> RouteAnchor {
        RouteAnchor(
            gateway: ThruRNDISNetworkRoute.routerIPv4Address,
            interfaceName: owned.bondInterfaceName
        )
    }

    private func waitForInterface(
        _ name: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if interfaceExists(name) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NetworkRouteControllerError.configurationConflict(
            "\(name) did not appear after applying SystemConfiguration."
        )
    }

    private func waitForIPv4Address(
        _ address: String,
        on interfaceName: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if interfaceHasIPv4Address(interfaceName, address: address) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NetworkRouteControllerError.configurationConflict(
            "\(interfaceName) did not acquire \(address) after enabling its Network Service."
        )
    }

    private func interfaceHasIPv4Address(
        _ interfaceName: String,
        address: String
    ) -> Bool {
        var expected = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &expected) }) == 1
        else {
            return false
        }

        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0 else { return false }
        defer { freeifaddrs(interfaceList) }
        var cursor = interfaceList
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard String(cString: entry.ifa_name) == interfaceName,
                  let addressPointer = entry.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let currentAddress = UnsafeRawPointer(addressPointer)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee.sin_addr
            if currentAddress.s_addr == expected.s_addr {
                return true
            }
        }
        return false
    }

    private func interfaceExists(_ name: String) -> Bool {
        name.withCString { if_nametoindex($0) != 0 }
    }

    private struct OwnedConfiguration {
        let network: NetworkRouteConfiguration
        let bondInterfaceName: String
    }

    private struct RouteAnchor {
        let gateway: String
        let interfaceName: String
    }
}
