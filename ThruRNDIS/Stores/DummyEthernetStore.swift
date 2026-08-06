/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

enum DummyEthernetOperation: String, Equatable {
    enum StatusSection: Equatable {
        case privilegedHelper
        case dummyEthernet
    }

    case installingHelper = "helper install"
    case reinstallingHelper = "helper reinstall"
    case removingHelper = "helper removal"
    case refreshing = "refresh"
    case starting = "start"
    case restarting = "restart"
    case stopping = "stop"

    var title: String {
        switch self {
        case .installingHelper:
            String(localized: "Installing Helper…")
        case .reinstallingHelper:
            String(localized: "Reinstalling Helper…")
        case .removingHelper:
            String(localized: "Removing Helper…")
        case .refreshing:
            String(localized: "Refreshing…")
        case .starting:
            String(localized: "Starting…")
        case .restarting:
            String(localized: "Restarting…")
        case .stopping:
            String(localized: "Stopping…")
        }
    }

    var statusSection: StatusSection {
        switch self {
        case .installingHelper, .reinstallingHelper, .removingHelper:
            .privilegedHelper
        case .refreshing, .starting, .restarting, .stopping:
            .dummyEthernet
        }
    }
}

@MainActor
final class DummyEthernetStore: ObservableObject {
    private static let helperReregistrationDelay = Duration.seconds(2)

    let isSignedBuild: Bool

    @Published private(set) var helperRegistrationStatus:
        DummyEthernetHelperRegistrationStatus
    @Published private(set) var runtimeState: DummyEthernetNetworkState?
    @Published private(set) var operation: DummyEthernetOperation?

    @Published var configurationInput: DummyEthernetConfiguration {
        didSet {
            configurationValidationResult = Self.validationResult(
                for: configurationInput
            )
            defaults.set(
                configurationInput.hostIPv4Address,
                forKey: DefaultsKey.hostIPv4Address
            )
            defaults.set(
                configurationInput.memberInterfaceName,
                forKey: DefaultsKey.memberInterfaceName
            )
            defaults.set(
                configurationInput.peerInterfaceName,
                forKey: DefaultsKey.peerInterfaceName
            )
        }
    }

    private let helperRegistration: DummyEthernetPrivilegedHelperRegistrationService
    private let networkManager: DummyEthernetPrivilegedHelperClient
    private let eventLog: EventLogStore
    private let defaults: UserDefaults
    private var configurationValidationResult:
        Result<DummyEthernetConfiguration, Error>

    init(eventLog: EventLogStore) {
        let defaults = UserDefaults.standard
        let configurationInput = DummyEthernetConfiguration(
            hostIPv4Address: defaults.string(
                forKey: DefaultsKey.hostIPv4Address
            ) ?? ThruRNDISDummyEthernet.defaultHostIPv4Address,
            memberInterfaceName: defaults.string(
                forKey: DefaultsKey.memberInterfaceName
            ) ?? ThruRNDISDummyEthernet.defaultMemberInterfaceName,
            peerInterfaceName: defaults.string(
                forKey: DefaultsKey.peerInterfaceName
            ) ?? ThruRNDISDummyEthernet.defaultPeerInterfaceName
        )

        helperRegistration = DummyEthernetPrivilegedHelperRegistrationService()
        networkManager = DummyEthernetPrivilegedHelperClient()
        self.eventLog = eventLog
        self.defaults = defaults
        isSignedBuild = PeerCodeSigningRequirementBuilder
            .currentProcessHasTeamIdentifier
        helperRegistrationStatus = helperRegistration.status()
        runtimeState = nil
        operation = nil
        self.configurationInput = configurationInput
        configurationValidationResult = Self.validationResult(
            for: configurationInput
        )
    }

    var isOperationInProgress: Bool {
        operation != nil
    }

    var helperStatusOperation: DummyEthernetOperation? {
        guard operation?.statusSection == .privilegedHelper else { return nil }
        return operation
    }

    var networkStatusOperation: DummyEthernetOperation? {
        guard operation?.statusSection == .dummyEthernet else { return nil }
        return operation
    }

