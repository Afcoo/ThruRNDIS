/*
Copyright (C) 2026 Afcoo.
*/

import CoreFoundation
import Foundation
import ServiceManagement

@MainActor
struct DummyEthernetPrivilegedHelperRegistrationService {
    private static let registeredBuildVersionKey =
        "DummyEthernet.registeredHelperBuildVersion"

    private let service: SMAppService
    private let defaults: UserDefaults
    private let currentHelperBuildVersion: String?

    init() {
        service = SMAppService.daemon(
            plistName: ThruRNDISDummyEthernet.helperLaunchDaemonPlistName
        )
        defaults = .standard
        currentHelperBuildVersion = Self.helperBuildVersion()
    }

    func status() -> DummyEthernetHelperRegistrationStatus {
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
            return true
        case .notRegistered, .notFound:
            guard let currentHelperBuildVersion,
                  let registeredBuildVersion = defaults.string(
                    forKey: Self.registeredBuildVersionKey
                  ) else {
                return false
            }
            return registeredBuildVersion != currentHelperBuildVersion
        case .unknown, .enabled, .requiresApproval:
            return false
        }
    }

    func enable() throws -> DummyEthernetHelperRegistrationStatus {
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
        -> DummyEthernetHelperRegistrationStatus {
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
            .appendingPathComponent(
                ThruRNDISDummyEthernet.helperExecutableName
            )
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
    ) -> DummyEthernetHelperRegistrationStatus {
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
