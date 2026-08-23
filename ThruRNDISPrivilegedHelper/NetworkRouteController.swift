/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum NetworkRouteControllerError: LocalizedError {
    case couldNotRemoveRoutes([String])
    case routeLeaseOwnedByAnotherConnection
    case routeVerificationFailed([String])

    var errorDescription: String? {
        switch self {
        case .couldNotRemoveRoutes(let failures):
            "Could not remove all managed IPv4 routes: \(failures.joined(separator: "; "))"
        case .routeLeaseOwnedByAnotherConnection:
            "The managed IPv4 routes are leased by another live app connection."
        case .routeVerificationFailed(let failures):
            "The managed IPv4 routes did not match the expected configuration after installation: \(failures.joined(separator: "; "))"
        }
    }
}

final class NetworkRouteController: @unchecked Sendable {
    typealias Completion = @Sendable (Result<NetworkRouteSnapshot, Error>) -> Void

    private let queue = DispatchQueue(label: "ThruRNDIS.NetworkRouteController")
    private let resolver = VZNATInterfaceResolver()
    private let runner = RouteCommandRunner()
    private var ownedConfiguration: OwnedConfiguration?
    private var leaseOwnerIdentifier: UUID?

    func status(completion: @escaping Completion) {
        queue.async { [self] in
            completion(Result { try currentSnapshot() })
        }
    }

