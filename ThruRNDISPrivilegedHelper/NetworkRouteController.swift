/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum NetworkRouteControllerError: LocalizedError {
    case couldNotRemoveRoutes([String])
    case routeLeaseOwnedByAnotherConnection
    case routeVerificationFailed

    var errorDescription: String? {
        switch self {
        case .couldNotRemoveRoutes(let failures):
            "Could not remove all managed IPv4 routes: \(failures.joined(separator: "; "))"
        case .routeLeaseOwnedByAnotherConnection:
            "The managed IPv4 routes are leased by another live app connection."
        case .routeVerificationFailed:
            "The managed IPv4 routes did not match the expected configuration after installation."
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
            throw RouteCommandRunnerError.conflictingRoute(route.prefix)
        }

        // Recover an interrupted earlier invocation only when its route bears
        // both private ownership flags and matches the exact gateway/interface.
        for (route, inspection) in inspections where inspection == .owned {
            try runner.delete(
                route,
                gateway: requested.guestIPv4Address,
                interfaceName: requested.interfaceName
            )
        }

        var added: [ManagedIPv4Route] = []
        do {
            for route in ManagedIPv4Route.all {
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
                throw NetworkRouteControllerError.routeVerificationFailed
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
                    "rollback \(route.prefix): \(error.localizedDescription)"
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
        for route in ManagedIPv4Route.all {
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
                        "\(route.prefix) no longer has the ThruRNDIS ownership signature"
                    )
                }
            } catch {
                failures.append("\(route.prefix): \(error.localizedDescription)")
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
        let installedPrefixes = ManagedIPv4Route.all.compactMap { route in
            inspections[route] == .owned ? route.prefix : nil
        }
        return NetworkRouteSnapshot(
            state: installedPrefixes.count == ManagedIPv4Route.all.count
                ? .active : .degraded,
            guestIPv4Address: configuration.guestIPv4Address,
            hostIPv4Address: configuration.hostIPv4Address,
            interfaceName: configuration.interfaceName,
            installedPrefixes: installedPrefixes
        )
    }

    private func discoverOwnedConfiguration() throws -> OwnedConfiguration? {
        let records = try ManagedIPv4Route.all.compactMap { route -> RouteLookupRecord? in
            guard let record = try runner.lookup(route), record.isOwned else {
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
