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
        guard let currentHelperBuildVersion,
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
                registeredBuildVersion != currentHelperBuildVersion
            } else {
                false
            }
        case .unknown, .enabled, .requiresApproval:
            false
        }
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
        if let currentHelperBuildVersion {
            defaults.set(
                currentHelperBuildVersion,
                forKey: Self.registeredBuildVersionKey
            )
        }
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

        try await service.unregister()
        if !preservingRegisteredBuildVersion {
            clearRegisteredBuildVersion()
        }
        return status()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func clearRegisteredBuildVersion() {
        defaults.removeObject(forKey: Self.registeredBuildVersionKey)
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
