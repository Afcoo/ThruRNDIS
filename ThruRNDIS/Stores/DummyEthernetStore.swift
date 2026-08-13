/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

enum DummyEthernetOperation: String, Equatable {
    case refreshing = "refresh"
    case starting = "start"
    case restarting = "restart"
    case stopping = "stop"

    var title: String {
        switch self {
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
}

@MainActor
final class DummyEthernetStore: ObservableObject {
    private static let applicationTerminationCleanupTimeout:
        DispatchTimeInterval = .seconds(5)

    let helper: DummyEthernetHelperStore

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

    private let networkManager: DummyEthernetPrivilegedHelperClient
    private let eventLog: EventLogStore
    private let defaults: UserDefaults
    private var configurationValidationResult:
        Result<DummyEthernetConfiguration, Error>
    private var helperStatusCancellable: AnyCancellable?

    init(
        eventLog: EventLogStore,
        helper: DummyEthernetHelperStore? = nil
    ) {
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

        let helper = helper ?? DummyEthernetHelperStore(eventLog: eventLog)
        self.helper = helper
        networkManager = DummyEthernetPrivilegedHelperClient()
        self.eventLog = eventLog
        self.defaults = defaults
        runtimeState = nil
        operation = nil
        self.configurationInput = configurationInput
        configurationValidationResult = Self.validationResult(
            for: configurationInput
        )

        helperStatusCancellable = helper.$registrationStatus
            .dropFirst()
            .sink { [weak self] status in
                guard status == .enabled else {
                    self?.runtimeState = nil
                    return
                }
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.refresh()
                }
            }
    }

    var isOperationInProgress: Bool {
        operation != nil
    }

    var isAnyOperationInProgress: Bool {
        isOperationInProgress || helper.isOperationInProgress
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
        !isOperationInProgress && helper.canEnable
    }

    var canReinstallHelper: Bool {
        !isOperationInProgress
            && helper.canReinstall
            && (runtimeState == nil || runtimeState == .inactive)
    }

    var canDisableHelper: Bool {
        !isOperationInProgress
            && helper.canDisable
            && (runtimeState == nil || runtimeState == .inactive)
    }

    var canStart: Bool {
        helper.isAvailable
            && !isAnyOperationInProgress
            && validatedConfiguration != nil
            && (runtimeState == nil || runtimeState == .inactive)
    }

    var canRestart: Bool {
        helper.isAvailable
            && !isAnyOperationInProgress
            && validatedConfiguration != nil
            && hasManagedConfiguration
    }

    var isRestartActionPresented: Bool {
        hasManagedConfiguration || operation == .restarting
    }

    var canStop: Bool {
        helper.isAvailable
            && !isAnyOperationInProgress
            && runtimeState != nil
            && runtimeState != .inactive
    }

    var canEditConfiguration: Bool {
        !isAnyOperationInProgress
            && (runtimeState == nil || runtimeState == .inactive)
    }

    func disableHelper() {
        guard canDisableHelper else { return }
        helper.disable()
    }

    func reinstallHelper() {
        guard canReinstallHelper else { return }
        helper.reinstall()
    }

    func refresh() {
        guard !isAnyOperationInProgress else { return }
        helper.refresh()
        guard helper.isAvailable else {
            runtimeState = nil
            appendEventLog(
                "Dummy Ethernet refresh skipped: Dummy Ethernet helper registration is unavailable or outdated.",
                level: .debug
            )
            return
        }

        performNetworkOperation(.refreshing) { manager in
            try await manager.status()
        }
    }

    func start() {
        guard canStart else { return }
        Task { @MainActor [weak self] in
            _ = await self?.startAndWaitUntilActive()
        }
    }

    @discardableResult
    func startAndWaitUntilActive() async -> Bool {
        guard !Task.isCancelled,
              await waitUntilCurrentOperationFinishes(),
              !Task.isCancelled else {
            return false
        }

        let shouldRestart = runtimeState == .degraded
        let nextOperation: DummyEthernetOperation = shouldRestart
            ? .restarting
            : .starting
        guard let configuration = configuration(for: nextOperation) else {
            return false
        }

        if shouldRestart {
            return await restartAndWaitUntilActive(
                configuration: configuration
            )
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
            return !Task.isCancelled && snapshot.state == .active
        } catch {
            reportError(
                "Dummy Ethernet start failed: \(Self.diagnosticDescription(for: error))"
            )
            return false
        }
    }

    @discardableResult
    func stopAfterCurrentOperation() async -> Bool {
        guard await waitUntilCurrentOperationFinishes(),
              !Task.isCancelled else {
            return false
        }

        return await stopManagedConfiguration(
            requestMessage: "Dummy Ethernet stop requested.",
            stopRequest: networkManager.stop
        )
    }

    @discardableResult
    func stopForApplicationTerminationIfNeeded() async -> Bool {
        let terminationDeadline = DispatchTime.now()
            + Self.applicationTerminationCleanupTimeout
        guard await waitUntilCurrentOperationFinishes(
            before: terminationDeadline
        ) else {
            if !Task.isCancelled {
                reportError(
                    "Dummy Ethernet application termination cleanup timed out while waiting for the current operation to finish."
                )
            }
            return false
        }
        guard !Task.isCancelled else {
            return false
        }

        let hadManagedConfiguration = hasManagedConfiguration
        helper.refresh()
        guard helper.isAvailable else {
            guard hadManagedConfiguration else {
                return true
            }
            reportError(
                "Dummy Ethernet could not be stopped for application termination: the Dummy Ethernet helper is unavailable."
            )
            return false
        }
        guard runtimeState != .inactive else {
            return true
        }

        return await stopManagedConfiguration(
            requestMessage: "Dummy Ethernet stop requested for application termination.",
            stopRequest: {
                try await networkManager.stopAndWaitUntilFinished(
                    before: terminationDeadline
                )
            }
        )
    }

    private func stopManagedConfiguration(
        requestMessage: String,
        stopRequest: @MainActor () async throws
            -> DummyEthernetNetworkSnapshot
    ) async -> Bool {
        helper.refresh()
        guard helper.isAvailable else {
            reportError("Dummy Ethernet stop failed: the Dummy Ethernet helper is unavailable.")
            return false
        }

        operation = .stopping
        appendEventLog(requestMessage, level: .debug)
        defer { operation = nil }

        do {
            let snapshot = try await stopRequest()
            applySnapshot(snapshot)
            appendCompletionEvent(for: .stopping, snapshot: snapshot)
            guard snapshot.state == .inactive else {
                reportError(
                    "Dummy Ethernet stop failed: the managed configuration remained active or degraded."
                )
                return false
            }
            return true
        } catch {
            reportError(
                "Dummy Ethernet stop failed: \(Self.diagnosticDescription(for: error))"
            )
            return false
        }
    }

    func stop() {
        guard canStop else { return }

        performNetworkOperation(.stopping) { manager in
            try await manager.stop()
        }
    }

    func restart() {
        guard canRestart else { return }
        guard let configuration = configuration(for: .restarting) else {
            return
        }
        beginRestartOperation()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            _ = await self.performRestartAndWaitUntilActive(
                configuration: configuration
            )
        }
    }

