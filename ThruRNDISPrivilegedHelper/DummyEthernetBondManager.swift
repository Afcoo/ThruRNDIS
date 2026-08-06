/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation

enum DummyEthernetBondManagerError: Error, LocalizedError {
    case configurationConflict(String)
    case operationFailed(String)
    case networkPathUnsatisfied(String)

    var errorDescription: String? {
        switch self {
        case .configurationConflict(let detail):
            "Dummy Ethernet did not modify an ambiguous configuration: \(detail)"
        case .operationFailed(let detail):
            detail
        case .networkPathUnsatisfied(let bondInterfaceName):
            "The \(bondInterfaceName) Ethernet network path did not become satisfied."
        }
    }
}

/// Serializes the small feth -> Bond -> Network Service lifecycle.
final class DummyEthernetBondManager: @unchecked Sendable {
    typealias Completion = @Sendable (
        Result<DummyEthernetNetworkSnapshot, Error>
    ) -> Void

    private let operationQueue = DispatchQueue(
        label: "ThruRNDIS.DummyEthernetBondManager"
    )
    private let runner = IfconfigRunner()
    private let systemConfiguration =
        DummyEthernetSystemConfigurationService()
    private let networkPathMonitor = DummyEthernetNetworkPathMonitor()

    func status(completion: @escaping Completion) {
        operationQueue.async {
            completion(Result { try self.statusSynchronously() })
        }
    }

    func start(
        configuration: DummyEthernetConfiguration,
        completion: @escaping Completion
    ) {
        operationQueue.async {
            completion(Result {
                try self.startSynchronously(configuration)
            })
        }
    }

    func stop(completion: @escaping Completion) {
        operationQueue.async {
            completion(Result { try self.stopSynchronously() })
        }
    }

    private func statusSynchronously() throws
        -> DummyEthernetNetworkSnapshot {
        snapshot(configuration: try systemConfiguration.inspect())
    }

    private func startSynchronously(
        _ untrustedConfiguration: DummyEthernetConfiguration
    ) throws -> DummyEthernetNetworkSnapshot {
        let requested = try DummyEthernetConfigurationValidator.validate(
            untrustedConfiguration
        )
        let existing = try systemConfiguration.inspect()

        if existing.hasConfiguration {
            let current = snapshot(configuration: existing)
            if current.state == .active,
               current.configuredIPv4Address == requested.hostIPv4Address,
               current.memberInterfaceName == requested.memberInterfaceName,
               current.peerInterfaceName == requested.peerInterfaceName {
                return current
            }
            throw DummyEthernetBondManagerError.configurationConflict(
                "A partial or differently configured ThruRNDIS setup already exists. Stop it before starting again."
            )
        }

        for name in [requested.memberInterfaceName, requested.peerInterfaceName]
            where interfaceExists(name) {
            throw DummyEthernetBondManagerError.configurationConflict(
                "\(name) already exists without a ThruRNDIS configuration."
            )
        }

        try createFethPair(configuration: requested)
        var bondInterfaceName: String?
        do {
            let bondName = try systemConfiguration
                .createDisabledConfiguration(requested)
            bondInterfaceName = bondName
            try waitForInterface(bondName, timeout: 3)
            try runner.run([bondName, "bondmode", "static"])
            try runner.run([
                bondName,
                "bonddev",
                requested.memberInterfaceName
            ])
            try systemConfiguration.enableNetworkService()

            guard networkPathMonitor.waitUntilSatisfied(
                interfaceName: bondName,
                timeout: 12
            ) else {
                throw DummyEthernetBondManagerError.networkPathUnsatisfied(
                    bondName
                )
            }
            let result = snapshot(
                configuration: try systemConfiguration.inspect(),
                networkPathSatisfied: true
            )
            guard result.state == .active else {
                throw DummyEthernetBondManagerError.operationFailed(
                    "Dummy Ethernet did not reach its active state."
                )
            }
            return result
        } catch {
            let cleanupFailure = rollbackFailedStart(
                bondInterfaceName: bondInterfaceName,
                configuration: requested
            )
            guard let cleanupFailure else { throw error }
            throw DummyEthernetBondManagerError.operationFailed(
                "\(error.localizedDescription) Cleanup: \(cleanupFailure)"
            )
        }
    }

