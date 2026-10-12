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
            String(localized: "Installing Network Helper…")
        case .reinstalling:
            String(localized: "Reinstalling Network Helper…")
        case .removing:
            String(localized: "Removing Network Helper…")
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
    private var hasAttemptedReplacementCleanup = false

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
        appendEventLog("Network Helper enable requested.", level: .debug)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try self.registrationService.enable()
                try await self.cleanUpAfterReplacementIfNeeded()
                let status = self.registrationService.status()
                self.registrationStatus = status
                self.operation = nil
                self.reportRegistrationResult(
                    status,
                    successMessage: "Network Helper is enabled for the current app build."
                )
            } catch {
                self.registrationStatus = self.registrationService.status()
                self.operation = nil
                self.refresh()
                if self.registrationStatus != .requiresApproval {
                    self.reportError(
                        "Could not enable the Network Helper: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func disable() {
        guard canDisable else { return }
        operation = .removing
        appendEventLog("Network Helper disable requested.", level: .debug)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.registrationService.disable()
                self.operation = nil
                self.registrationStatus = status
                if status == .notRegistered || status == .notFound {
                    self.appendEventLog(
                        "Network Helper is disabled.",
                        level: .info
                    )
                } else {
                    self.reportError(
                        "Network Helper registration did not become disabled."
                    )
                }
            } catch {
                self.operation = nil
                self.refresh()
                self.reportError(
                    "Could not disable the Network Helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func reinstall() {
        guard canReinstall else { return }
        operation = .reinstalling
        appendEventLog("Network Helper reinstall started.", level: .debug)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Approval or relaunch can resume cleanup without replacing an
                // already registered helper. Explicit retries after failure
                // still perform a full reinstall.
                if !self.registrationService.canCleanUpAfterReplacement
                    || self.hasAttemptedReplacementCleanup {
                    // Authenticate only the new executable. The old daemon may
                    // no longer match the replaced app bundle on disk.
                    let removalStatus = try await self.registrationService.disable(
                        preservingRegisteredBuildVersion: true
                    )
                    guard removalStatus == .notRegistered
                            || removalStatus == .notFound else {
                        self.registrationStatus = removalStatus
                        self.operation = nil
                        self.reportError(
                            "Network Helper did not become disabled for reinstall."
                        )
                        return
                    }

                    self.registrationService.requireReplacementCleanup()
                    self.hasAttemptedReplacementCleanup = false
                    // macOS 27 can finish unregistering the process before
                    // Background Task Management permits registration again.
                    try await Task.sleep(for: Self.reregistrationDelay)
                    _ = try self.registrationService.enable()
                }
                try await self.cleanUpAfterReplacementIfNeeded()
                let status = self.registrationService.status()
                self.registrationStatus = status
                self.operation = nil
                self.reportRegistrationResult(
                    status,
                    successMessage: "Network Helper was reinstalled for the current app build."
                )
            } catch {
                self.registrationStatus = self.registrationService.status()
                self.operation = nil
                self.refresh()
                if self.registrationStatus != .requiresApproval {
                    self.reportError(
                        "Could not reinstall the Network Helper: \(error.localizedDescription)"
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
        // Resume once after approval or relaunch. A failed cleanup remains
        // unavailable until an explicit reinstall (or the next launch).
        guard registrationService.canCleanUpAfterReplacement,
              !hasAttemptedReplacementCleanup else { return }
        reinstall()
    }

    private func cleanUpAfterReplacementIfNeeded() async throws {
        guard registrationService.canCleanUpAfterReplacement else { return }
        hasAttemptedReplacementCleanup = true
        appendEventLog(
            "Cleaning up managed network state with the replacement Network Helper.",
            level: .debug
        )
        let replacementClient = NetworkRoutePrivilegedHelperClient()
        let snapshot = try await replacementClient.stop()
        guard snapshot.state == .inactive else {
            throw NetworkRoutePrivilegedHelperClientError.helperFailure(
                message: "Network Helper replacement cleanup did not become inactive."
            )
        }
        registrationService.completeReplacementCleanup()
    }

    func openSystemSettings() {
        registrationService.openSystemSettings()
        appendEventLog(
            "Opened Login Items settings for Network Helper approval.",
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
                "Network Helper requires user approval.",
                level: .warning
            )
        default:
            reportError(
                "Network Helper registration did not become enabled."
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
