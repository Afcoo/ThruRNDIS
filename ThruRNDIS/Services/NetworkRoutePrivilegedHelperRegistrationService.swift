/*
Copyright (C) 2026 Afcoo.
*/

import CoreFoundation
import Foundation
import ServiceManagement

@MainActor
struct NetworkRoutePrivilegedHelperRegistrationService {
    private static let registeredBuildVersionKey =
        "NetworkRoute.registeredHelperBuildVersion"
    private static let replacementCleanupPendingKey =
        "NetworkRoute.helperReplacementCleanupPending"

    private let service: SMAppService
    private let defaults: UserDefaults
    private let currentHelperBuildVersion: String?

    init() {
        service = SMAppService.daemon(
            plistName: ThruRNDISNetworkRoute.helperLaunchDaemonPlistName
        )
        defaults = .standard
        currentHelperBuildVersion = Self.helperBuildVersion()
    }

    func status() -> NetworkRouteHelperRegistrationStatus {
        let registrationStatus = Self.registrationStatus(from: service.status)
        guard registrationStatus == .enabled else {
            return registrationStatus
        }
        guard !hasPendingReplacementCleanup,
              let currentHelperBuildVersion,
              defaults.string(forKey: Self.registeredBuildVersionKey)
                == currentHelperBuildVersion else {
            return .updateRequired
        }
        return .enabled
    }

    var needsAutomaticUpdate: Bool {
        switch status() {
        case .updateRequired:
            true
        case .notRegistered, .notFound:
            if let currentHelperBuildVersion,
               let registeredBuildVersion = defaults.string(
                forKey: Self.registeredBuildVersionKey
               ) {
                hasPendingReplacementCleanup
                    || registeredBuildVersion != currentHelperBuildVersion
            } else {
                false
            }
        case .unknown, .enabled, .requiresApproval:
            false
        }
    }

    var canCleanUpAfterReplacement: Bool {
        guard let currentHelperBuildVersion else { return false }
        // Legacy Boolean markers do not identify a build and must reinstall.
        return defaults.object(forKey: Self.replacementCleanupPendingKey) as? String
            == currentHelperBuildVersion
            && service.status == .enabled
    }

    func requireReplacementCleanup() {
        // An unknown build remains pending but can never resume cleanup.
        defaults.set(
            currentHelperBuildVersion ?? "",
            forKey: Self.replacementCleanupPendingKey
        )
    }

    func completeReplacementCleanup() {
        // register() may have required approval before recording the version.
        recordRegisteredBuildVersion()
        defaults.removeObject(forKey: Self.replacementCleanupPendingKey)
    }

    func enable() throws -> NetworkRouteHelperRegistrationStatus {
        let currentStatus = status()
        switch currentStatus {
        case .enabled, .updateRequired, .requiresApproval:
            return currentStatus
        case .unknown, .notRegistered, .notFound:
            break
        }

        try service.register()
        recordRegisteredBuildVersion()
        return status()
    }

    func disable(preservingRegisteredBuildVersion: Bool = false) async throws
        -> NetworkRouteHelperRegistrationStatus {
        let currentStatus = status()
        switch currentStatus {
        case .notRegistered, .notFound:
            if !preservingRegisteredBuildVersion {
                clearRegisteredBuildVersion()
            }
            return currentStatus
        case .unknown, .enabled, .updateRequired, .requiresApproval:
            break
        }

        // Await daemon termination. The replacement workflow also allows time
        // for Background Task Management's registration state to settle.
        try await service.unregister()
        if !preservingRegisteredBuildVersion {
            clearRegisteredBuildVersion()
        }
        return status()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var hasPendingReplacementCleanup: Bool {
        defaults.object(forKey: Self.replacementCleanupPendingKey) != nil
    }

    private func clearRegisteredBuildVersion() {
        defaults.removeObject(forKey: Self.registeredBuildVersionKey)
    }

    private func recordRegisteredBuildVersion() {
        if let currentHelperBuildVersion {
            defaults.set(
                currentHelperBuildVersion,
                forKey: Self.registeredBuildVersionKey
            )
        }
    }

    private static func helperBuildVersion() -> String? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(ThruRNDISNetworkRoute.helperExecutableName)
        guard let infoDictionary = CFBundleCopyInfoDictionaryForURL(
            helperURL as CFURL
        ) as? [String: Any],
              let buildVersion = infoDictionary[kCFBundleVersionKey as String]
                as? String,
              !buildVersion.isEmpty else {
            return nil
        }
        return buildVersion
    }

    private static func registrationStatus(
        from status: SMAppService.Status
    ) -> NetworkRouteHelperRegistrationStatus {
        switch status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .unknown
        }
    }
}