    var validatedConfiguration: DummyEthernetConfiguration? {
        try? configurationValidationResult.get()
    }

    var configurationErrorMessage: String? {
        guard case .failure(let error) = configurationValidationResult else {
            return nil
        }
        return error.localizedDescription
    }

    var canEnableHelper: Bool {
        guard !isOperationInProgress else { return false }
        switch helperRegistrationStatus {
        case .unknown, .notRegistered, .notFound:
            return true
        case .enabled, .updateRequired, .requiresApproval:
            return false
        }
    }

    var canReinstallHelper: Bool {
        guard !isOperationInProgress else { return false }
        switch helperRegistrationStatus {
        case .enabled:
            return runtimeState == nil || runtimeState == .inactive
        case .updateRequired:
            return true
        case .unknown, .notRegistered, .requiresApproval, .notFound:
            return false
        }
    }

    var isReinstallActionPresented: Bool {
        switch helperRegistrationStatus {
        case .enabled, .updateRequired:
            return true
        case .unknown, .notRegistered, .requiresApproval, .notFound:
            return operation == .reinstallingHelper
        }
    }

    var canDisableHelper: Bool {
        guard !isOperationInProgress else { return false }
        switch helperRegistrationStatus {
        case .enabled:
            return runtimeState == nil || runtimeState == .inactive
        case .updateRequired, .requiresApproval:
            return true
        case .unknown, .notRegistered, .notFound:
            return false
        }
    }

    var canStart: Bool {
        helperIsAvailable
            && !isOperationInProgress
            && validatedConfiguration != nil
            && (runtimeState == nil || runtimeState == .inactive)
    }

    var canRestart: Bool {
        helperIsAvailable
            && !isOperationInProgress
            && validatedConfiguration != nil
            && hasManagedConfiguration
    }

    var isRestartActionPresented: Bool {
        hasManagedConfiguration || operation == .restarting
    }

    var canStop: Bool {
        helperIsAvailable
            && !isOperationInProgress
            && runtimeState != nil
            && runtimeState != .inactive
    }

    var canEditConfiguration: Bool {
        !isOperationInProgress
            && (runtimeState == nil || runtimeState == .inactive)
    }

