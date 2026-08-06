/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

enum DummyEthernetHelperOperation: String, Equatable {
    case installing = "helper install"
    case reinstalling = "helper reinstall"
    case removing = "helper removal"

    var title: String {
        switch self {
        case .installing:
            String(localized: "Installing Dummy Ethernet helper…")
        case .reinstalling:
            String(localized: "Reinstalling Dummy Ethernet helper…")
        case .removing:
            String(localized: "Removing Dummy Ethernet helper…")
        }
    }
}

@MainActor
final class DummyEthernetHelperStore: ObservableObject {
    private static let reregistrationDelay = Duration.seconds(2)

    let isSignedBuild: Bool

    @Published private(set) var registrationStatus:
        DummyEthernetHelperRegistrationStatus
    @Published private(set) var operation: DummyEthernetHelperOperation?

    private let registrationService:
        DummyEthernetPrivilegedHelperRegistrationService
    private let eventLog: EventLogStore

    init(eventLog: EventLogStore) {
        registrationService =
            DummyEthernetPrivilegedHelperRegistrationService()
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

    var canEnable: Bool {
        guard !isOperationInProgress else { return false }
        switch registrationStatus {
        case .unknown, .notRegistered, .notFound:
            return true
        case .enabled, .updateRequired, .requiresApproval:
            return false
        }
    }

    var canReinstall: Bool {
        guard !isOperationInProgress else { return false }
        switch registrationStatus {
        case .enabled, .updateRequired:
            return true
        case .unknown, .notRegistered, .requiresApproval, .notFound:
            return false
        }
    }

    var isReinstallActionPresented: Bool {
        switch registrationStatus {
        case .enabled, .updateRequired:
            true
        case .unknown, .notRegistered, .requiresApproval, .notFound:
            operation == .reinstalling
        }
    }

    var canDisable: Bool {
        guard !isOperationInProgress else { return false }
        switch registrationStatus {
        case .enabled, .updateRequired, .requiresApproval:
            return true
        case .unknown, .notRegistered, .notFound:
            return false
        }
    }

    func enable() {
        guard canEnable else { return }
        operation = .installing
        appendEventLog(
            "Dummy Ethernet helper enable requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try self.registrationService.enable()
                self.operation = nil
                self.registrationStatus = status

                switch status {
                case .enabled:
                    self.appendEventLog(
                        "Dummy Ethernet helper is enabled for the current app build.",
                        level: .info
                    )
                case .requiresApproval:
                    self.appendEventLog(
                        "Dummy Ethernet helper requires user approval.",
                        level: .warning
                    )
                default:
                    self.reportError(
                        "Dummy Ethernet helper registration did not become enabled."
                    )
                }
            } catch {
                self.operation = nil
                self.refresh()
                if self.registrationStatus == .requiresApproval {
                    return
                }
                self.reportError(
                    "Could not enable the Dummy Ethernet helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func disable() {
        guard canDisable else { return }
        operation = .removing
        appendEventLog(
            "Dummy Ethernet helper disable requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.registrationService.disable()
                self.operation = nil
                self.registrationStatus = status

                switch status {
                case .notRegistered, .notFound:
                    self.appendEventLog(
                        "Dummy Ethernet helper is disabled.",
                        level: .info
                    )
                default:
                    self.reportError(
                        "Dummy Ethernet helper registration did not become disabled."
                    )
                }
            } catch {
                self.operation = nil
                self.refresh()
                self.reportError(
                    "Could not disable the Dummy Ethernet helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func reinstall() {
        guard canReinstall else { return }
        operation = .reinstalling
        appendEventLog(
            "Dummy Ethernet helper reinstall requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let removalStatus = try await self.registrationService.disable()
                guard removalStatus == .notRegistered
                        || removalStatus == .notFound else {
                    self.operation = nil
                    self.registrationStatus = removalStatus
                    self.reportError(
                        "Dummy Ethernet helper registration did not become disabled for reinstall."
                    )
                    return
                }

                // ServiceManagement can reject an immediate registration even
                // after its asynchronous unregister completion has returned.
                try await Task.sleep(for: Self.reregistrationDelay)
                let status = try self.registrationService.enable()
                self.operation = nil
                self.registrationStatus = status

                switch status {
                case .enabled:
                    self.appendEventLog(
                        "Dummy Ethernet helper was reinstalled for the current app build.",
                        level: .info
                    )
                case .requiresApproval:
                    self.appendEventLog(
                        "Dummy Ethernet helper requires user approval after reinstall.",
                        level: .warning
                    )
                default:
                    self.reportError(
                        "Dummy Ethernet helper registration did not become enabled after reinstall."
                    )
                }
            } catch {
                self.operation = nil
                self.refresh()
                if self.registrationStatus == .requiresApproval {
                    return
                }
                self.reportError(
                    "Could not reinstall the Dummy Ethernet helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func openSystemSettings() {
        registrationService.openSystemSettings()
        appendEventLog(
            "Opened Login Items settings for Dummy Ethernet helper approval.",
            level: .debug
        )
    }

    func refresh() {
        guard !isOperationInProgress else { return }
        let status = registrationService.status()
        if registrationStatus != status {
            registrationStatus = status
        }
    }

    func removeForAppSettings() async throws
        -> DummyEthernetHelperRegistrationStatus {
        guard !isOperationInProgress else {
            throw DummyEthernetSettingsResetError.operationInProgress
        }

        operation = .removing
        appendEventLog(
            "Dummy Ethernet helper removal requested for app settings reset.",
            level: .debug
        )
        defer { operation = nil }

        do {
            let status = try await registrationService.disable()
            registrationStatus = status
            return status
        } catch {
            operation = nil
            refresh()
            throw error
        }
    }

    private func reportError(_ message: String) {
        appendEventLog(message, level: .error)
    }

    private func appendEventLog(
        _ message: String,
        level: EventLogLevel
    ) {
        eventLog.append(message, level: level, category: .dummyEthernet)
    }
}
