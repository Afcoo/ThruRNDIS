/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import SystemConfiguration

struct SystemConfigurationPreferencesTransaction: Sendable {
    func withLockedPreferences<Result>(
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
            throw error("lock System network preferences")
        }
        defer { SCPreferencesUnlock(preferences) }
        SCPreferencesSynchronize(preferences)
        return try operation(preferences)
    }

    func commitAndApply(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences),
              SCPreferencesApplyChanges(preferences) else {
            throw error("commit and apply System network preferences")
        }
    }

    func error(
        _ operation: String
    ) -> NetworkRouteSystemConfigurationError {
        .operationFailed(
            "\(operation): \(String(cString: SCErrorString(SCError())))"
        )
    }
}
