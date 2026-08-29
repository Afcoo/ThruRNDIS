/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation
import SystemConfiguration

enum LegacyDummyEthernetCleanupError: LocalizedError {
    case conflict(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .conflict(let detail):
            "The Network Helper did not remove an ambiguous legacy configuration: \(detail)"
        case .operationFailed(let detail):
            "Could not remove the legacy network configuration: \(detail)"
        }
    }
}

/// Removes only the exact Dummy Ethernet objects recorded by ThruRNDIS 0.3.
struct LegacyDummyEthernetCleanupService: Sendable {
    private let interfaceRunner = NetworkInterfaceCommandRunner()

    func removeIfPresent() throws {
        try withLockedPreferences { preferences in
            guard let metadata = try metadata(in: preferences) else { return }
            let objects = try managedObjects(
                for: metadata,
                in: preferences
            )
            let shouldDetachMember = try validateRuntime(
                for: metadata,
                objects: objects
            )

            if shouldDetachMember {
                try interfaceRunner.run([
                    metadata.bondInterfaceName,
                    "-bonddev",
                    metadata.memberInterfaceName,
                ])
            }
            do {
                try removeFethPair(metadata)
            } catch {
                throw LegacyDummyEthernetCleanupError.operationFailed(
                    "The recorded feth pair could not be removed; its ownership record was retained. \(error.localizedDescription)"
                )
            }

            if let service = objects.service,
               !SCNetworkServiceRemove(service) {
                throw lastError("remove the recorded Network Service")
            }
            if let bond = objects.bond,
               !SCBondInterfaceRemove(bond) {
                throw lastError("remove the recorded Ethernet Bond")
            }
            guard SCPreferencesRemoveValue(
                preferences,
                Constants.metadataKey as CFString
            ) else {
                throw lastError("remove the legacy ownership metadata")
            }
            try commitAndApply(preferences)
        }
    }

