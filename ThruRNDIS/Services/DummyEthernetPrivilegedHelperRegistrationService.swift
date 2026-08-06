/*
Copyright (C) 2026 Afcoo.
*/

import CoreFoundation
import Foundation
import ServiceManagement

@MainActor
struct DummyEthernetPrivilegedHelperRegistrationService {
    private static let registeredIdentityKey =
        "DummyEthernet.registeredHelperIdentity"

    private let service: SMAppService
    private let defaults: UserDefaults
    private let currentHelperIdentity: String?

    init() {
        service = SMAppService.daemon(
            plistName: ThruRNDISDummyEthernet.helperLaunchDaemonPlistName
        )
        defaults = .standard
        currentHelperIdentity = Self.helperInstallationIdentity()
    }

    func status() -> DummyEthernetHelperRegistrationStatus {
        let registrationStatus = Self.registrationStatus(from: service.status)
        guard registrationStatus == .enabled else {
            return registrationStatus
        }
        guard let currentHelperIdentity,
              defaults.string(forKey: Self.registeredIdentityKey)
                == currentHelperIdentity else {
            return .updateRequired
        }
        return .enabled
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
        if let currentHelperIdentity {
            defaults.set(
                currentHelperIdentity,
                forKey: Self.registeredIdentityKey
            )
        }
        return status()
    }

    func disable() async throws
        -> DummyEthernetHelperRegistrationStatus {
        let currentStatus = status()
        switch currentStatus {
        case .notRegistered, .notFound:
            clearRegisteredIdentity()
            return currentStatus
        case .unknown, .enabled, .updateRequired, .requiresApproval:
            break
        }

        try await service.unregister()
        clearRegisteredIdentity()
        return status()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func clearRegisteredIdentity() {
        defaults.removeObject(forKey: Self.registeredIdentityKey)
    }

    private static func helperInstallationIdentity() -> String? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(
                ThruRNDISDummyEthernet.helperExecutableName
            )
        guard let infoDictionary = CFBundleCopyInfoDictionaryForURL(
            helperURL as CFURL
        ) as? [String: Any],
            let identity = infoDictionary[
                ThruRNDISDummyEthernet
                    .helperInstallationIdentityInfoDictionaryKey
            ] as? String,
            !identity.isEmpty else {
            return nil
        }
        return identity
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