    func resetForAppSettings() async throws {
        guard !isAnyOperationInProgress else {
            throw DummyEthernetSettingsResetError.operationInProgress
        }

        helper.refresh()
        defer { operation = nil }

        switch helper.registrationStatus {
        case .enabled:
            operation = .stopping
            appendEventLog(
                "Dummy Ethernet stop requested for app settings reset.",
                level: .debug
            )

            let snapshot: DummyEthernetNetworkSnapshot
            do {
                snapshot = try await networkManager
                    .stopAndWaitUntilFinished()
            } catch {
                let resetError = DummyEthernetSettingsResetError
                    .stopFailed(error.localizedDescription)
                reportError(
                    "Dummy Ethernet settings reset failed while stopping: \(Self.diagnosticDescription(for: error))"
                )
                throw resetError
            }
            applySnapshot(snapshot)
            guard snapshot.state == .inactive else {
                let resetError = DummyEthernetSettingsResetError
                    .stopIncomplete
                reportError(
                    "Dummy Ethernet settings reset failed: the managed configuration remained active or degraded."
                )
                throw resetError
            }
            appendCompletionEvent(for: .stopping, snapshot: snapshot)

        case .updateRequired:
            let resetError = DummyEthernetSettingsResetError
                .helperUpdateRequired
            reportError(
                "Dummy Ethernet settings reset failed: the helper requires reinstallation."
            )
            throw resetError

        case .unknown:
            let resetError = DummyEthernetSettingsResetError
                .helperStatusUnavailable
            reportError(
                "Dummy Ethernet settings reset failed: the helper registration status is unavailable."
            )
            throw resetError

        case .notRegistered, .notFound:
            runtimeState = nil

        case .requiresApproval:
            break
        }

        let removalStatus: DummyEthernetHelperRegistrationStatus
        do {
            removalStatus = try await helper.removeForAppSettings()
        } catch {
            let resetError = DummyEthernetSettingsResetError
                .helperRemovalFailed(error.localizedDescription)
            reportError(
                "Dummy Ethernet settings reset failed while removing the helper: \(Self.diagnosticDescription(for: error))"
            )
            throw resetError
        }
        guard removalStatus == .notRegistered || removalStatus == .notFound else {
            let resetError = DummyEthernetSettingsResetError
                .helperRemovalIncomplete
            reportError(
                "Dummy Ethernet settings reset failed: the helper remained registered."
            )
            throw resetError
        }

        runtimeState = nil
        resetPersistedInput()
        appendEventLog(
            "Dummy Ethernet configuration and Dummy Ethernet helper were removed for app settings reset.",
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
                    "Dummy Ethernet \(nextOperation.rawValue) failed: \(Self.diagnosticDescription(for: error))"
                )
            }
        }
    }

    private func waitUntilCurrentOperationFinishes(
        before deadline: DispatchTime? = nil
    ) async -> Bool {
        while isAnyOperationInProgress {
            let sleepDuration: Duration
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else {
                    return false
                }
                sleepDuration = .nanoseconds(
                    Int64(min(deadline.uptimeNanoseconds - now, 50_000_000))
                )
            } else {
                sleepDuration = .milliseconds(50)
            }
            do {
                try await Task.sleep(for: sleepDuration)
            } catch {
                return false
            }
        }
        guard let deadline else { return true }
        return DispatchTime.now().uptimeNanoseconds
            < deadline.uptimeNanoseconds
    }

    private func configuration(
        for operation: DummyEthernetOperation
    ) -> DummyEthernetConfiguration? {
        helper.refresh()
        guard helper.isAvailable else {
            reportError(
                "Dummy Ethernet \(operation.rawValue) failed: the Dummy Ethernet helper is unavailable."
            )
            return nil
        }
        guard let configuration = validatedConfiguration else {
            let message = configurationErrorMessage
                ?? String(localized: "Enter a valid Dummy Ethernet configuration.")
            reportError(
                "Dummy Ethernet \(operation.rawValue) failed: \(message)"
            )
            return nil
        }
        return configuration
    }

    private func restartAndWaitUntilActive(
        configuration: DummyEthernetConfiguration
    ) async -> Bool {
        beginRestartOperation()
        defer { operation = nil }
        return await performRestartAndWaitUntilActive(
            configuration: configuration
        )
    }

    private func beginRestartOperation() {
        operation = .restarting
        appendEventLog(
            "Dummy Ethernet restart requested.",
            level: .debug
        )
    }

    private func performRestartAndWaitUntilActive(
        configuration: DummyEthernetConfiguration
    ) async -> Bool {
        do {
            let stoppedSnapshot = try await networkManager.stop()
            applySnapshot(stoppedSnapshot)
            guard !Task.isCancelled else { return false }
            guard stoppedSnapshot.state == .inactive else {
                reportError(
                    "Dummy Ethernet restart failed: the managed configuration remained active or degraded after stopping."
                )
                return false
            }

            let restartedSnapshot = try await networkManager.start(
                configuration: configuration
            )
            applySnapshot(restartedSnapshot)
            appendCompletionEvent(
                for: .restarting,
                snapshot: restartedSnapshot
            )
            return !Task.isCancelled && restartedSnapshot.state == .active
        } catch {
            reportError(
                "Dummy Ethernet restart failed: \(Self.diagnosticDescription(for: error))"
            )
            return false
        }
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

    private var hasManagedConfiguration: Bool {
        runtimeState != nil && runtimeState != .inactive
    }

    private func reportError(_ message: String) {
        appendEventLog(message, level: .error)
    }

    private static func diagnosticDescription(for error: Error) -> String {
        if let error = error as? DummyEthernetPrivilegedHelperClientError {
            return error.diagnosticDescription
        }

        let nsError = error as NSError
        return "domain=\(nsError.domain), code=\(nsError.code)"
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

enum DummyEthernetSettingsResetError: LocalizedError {
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
                localized: "Reinstall the Dummy Ethernet helper before resetting app settings."
            )
        case .helperStatusUnavailable:
            String(
                localized: "Refresh the Dummy Ethernet helper status before managing Dummy Ethernet."
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
                localized: "Could not remove the Dummy Ethernet helper while resetting app settings: \(detail)"
            )
        case .helperRemovalIncomplete:
            String(
                localized: "The Dummy Ethernet helper remained registered during the settings reset."
            )
        }
    }
}