    private func managedObjects(
        for metadata: Metadata,
        in preferences: SCPreferences
    ) throws -> ManagedObjects {
        let matchingBonds = ((SCBondInterfaceCopyAll(preferences)
            as? [SCBondInterface]) ?? []).filter {
                interfaceName(of: $0) == metadata.bondInterfaceName
            }
        guard matchingBonds.count <= 1 else {
            throw LegacyDummyEthernetCleanupError.conflict(
                "More than one Ethernet Bond uses the recorded BSD name."
            )
        }
        let bond = matchingBonds.first

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
                  CFEqual(interfaceType, kSCNetworkInterfaceTypeBond),
                  bond.map({ CFEqual(serviceInterface, $0) }) ?? true else {
                throw LegacyDummyEthernetCleanupError.conflict(
                    "The recorded Network Service no longer identifies its legacy Ethernet Bond."
                )
            }
        }
        return ManagedObjects(bond: bond, service: service)
    }

    private func validateRuntime(
        for metadata: Metadata,
        objects: ManagedObjects
    ) throws -> Bool {
        let memberExists = interfaceExists(metadata.memberInterfaceName)
        let peerExists = interfaceExists(metadata.peerInterfaceName)
        let hasSystemOwnership = objects.bond != nil || objects.service != nil

        let memberPeer = try memberExists
            ? interfaceRunner.fethPeer(
                interfaceName: metadata.memberInterfaceName
            )
            : nil
        let peerMember = try peerExists
            ? interfaceRunner.fethPeer(
                interfaceName: metadata.peerInterfaceName
            )
            : nil
        if memberExists && peerExists {
            guard memberPeer == metadata.peerInterfaceName,
                  peerMember == metadata.memberInterfaceName else {
                throw LegacyDummyEthernetCleanupError.conflict(
                    "The recorded feth interfaces are not each other's peers."
                )
            }
        } else if memberExists || peerExists {
            guard hasSystemOwnership,
                  memberPeer == nil
                    || memberPeer == metadata.peerInterfaceName,
                  peerMember == nil
                    || peerMember == metadata.memberInterfaceName else {
                throw LegacyDummyEthernetCleanupError.conflict(
                    "A lone recorded feth interface cannot be proven to be legacy-owned."
                )
            }
        }

        guard objects.bond != nil,
              interfaceExists(metadata.bondInterfaceName) else {
            return false
        }
        let runtime = try interfaceRunner.bondRuntime(
            interfaceName: metadata.bondInterfaceName
        )
        guard runtime.mode == "static",
              runtime.members.isEmpty
                || runtime.members == Set([metadata.memberInterfaceName]) else {
            throw LegacyDummyEthernetCleanupError.conflict(
                "The recorded Ethernet Bond has unexpected runtime members."
            )
        }
        return memberExists
            && runtime.members.contains(metadata.memberInterfaceName)
    }

    private func removeFethPair(_ metadata: Metadata) throws {
        if interfaceExists(metadata.memberInterfaceName) {
            try? interfaceRunner.run([
                metadata.memberInterfaceName,
                "-peer",
            ])
        }
        var failures: [String] = []
        for name in [
            metadata.peerInterfaceName,
            metadata.memberInterfaceName,
        ] where interfaceExists(name) {
            try? interfaceRunner.run([name, "down"])
            do {
                try interfaceRunner.run([name, "destroy"])
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        guard failures.isEmpty else {
            throw LegacyDummyEthernetCleanupError.operationFailed(
                failures.joined(separator: "; ")
            )
        }
    }

    private func metadata(
        in preferences: SCPreferences
    ) throws -> Metadata? {
        guard let value = SCPreferencesGetValue(
            preferences,
            Constants.metadataKey as CFString
        ) else {
            return nil
        }
        guard let values = value as? [String: String],
              Set(values.keys) == Set(MetadataKey.all),
              let bondInterfaceName = values[MetadataKey.bondInterfaceName],
              let networkServiceID = values[MetadataKey.networkServiceID],
              let memberInterfaceName = values[MetadataKey.memberInterfaceName],
              let peerInterfaceName = values[MetadataKey.peerInterfaceName],
              isCanonicalInterfaceName(
                bondInterfaceName,
                prefix: "bond"
              ),
              isCanonicalInterfaceName(
                memberInterfaceName,
                prefix: "feth"
              ),
              isCanonicalInterfaceName(
                peerInterfaceName,
                prefix: "feth"
              ),
              memberInterfaceName != peerInterfaceName,
              !networkServiceID.isEmpty else {
            throw LegacyDummyEthernetCleanupError.conflict(
                "The stored legacy ownership metadata is malformed."
            )
        }
        return Metadata(
            bondInterfaceName: bondInterfaceName,
            networkServiceID: networkServiceID,
            memberInterfaceName: memberInterfaceName,
            peerInterfaceName: peerInterfaceName
        )
    }

    private func withLockedPreferences<Result>(
        operation: (SCPreferences) throws -> Result
    ) throws -> Result {
        guard let preferences = SCPreferencesCreate(
            nil,
            "ThruRNDISPrivilegedHelper" as CFString,
            nil
        ) else {
            throw LegacyDummyEthernetCleanupError.operationFailed(
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
    ) -> LegacyDummyEthernetCleanupError {
        .operationFailed(
            "\(operation): \(String(cString: SCErrorString(SCError())))"
        )
    }

    private func interfaceName(
        of interface: SCNetworkInterface
    ) -> String? {
        SCNetworkInterfaceGetBSDName(interface) as String?
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

    private func interfaceExists(_ name: String) -> Bool {
        name.withCString { if_nametoindex($0) != 0 }
    }

    private enum Constants {
        static let metadataKey =
            "ThruRNDIS.DummyEthernet.Configuration"
    }

    private enum MetadataKey {
        static let bondInterfaceName = "BondInterfaceName"
        static let networkServiceID = "NetworkServiceID"
        static let memberInterfaceName = "MemberInterfaceName"
        static let peerInterfaceName = "PeerInterfaceName"
        static let all = [
            bondInterfaceName,
            networkServiceID,
            memberInterfaceName,
            peerInterfaceName,
        ]
    }

    private struct Metadata {
        let bondInterfaceName: String
        let networkServiceID: String
        let memberInterfaceName: String
        let peerInterfaceName: String
    }

    private struct ManagedObjects {
        let bond: SCBondInterface?
        let service: SCNetworkService?
    }
}
