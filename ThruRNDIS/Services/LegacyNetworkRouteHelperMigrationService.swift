/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

private enum LegacyNetworkRouteHelperDefaultsKey {
    static let registeredBuildVersion =
        "NetworkRoute.registeredHelperBuildVersion"
    static let legacyRegisteredBuildVersion =
        "DummyEthernet.registeredHelperBuildVersion"
    static let didMigrateLegacyRegistration =
        "NetworkRoute.didMigrateLegacyHelperRegistration"
}

private enum LegacyNetworkRouteHelperMigrationError: LocalizedError {
    case removalIncomplete
    case registrationIncomplete
    case approvalRequired

    var errorDescription: String? {
        switch self {
        case .removalIncomplete:
            "The legacy Network Helper registration could not be removed."
        case .registrationIncomplete:
            "The current Network Helper registration could not be installed."
        case .approvalRequired:
            "Allow the current Network Helper, then restart ThruRNDIS to finish legacy cleanup."
        }
    }
}

@MainActor
struct LegacyNetworkRouteHelperMigrationService {
    private static let reregistrationDelay = Duration.seconds(2)

    private let defaults: UserDefaults
    private let registrationService:
        NetworkRoutePrivilegedHelperRegistrationService

    init() {
        defaults = .standard
        registrationService = NetworkRoutePrivilegedHelperRegistrationService()
    }

    /// Returns true only when the legacy registration and network were removed.
    func migrateIfNeeded() async throws -> Bool {
        guard !defaults.bool(
            forKey: LegacyNetworkRouteHelperDefaultsKey
                .didMigrateLegacyRegistration
        ) else {
            return false
        }

        guard defaults.object(
            forKey: LegacyNetworkRouteHelperDefaultsKey
                .legacyRegisteredBuildVersion
        ) != nil else {
            markCompleted()
            return false
        }

        if defaults.object(
            forKey: LegacyNetworkRouteHelperDefaultsKey.registeredBuildVersion
        ) != nil {
            do {
                try await removeLegacyNetworkUsingCurrentHelper()
                markCompleted()
                return true
            } catch {
                guard shouldReplaceCurrentRegistration(after: error) else {
                    throw error
                }
            }
        }

        let removalStatus = try await registrationService.disable(
            preservingRegisteredBuildVersion: true
        )
        guard removalStatus == .notRegistered
                || removalStatus == .notFound else {
            throw LegacyNetworkRouteHelperMigrationError.removalIncomplete
        }

        try await Task.sleep(for: Self.reregistrationDelay)
        let registrationStatus = try registrationService.enable()
        guard registrationStatus == .enabled
                || registrationStatus == .requiresApproval else {
            invalidateCurrentRegistrationRecord()
            throw LegacyNetworkRouteHelperMigrationError
                .registrationIncomplete
        }
        guard registrationStatus == .enabled else {
            invalidateCurrentRegistrationRecord()
            throw LegacyNetworkRouteHelperMigrationError.approvalRequired
        }
        try await removeLegacyNetworkUsingCurrentHelper()

        markCompleted()
        return true
    }

    private func removeLegacyNetworkUsingCurrentHelper() async throws {
        do {
            _ = try await NetworkRoutePrivilegedHelperClient().stop()
        } catch {
            invalidateCurrentRegistrationRecord()
            throw error
        }
    }

    private func shouldReplaceCurrentRegistration(after error: Error) -> Bool {
        guard let error = error as?
                NetworkRoutePrivilegedHelperClientError else {
            return false
        }
        return switch error {
        case .remoteObjectUnavailable, .malformedResponse, .requestTimedOut:
            true
        case .applicationBundleIdentifierUnavailable, .helperFailure:
            false
        }
    }

    private func invalidateCurrentRegistrationRecord() {
        defaults.removeObject(
            forKey: LegacyNetworkRouteHelperDefaultsKey
                .registeredBuildVersion
        )
    }

    private func markCompleted() {
        defaults.removeObject(
            forKey: LegacyNetworkRouteHelperDefaultsKey
                .legacyRegisteredBuildVersion
        )
        defaults.set(
            true,
            forKey: LegacyNetworkRouteHelperDefaultsKey
                .didMigrateLegacyRegistration
        )
    }
}