    func start(
        guestIPv4Address: String,
        leaseOwnerIdentifier: UUID,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            completion(Result {
                try startNow(
                    guestIPv4Address: guestIPv4Address,
                    leaseOwnerIdentifier: leaseOwnerIdentifier
                )
            })
        }
    }

    func stop(
        leaseOwnerIdentifier: UUID?,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            completion(Result {
                try stopNow(leaseOwnerIdentifier: leaseOwnerIdentifier)
            })
        }
    }

    private func startNow(
        guestIPv4Address: String,
        leaseOwnerIdentifier: UUID
    ) throws -> NetworkRouteSnapshot {
        if let currentLeaseOwnerIdentifier = self.leaseOwnerIdentifier,
           currentLeaseOwnerIdentifier != leaseOwnerIdentifier {
            throw NetworkRouteControllerError
                .routeLeaseOwnedByAnotherConnection
        }

        let interface = try resolver.resolve(
            guestIPv4Address: guestIPv4Address
        )
        let requested = OwnedConfiguration(
            guestIPv4Address: guestIPv4Address,
            hostIPv4Address: interface.hostIPv4Address,
            interfaceName: interface.name
        )

        if let ownedConfiguration, ownedConfiguration != requested {
            _ = try stopNow(
                leaseOwnerIdentifier: leaseOwnerIdentifier
            )
        }

        let inspections = try inspectRoutes(for: requested)
        if inspections.allSatisfy({ $0.value == .owned }) {
            ownedConfiguration = requested
            self.leaseOwnerIdentifier = leaseOwnerIdentifier
            return snapshot(for: requested, inspections: inspections)
        }
        if inspections.contains(where: { $0.value == .conflicting }) {
            let route = inspections.first { $0.value == .conflicting }!.key
            throw RouteCommandRunnerError.conflictingRoute(
                route.diagnosticName(interfaceName: requested.interfaceName)
            )
        }

        // Recover an interrupted earlier invocation only when its route bears
        // both private ownership flags and matches the exact gateway/interface.
        for route in ManagedIPv4Route.removalOrder
        where inspections[route] == .owned {
            try runner.delete(
                route,
                gateway: requested.guestIPv4Address,
                interfaceName: requested.interfaceName
            )
        }

        var added: [ManagedIPv4Route] = []
        do {
            for route in ManagedIPv4Route.installationOrder {
                try runner.add(
                    route,
                    gateway: requested.guestIPv4Address,
                    interfaceName: requested.interfaceName
                )
                added.append(route)
            }
        } catch {
            try failAfterRollingBack(
                error,
                addedRoutes: added,
                configuration: requested
            )
        }

        let installed: [ManagedIPv4Route: ManagedRouteInspection]
        do {
            installed = try inspectRoutes(for: requested)
            guard installed.allSatisfy({ $0.value == .owned }) else {
                let failures = ManagedIPv4Route.installationOrder.compactMap {
                    route -> String? in
                    guard let inspection = installed[route],
                          inspection != .owned else {
                        return nil
                    }
                    let output = runner.diagnosticOutput(
                        of: route,
                        interfaceName: requested.interfaceName
                    )
                    return "\(route.diagnosticName(interfaceName: requested.interfaceName)) is \(inspection.diagnosticName) [\(output)]"
                }
                throw NetworkRouteControllerError.routeVerificationFailed(
                    failures
                )
            }
        } catch {
            try failAfterRollingBack(
                error,
                addedRoutes: added,
                configuration: requested
            )
        }

        ownedConfiguration = requested
        self.leaseOwnerIdentifier = leaseOwnerIdentifier
        return snapshot(for: requested, inspections: installed)
    }

    private func failAfterRollingBack(
        _ originalError: Error,
        addedRoutes: [ManagedIPv4Route],
        configuration: OwnedConfiguration
    ) throws -> Never {
        var rollbackFailures: [String] = []
        for route in addedRoutes.reversed() {
            do {
                try runner.delete(
                    route,
                    gateway: configuration.guestIPv4Address,
                    interfaceName: configuration.interfaceName
                )
            } catch {
                rollbackFailures.append(
                    "rollback \(route.diagnosticName(interfaceName: configuration.interfaceName)): "
                        + error.localizedDescription
                )
            }
        }

        guard !rollbackFailures.isEmpty else {
            throw originalError
        }

        // The routes may now be partial. Do not grant a live lease for a
        // failed start; retain only enough exact configuration for the fresh
        // transient stop issued by the client to recover the leftovers.
        ownedConfiguration = configuration
        leaseOwnerIdentifier = nil
        throw NetworkRouteControllerError.couldNotRemoveRoutes(
            ["route setup failed: \(originalError.localizedDescription)"]
                + rollbackFailures
        )
    }

    private func stopNow(
        leaseOwnerIdentifier requestedLeaseOwnerIdentifier: UUID?
    ) throws -> NetworkRouteSnapshot {
        if ownedConfiguration == nil {
            ownedConfiguration = try discoverOwnedConfiguration()
        }
        guard let configuration = ownedConfiguration else {
            return .inactive
        }
        if let leaseOwnerIdentifier {
            guard requestedLeaseOwnerIdentifier == leaseOwnerIdentifier else {
                // A transient or stale connection must never tear down a route
                // pair whose lease is still held by a live connection.
                throw NetworkRouteControllerError
                    .routeLeaseOwnedByAnotherConnection
            }
        }

        var failures: [String] = []
        for route in ManagedIPv4Route.removalOrder {
            do {
                switch try runner.inspection(
                    of: route,
                    gateway: configuration.guestIPv4Address,
                    interfaceName: configuration.interfaceName
                ) {
                case .absent:
                    continue
                case .owned:
                    try runner.delete(
                        route,
                        gateway: configuration.guestIPv4Address,
                        interfaceName: configuration.interfaceName
                    )
                case .conflicting:
                    failures.append(
                        route.diagnosticName(
                            interfaceName: configuration.interfaceName
                        ) + " no longer has the ThruRNDIS ownership signature"
                    )
                }
            } catch {
                failures.append(
                    "\(route.diagnosticName(interfaceName: configuration.interfaceName)): \(error.localizedDescription)"
                )
            }
        }

        guard failures.isEmpty else {
            throw NetworkRouteControllerError.couldNotRemoveRoutes(failures)
        }
        ownedConfiguration = nil
        leaseOwnerIdentifier = nil
        return .inactive
    }

    private func currentSnapshot() throws -> NetworkRouteSnapshot {
        if ownedConfiguration == nil {
            ownedConfiguration = try discoverOwnedConfiguration()
        }
        guard let ownedConfiguration else {
            return .inactive
        }
        return snapshot(
            for: ownedConfiguration,
            inspections: try inspectRoutes(for: ownedConfiguration)
        )
    }

    private func inspectRoutes(
        for configuration: OwnedConfiguration
    ) throws -> [ManagedIPv4Route: ManagedRouteInspection] {
        var result: [ManagedIPv4Route: ManagedRouteInspection] = [:]
        for route in ManagedIPv4Route.all {
            result[route] = try runner.inspection(
                of: route,
                gateway: configuration.guestIPv4Address,
                interfaceName: configuration.interfaceName
            )
        }
        return result
    }

    private func snapshot(
        for configuration: OwnedConfiguration,
        inspections: [ManagedIPv4Route: ManagedRouteInspection]
    ) -> NetworkRouteSnapshot {
        let installedPrefixes = ManagedIPv4Route.prefixes.filter { prefix in
            ManagedIPv4Route.entries(for: prefix).allSatisfy { route in
                inspections[route] == .owned
            }
        }
        return NetworkRouteSnapshot(
            state: inspections.count == ManagedIPv4Route.all.count
                && inspections.allSatisfy { $0.value == .owned }
                ? .active : .degraded,
            guestIPv4Address: configuration.guestIPv4Address,
            hostIPv4Address: configuration.hostIPv4Address,
            interfaceName: configuration.interfaceName,
            installedPrefixes: installedPrefixes
        )
    }

    private func discoverOwnedConfiguration() throws -> OwnedConfiguration? {
        // Installation and removal keep a global entry present until all
        // interface-scoped entries are gone, so a restarted helper can first
        // recover the interface and gateway from this unscoped anchor.
        let records = try ManagedIPv4Route.global.compactMap {
            route -> RouteLookupRecord? in
            guard let record = try runner.lookup(
                route,
                interfaceName: nil
            ), record.isOwned else {
                return nil
            }
            return record
        }
        guard let first = records.first else {
            return nil
        }
        try resolver.validateGuestIPv4Address(first.gateway)
        guard records.allSatisfy({
            $0.gateway == first.gateway
                && $0.interfaceName == first.interfaceName
        }) else {
            throw NetworkRouteControllerError.couldNotRemoveRoutes([
                "owned route markers disagree about their gateway or interface",
            ])
        }

        return OwnedConfiguration(
            guestIPv4Address: first.gateway,
            hostIPv4Address: nil,
            interfaceName: first.interfaceName
        )
    }

    private struct OwnedConfiguration: Equatable {
        let guestIPv4Address: String
        let hostIPv4Address: String?
        let interfaceName: String
    }
}
