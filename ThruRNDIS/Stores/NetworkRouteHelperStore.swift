/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum NetworkRouteHelperOperation: Equatable {
    case installing
    case reinstalling
    case removing

    var title: String {
        switch self {
        case .installing:
            String(localized: "Installing network helper…")
        case .reinstalling:
            String(localized: "Reinstalling network helper…")
        case .removing:
            String(localized: "Removing network helper…")
        }
    }
}

@MainActor
final class NetworkRouteHelperStore: ObservableObject {
    private static let reregistrationDelay = Duration.seconds(2)

    let isSignedBuild: Bool

    @Published private(set) var registrationStatus:
        NetworkRouteHelperRegistrationStatus
    @Published private(set) var operation: NetworkRouteHelperOperation?

    private let registrationService:
        NetworkRoutePrivilegedHelperRegistrationService
    private let eventLog: EventLogStore

    init(eventLog: EventLogStore) {
        registrationService = NetworkRoutePrivilegedHelperRegistrationService()
        self.eventLog = eventLog
        isSignedBuild = PeerCodeSigningRequirementBuilder
            .currentProcessHasTeamIdentifier
        registrationStatus = registrationService.status()
    }

    var isOperationInProgress: Bool {
        operation != nil
    }

    var isAvailable: Bool {
        registrationStatus == .enabled
    }

    var needsAutomaticUpdate: Bool {
        registrationService.needsAutomaticUpdate
    }

    var canEnable: Bool {
        guard !isOperationInProgress else { return false }
        return switch registrationStatus {
        case .unknown, .notRegistered, .notFound:
            true
        case .enabled, .updateRequired, .requiresApproval:
            false
        }
    }

    var canReinstall: Bool {
        guard !isOperationInProgress else { return false }
        return switch registrationStatus {
        case .enabled, .updateRequired:
            true
        case .unknown, .notRegistered, .requiresApproval, .notFound:
            needsAutomaticUpdate
        }
    }

    var canDisable: Bool {
        guard !isOperationInProgress else { return false }
        return switch registrationStatus {
        case .enabled, .updateRequired, .requiresApproval:
            true
        case .unknown, .notRegistered, .notFound:
            false
        }
    }

    func enable() {
        guard canEnable else { return }
        operation = .installing
        appendEventLog("Network route helper enable requested.", level: .debug)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try self.registrationService.enable()
                self.operation = nil
                self.registrationStatus = status
                self.reportRegistrationResult(
                    status,
                    successMessage: "Network route helper is enabled for the current app build."
                )
            } catch {
                self.operation = nil
                self.refresh()
                if self.registrationStatus != .requiresApproval {
                    self.reportError(
                        "Could not enable the network route helper: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func disable() {
        guard canDisable else { return }
        operation = .removing
        appendEventLog("Network route helper disable requested.", level: .debug)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.registrationService.disable()
                self.operation = nil
                self.registrationStatus = status
                if status == .notRegistered || status == .notFound {
                    self.appendEventLog(
                        "Network route helper is disabled.",
                        level: .info
                    )
                } else {
                    self.reportError(
                        "Network route helper registration did not become disabled."
                    )
                }
            } catch {
                self.operation = nil
                self.refresh()
                self.reportError(
                    "Could not disable the network route helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func reinstall() {
        guard canReinstall else { return }
        operation = .reinstalling
        appendEventLog("Network route helper reinstall started.", level: .debug)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let removalStatus = try await self.registrationService.disable(
                    preservingRegisteredBuildVersion: true
                )
                guard removalStatus == .notRegistered
                        || removalStatus == .notFound else {
                    self.operation = nil
                    self.registrationStatus = removalStatus
                    self.reportError(
                        "Network route helper did not become disabled for reinstall."
                    )
                    return
                }

                try await Task.sleep(for: Self.reregistrationDelay)
                let status = try self.registrationService.enable()
                self.operation = nil
                self.registrationStatus = status
                self.reportRegistrationResult(
                    status,
                    successMessage: "Network route helper was reinstalled for the current app build."
                )
            } catch {
                self.operation = nil
                self.refresh()
                if self.registrationStatus != .requiresApproval {
                    self.reportError(
                        "Could not reinstall the network route helper: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func refresh() {
        guard !isOperationInProgress else { return }
        let status = registrationService.status()
        if registrationStatus != status {
            registrationStatus = status
        }
    }

    func openSystemSettings() {
        registrationService.openSystemSettings()
        appendEventLog(
            "Opened Login Items settings for network helper approval.",
            level: .debug
        )
    }

    func removeForAppSettings() async throws
        -> NetworkRouteHelperRegistrationStatus {
        guard !isOperationInProgress else {
            throw NetworkRouteSettingsResetError.operationInProgress
        }

        operation = .removing
        defer { operation = nil }
        let status = try await registrationService.disable()
        registrationStatus = status
        return status
    }

    private func reportRegistrationResult(
        _ status: NetworkRouteHelperRegistrationStatus,
        successMessage: String
    ) {
        switch status {
        case .enabled:
            appendEventLog(successMessage, level: .info)
        case .requiresApproval:
            appendEventLog(
                "Network route helper requires user approval.",
                level: .warning
            )
        default:
            reportError(
                "Network route helper registration did not become enabled."
            )
        }
    }

    private func reportError(_ message: String) {
        appendEventLog(message, level: .error)
    }

    private func appendEventLog(
        _ message: String,
        level: EventLogLevel
    ) {
        eventLog.append(message, level: level, category: .network)
    }
}