    private func stopSynchronously() throws
        -> DummyEthernetNetworkSnapshot {
        let existing = try systemConfiguration.inspect()
        guard existing.hasConfiguration else { return .inactive }
        guard let member = existing.memberInterfaceName,
              let peer = existing.peerInterfaceName else {
            throw DummyEthernetBondManagerError.configurationConflict(
                "The managed feth interface names are unavailable."
            )
        }
        try removeManagedConfiguration(
            bond: existing.bondInterfaceName,
            member: member,
            peer: peer
        )
        return .inactive
    }

    private func snapshot(
        configuration: DummyEthernetSystemConfigurationSnapshot,
        networkPathSatisfied knownPathState: Bool? = nil
    ) -> DummyEthernetNetworkSnapshot {
        guard configuration.hasConfiguration else { return .inactive }
        let configurationReady = configuration.hasBond
            && configuration.hasNetworkService
            && configuration.isNetworkServiceEnabled
            && hasRuntimeInterfaces(configuration)
        let pathSatisfied = knownPathState
            ?? configuration.bondInterfaceName.map {
                configurationReady
                    && networkPathMonitor.waitUntilSatisfied(
                        interfaceName: $0,
                        timeout: 1
                    )
            } ?? false
        return DummyEthernetNetworkSnapshot(
            state: configurationReady && pathSatisfied ? .active : .degraded,
            bondInterfaceName: configuration.bondInterfaceName,
            memberInterfaceName: configuration.memberInterfaceName,
            peerInterfaceName: configuration.peerInterfaceName,
            configuredIPv4Address: configuration.configuredIPv4Address
        )
    }

    private func createFethPair(
        configuration: DummyEthernetConfiguration
    ) throws {
        let member = configuration.memberInterfaceName
        let peer = configuration.peerInterfaceName
        try runner.run([member, "create"])
        do {
            try runner.run([peer, "create"])
        } catch {
            try? runner.run([member, "destroy"])
            throw error
        }
        do {
            try runner.run([member, "peer", peer])
            try runner.run([member, "up"])
            try runner.run([
                peer,
                "inet",
                configuration.routerIPv4Address,
                "netmask",
                "255.255.255.255",
                "up"
            ])
        } catch {
            for name in [peer, member] {
                optionalIfconfig([name, "down"])
                try? runner.run([name, "destroy"])
            }
            throw error
        }
    }

    private func rollbackFailedStart(
        bondInterfaceName: String?,
        configuration: DummyEthernetConfiguration
    ) -> String? {
        let member = configuration.memberInterfaceName
        let bond = bondInterfaceName
            ?? (try? systemConfiguration.inspect())?.bondInterfaceName
        do {
            try removeManagedConfiguration(
                bond: bond,
                member: member,
                peer: configuration.peerInterfaceName
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func removeManagedConfiguration(
        bond: String?,
        member: String,
        peer: String
    ) throws {
        if let bond, interfaceExists(bond), interfaceExists(member) {
            optionalIfconfig([bond, "-bonddev", member])
        }
        do {
            try removeFethPair(member: member, peer: peer)
        } catch {
            throw DummyEthernetBondManagerError.operationFailed(
                "The feth pair could not be removed; its SystemConfiguration marker was retained. "
                    + error.localizedDescription
            )
        }
        try systemConfiguration.removeConfiguration()
    }

    private func removeFethPair(
        member: String,
        peer: String
    ) throws {
        if interfaceExists(member) {
            optionalIfconfig([member, "-peer"])
        }
        var firstError: Error?
        for name in [peer, member] where interfaceExists(name) {
            optionalIfconfig([name, "down"])
            do {
                try runner.run([name, "destroy"])
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func hasRuntimeInterfaces(
        _ configuration: DummyEthernetSystemConfigurationSnapshot
    ) -> Bool {
        guard let bond = configuration.bondInterfaceName,
              let member = configuration.memberInterfaceName,
              let peer = configuration.peerInterfaceName else {
            return false
        }
        return interfaceExists(bond)
            && interfaceExists(member)
            && interfaceExists(peer)
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
        throw DummyEthernetBondManagerError.operationFailed(
            "\(name) did not appear after applying SystemConfiguration."
        )
    }

    private func optionalIfconfig(_ arguments: [String]) {
        try? runner.run(arguments)
    }

    private func interfaceExists(_ name: String) -> Bool {
        name.withCString { if_nametoindex($0) != 0 }
    }
}