    func enableHelper() {
        guard !isOperationInProgress else { return }
        operation = .installingHelper
        appendEventLog(
            "Dummy Ethernet helper enable requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.helperRegistrationStatus = try self
                    .helperRegistration.enable()
                self.operation = nil

                switch self.helperRegistrationStatus {
                case .enabled:
                    self.appendEventLog(
                        "Dummy Ethernet privileged helper is enabled for the current app build.",
                        level: .info
                    )
                    self.refresh()
                case .requiresApproval:
                    self.appendEventLog(
                        "Dummy Ethernet privileged helper requires user approval.",
                        level: .warning
                    )
                default:
                    self.reportError(
                        "Dummy Ethernet helper registration did not become enabled."
                    )
                }
            } catch {
                self.operation = nil
                self.refreshHelperRegistrationState()
                if self.helperRegistrationStatus == .requiresApproval {
                    return
                }
                self.reportError(
                    "Could not enable the Dummy Ethernet helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func disableHelper() {
        guard canDisableHelper else { return }
        operation = .removingHelper
        appendEventLog(
            "Dummy Ethernet helper disable requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.helperRegistrationStatus = try await self
                    .helperRegistration.disable()
                self.operation = nil

                switch self.helperRegistrationStatus {
                case .notRegistered, .notFound:
                    self.runtimeState = nil
                    self.appendEventLog(
                        "Dummy Ethernet privileged helper is disabled.",
                        level: .info
                    )
                default:
                    self.reportError(
                        "Dummy Ethernet helper registration did not become disabled."
                    )
                }
            } catch {
                self.operation = nil
                self.refreshHelperRegistrationState()
                self.reportError(
                    "Could not disable the Dummy Ethernet helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func reinstallHelper() {
        guard canReinstallHelper else { return }
        operation = .reinstallingHelper
        appendEventLog(
            "Dummy Ethernet helper reinstall requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let removalStatus = try await self.helperRegistration.disable()
                self.helperRegistrationStatus = removalStatus
                self.runtimeState = nil

                guard removalStatus == .notRegistered
                    || removalStatus == .notFound else {
                    self.operation = nil
                    self.reportError(
                        "Dummy Ethernet helper registration did not become disabled for reinstall."
                    )
                    return
                }

                // ServiceManagement can reject an immediate registration even
                // after its asynchronous unregister completion has returned.
                try await Task.sleep(
                    for: Self.helperReregistrationDelay
                )
                self.helperRegistrationStatus = try self
                    .helperRegistration.enable()
                self.operation = nil

                switch self.helperRegistrationStatus {
                case .enabled:
                    self.appendEventLog(
                        "Dummy Ethernet privileged helper was reinstalled for the current app build.",
                        level: .info
                    )
                    self.refresh()
                case .requiresApproval:
                    self.appendEventLog(
                        "Dummy Ethernet privileged helper requires user approval after reinstall.",
                        level: .warning
                    )
                default:
                    self.reportError(
                        "Dummy Ethernet helper registration did not become enabled after reinstall."
                    )
                }
            } catch {
                self.operation = nil
                self.refreshHelperRegistrationState()
                if self.helperRegistrationStatus == .requiresApproval {
                    return
                }
                self.reportError(
                    "Could not reinstall the Dummy Ethernet helper: \(error.localizedDescription)"
                )
            }
        }
    }

    func openLoginItemsSettings() {
        helperRegistration.openSystemSettings()
        appendEventLog(
            "Opened Login Items settings for Dummy Ethernet helper approval.",
            level: .debug
        )
    }

    func refresh() {
        guard !isOperationInProgress else { return }
        refreshHelperRegistrationState()
        guard helperIsAvailable else {
            runtimeState = nil
            appendEventLog(
                "Dummy Ethernet refresh skipped: helper registration is unavailable or outdated.",
                level: .debug
            )
            return
        }

        performNetworkOperation(.refreshing) { manager in
            try await manager.status()
        }
    }

    func start() {
        guard !isOperationInProgress else { return }
        Task { @MainActor [weak self] in
            _ = await self?.startAndWaitUntilActive()
        }
    }

    @discardableResult
    func startAndWaitUntilActive() async -> Bool {
        guard await waitUntilCurrentOperationFinishes() else { return false }

        guard runtimeState != .active else { return true }
        refreshHelperRegistrationState()
        guard helperIsAvailable else {
            reportError("Dummy Ethernet start failed: helper unavailable.")
            return false
        }
        guard let configuration = validatedConfiguration else {
            let message = configurationErrorMessage
                ?? String(localized: "Enter a valid Dummy Ethernet configuration.")
            reportError("Dummy Ethernet start failed: \(message)")
            return false
        }

        operation = .starting
        appendEventLog(
            "Dummy Ethernet start requested.",
            level: .debug
        )
        defer { operation = nil }

        do {
            let snapshot = try await networkManager.start(
                configuration: configuration
            )
            applySnapshot(snapshot)
            appendCompletionEvent(for: .starting, snapshot: snapshot)
            return snapshot.state == .active
        } catch {
            reportError(
                "Dummy Ethernet start failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    func stopAfterCurrentOperation() {
        Task { @MainActor [weak self] in
            guard let self,
                  await self.waitUntilCurrentOperationFinishes() else {
                return
            }
            self.stop()
        }
    }

    func stop() {
        guard !isOperationInProgress else { return }
        refreshHelperRegistrationState()
        guard helperIsAvailable else {
            reportError("Dummy Ethernet stop failed: helper unavailable.")
            return
        }

        performNetworkOperation(.stopping) { manager in
            try await manager.stop()
        }
    }

    func restart() {
        guard canRestart else { return }
        refreshHelperRegistrationState()
        guard helperIsAvailable else {
            reportError("Dummy Ethernet restart failed: helper unavailable.")
            return
        }
        guard let configuration = validatedConfiguration else {
            let message = configurationErrorMessage
                ?? String(localized: "Enter a valid Dummy Ethernet configuration.")
            reportError("Dummy Ethernet restart failed: \(message)")
            return
        }

        operation = .restarting
        appendEventLog(
            "Dummy Ethernet restart requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            do {
                let stoppedSnapshot = try await self.networkManager.stop()
                self.applySnapshot(stoppedSnapshot)

                let restartedSnapshot = try await self.networkManager.start(
                    configuration: configuration
                )
                self.applySnapshot(restartedSnapshot)
                self.appendCompletionEvent(
                    for: .restarting,
                    snapshot: restartedSnapshot
                )
            } catch {
                self.reportError(
                    "Dummy Ethernet restart failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func resetForAppSettings() async throws {
        guard !isOperationInProgress else {
            throw DummyEthernetSettingsResetError.operationInProgress
        }

        refreshHelperRegistrationState()
        defer { operation = nil }

        switch helperRegistrationStatus {
        case .enabled:
            operation = .stopping
            appendEventLog(
                "Dummy Ethernet stop requested for app settings reset.",
                level: .debug
            )

            let snapshot: DummyEthernetNetworkSnapshot
            do {
                snapshot = try await networkManager.stop()
            } catch {
                let resetError = DummyEthernetSettingsResetError
                    .stopFailed(error.localizedDescription)
                reportError(resetError.localizedDescription)
                throw resetError
            }
            applySnapshot(snapshot)
            guard snapshot.state == .inactive else {
                let resetError = DummyEthernetSettingsResetError
                    .stopIncomplete
                reportError(resetError.localizedDescription)
                throw resetError
            }
            appendCompletionEvent(for: .stopping, snapshot: snapshot)

        case .updateRequired:
            let resetError = DummyEthernetSettingsResetError
                .helperUpdateRequired
            reportError(resetError.localizedDescription)
            throw resetError

        case .unknown:
            let resetError = DummyEthernetSettingsResetError
                .helperStatusUnavailable
            reportError(resetError.localizedDescription)
            throw resetError

        case .notRegistered, .notFound:
            runtimeState = nil

        case .requiresApproval:
            break
        }

        operation = .removingHelper
        appendEventLog(
            "Dummy Ethernet helper removal requested for app settings reset.",
            level: .debug
        )

        let removalStatus: DummyEthernetHelperRegistrationStatus
        do {
            removalStatus = try await helperRegistration.disable()
        } catch {
            refreshHelperRegistrationState()
            let resetError = DummyEthernetSettingsResetError
                .helperRemovalFailed(error.localizedDescription)
            reportError(resetError.localizedDescription)
            throw resetError
        }
        helperRegistrationStatus = removalStatus
        guard removalStatus == .notRegistered || removalStatus == .notFound else {
            let resetError = DummyEthernetSettingsResetError
                .helperRemovalIncomplete
            reportError(resetError.localizedDescription)
            throw resetError
        }

        runtimeState = nil
        resetPersistedInput()
        appendEventLog(
            "Dummy Ethernet configuration and privileged helper were removed for app settings reset.",
            level: .info
        )
    }

    private func resetPersistedInput() {
        configurationInput = DummyEthernetConfiguration(
            hostIPv4Address: ThruRNDISDummyEthernet.defaultHostIPv4Address,
            memberInterfaceName:
                ThruRNDISDummyEthernet.defaultMemberInterfaceName,
            peerInterfaceName:
                ThruRNDISDummyEthernet.defaultPeerInterfaceName
        )
        defaults.removeObject(forKey: DefaultsKey.hostIPv4Address)
        defaults.removeObject(forKey: DefaultsKey.memberInterfaceName)
        defaults.removeObject(forKey: DefaultsKey.peerInterfaceName)
        appendEventLog(
            "Reset the Dummy Ethernet inputs to defaults.",
            level: .debug
        )
    }

    private func performNetworkOperation(
        _ nextOperation: DummyEthernetOperation,
        action: @escaping @MainActor (
            DummyEthernetPrivilegedHelperClient
        ) async throws -> DummyEthernetNetworkSnapshot
    ) {
        operation = nextOperation
        appendEventLog(
            "Dummy Ethernet \(nextOperation.rawValue) requested.",
            level: .debug
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            do {
                let snapshot = try await action(self.networkManager)
                self.applySnapshot(snapshot)
                self.appendCompletionEvent(
                    for: nextOperation,
                    snapshot: snapshot
                )
            } catch {
                self.reportError(
                    "Dummy Ethernet \(nextOperation.rawValue) failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func waitUntilCurrentOperationFinishes() async -> Bool {
        while isOperationInProgress {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return true
    }

    private func appendCompletionEvent(
        for completedOperation: DummyEthernetOperation,
        snapshot: DummyEthernetNetworkSnapshot
    ) {
        appendEventLog(
            "Dummy Ethernet \(completedOperation.rawValue) completed: "
                + "state=\(snapshot.state.rawValue), "
                + "bond=\(snapshot.bondInterfaceName ?? "none"), "
                + "member=\(snapshot.memberInterfaceName ?? "none"), "
                + "peer=\(snapshot.peerInterfaceName ?? "none"), "
                + "ipv4=\(snapshot.configuredIPv4Address ?? "none").",
            level: snapshot.state == .degraded ? .warning : .info
        )
    }

    private func applySnapshot(_ snapshot: DummyEthernetNetworkSnapshot) {
        runtimeState = snapshot.state
        if snapshot.state != .inactive {
            configurationInput = DummyEthernetConfiguration(
                hostIPv4Address: snapshot.configuredIPv4Address
                    ?? configurationInput.hostIPv4Address,
                memberInterfaceName: snapshot.memberInterfaceName
                    ?? configurationInput.memberInterfaceName,
                peerInterfaceName: snapshot.peerInterfaceName
                    ?? configurationInput.peerInterfaceName
            )
        }
    }

    private func refreshHelperRegistrationState() {
        helperRegistrationStatus = helperRegistration.status()
    }

    private var helperIsAvailable: Bool {
        helperRegistrationStatus == .enabled
    }

    private var hasManagedConfiguration: Bool {
        runtimeState != nil && runtimeState != .inactive
    }

    private func reportError(_ message: String) {
        appendEventLog(message, level: .error)
    }

    private static func validationResult(
        for configuration: DummyEthernetConfiguration
    ) -> Result<DummyEthernetConfiguration, Error> {
        Result {
            try DummyEthernetConfigurationValidator.validate(configuration)
        }
    }

    private func appendEventLog(
        _ message: String,
        level: EventLogLevel
    ) {
        eventLog.append(message, level: level, category: .dummyEthernet)
    }

    private enum DefaultsKey {
        static let hostIPv4Address = "DummyEthernet.hostIPv4Address"
        static let memberInterfaceName = "DummyEthernet.memberInterfaceName"
        static let peerInterfaceName = "DummyEthernet.peerInterfaceName"
    }
}

private enum DummyEthernetSettingsResetError: LocalizedError {
    case operationInProgress
    case helperUpdateRequired
    case helperStatusUnavailable
    case stopFailed(String)
    case stopIncomplete
    case helperRemovalFailed(String)
    case helperRemovalIncomplete

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            String(
                localized: "Wait for the current Dummy Ethernet operation to finish."
            )
        case .helperUpdateRequired:
            String(
                localized: "Reinstall the Dummy Ethernet privileged helper before resetting app settings."
            )
        case .helperStatusUnavailable:
            String(
                localized: "Refresh the helper status before managing Dummy Ethernet."
            )
        case .stopFailed(let detail):
            String(
                localized: "Could not stop Dummy Ethernet while resetting app settings: \(detail)"
            )
        case .stopIncomplete:
            String(
                localized: "Dummy Ethernet did not stop while resetting app settings."
            )
        case .helperRemovalFailed(let detail):
            String(
                localized: "Could not remove the Dummy Ethernet privileged helper while resetting app settings: \(detail)"
            )
        case .helperRemovalIncomplete:
            String(
                localized: "The Dummy Ethernet privileged helper remained registered during the settings reset."
            )
        }
    }
}
