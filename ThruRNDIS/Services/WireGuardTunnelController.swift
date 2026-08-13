/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
@preconcurrency import NetworkExtension

private struct ConnectionObservationContext: Equatable {
    let operationID: UUID
    let ignoresDisconnectError: Bool
}

@MainActor
final class WireGuardTunnelController {
    private static let applicationTerminationStopTimeout =
        Duration.seconds(5)

    var onStatusChange: ((WireGuardTunnelStatus) -> Void)?
    var onFailureChange: ((WireGuardTunnelFailure?) -> Void)?
    var onSystemExtensionStatusChange: ((WireGuardSystemExtensionStatus) -> Void)?
    var onEventLog: EventLogHandler?

    private let systemExtensionActivator: WireGuardSystemExtensionActivator
    private var vpnStatusObserverToken: NSObjectProtocol?
    private var activeOperationID = UUID()
    private var currentStatus: WireGuardTunnelStatus = .unconfigured
    private var activeSystemExtensionOperationID = UUID()
    private var currentSystemExtensionStatus: WireGuardSystemExtensionStatus = .notChecked
    private var isSystemExtensionActivationInProgress = false
    private var areSystemExtensionOperationsInvalidated = false
    private var cachedManager: NETunnelProviderManager?
    private var connectionObservationContexts: [
        ObjectIdentifier: ConnectionObservationContext
    ] = [:]

    init(
        systemExtensionActivator: WireGuardSystemExtensionActivator
    ) {
        self.systemExtensionActivator = systemExtensionActivator
        vpnStatusObserverToken = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let session = notification.object as? NETunnelProviderSession,
                  let manager = session.manager as? NETunnelProviderManager else {
                return
            }
            let status = session.status
            let context = MainActor.assumeIsolated { [weak self] in
                self?.connectionObservationContexts[ObjectIdentifier(session)]
            }
            guard let context else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.isThruRNDISManager(manager) else {
                    return
                }
                await self.updateStatus(
                    from: status,
                    connection: session,
                    context: context
                )
            }
        }
    }

    deinit {
        if let vpnStatusObserverToken {
            NotificationCenter.default.removeObserver(vpnStatusObserverToken)
        }
    }

    func refreshSystemExtensionStatus() async {
        guard !Task.isCancelled, !areSystemExtensionOperationsInvalidated else {
            return
        }
        guard !isSystemExtensionActivationInProgress else {
            reportEventLog(
                "Skipped network extension status refresh during activation.",
                level: .debug
            )
            return
        }

        let operationID = beginSystemExtensionOperation()
        do {
            let bundleIdentifier = try systemExtensionBundleIdentifier()
            systemExtensionActivator.onEventLog = onEventLog
            let status = try await systemExtensionActivator.status(
                bundleIdentifier: bundleIdentifier
            )
            try Task.checkCancellation()
            guard !areSystemExtensionOperationsInvalidated,
                  activeSystemExtensionOperationID == operationID else {
                return
            }
            setSystemExtensionStatus(status)
        } catch is CancellationError {
            return
        } catch {
            guard activeSystemExtensionOperationID == operationID else {
                return
            }
            failSystemExtension(action: "status refresh", error: error)
        }
    }

    func activateSystemExtension() async {
        guard !Task.isCancelled, !areSystemExtensionOperationsInvalidated else {
            return
        }
        guard !isSystemExtensionActivationInProgress else {
            reportEventLog(
                "Ignored a duplicate network extension activation request.",
                level: .debug
            )
            return
        }

        isSystemExtensionActivationInProgress = true
        defer { isSystemExtensionActivationInProgress = false }

        let operationID = beginSystemExtensionOperation()
        do {
            let bundleIdentifier = try systemExtensionBundleIdentifier()
            let verifiedStatus = try await activateAndVerifySystemExtensionStatus(
                bundleIdentifier: bundleIdentifier,
                operationID: operationID
            )
            setSystemExtensionStatus(verifiedStatus)
            if !verifiedStatus.isActive {
                reportEventLog(
                    "Network extension activation failed; verified status: " +
                        "\(verifiedStatus.eventLogDescription)",
                    level: .error
                )
            }
        } catch is CancellationError {
            return
        } catch WireGuardTunnelError.operationSuperseded {
            return
        } catch WireGuardSystemExtensionActivationError.restartRequired {
            guard activeSystemExtensionOperationID == operationID else {
                return
            }
            setSystemExtensionStatus(.inactive(.restartRequired(.activation)))
            reportEventLog(
                "Network extension activation requires a macOS restart.",
                level: .warning
            )
        } catch {
            guard activeSystemExtensionOperationID == operationID else {
                return
            }
            failSystemExtension(action: "activation", error: error)
        }
    }

    func invalidateSystemExtensionOperations() {
        areSystemExtensionOperationsInvalidated = true
        cancelPendingSystemExtensionOperations()
    }

    func cancelPendingSystemExtensionOperations() {
        _ = beginSystemExtensionOperation()
        systemExtensionActivator.cancelPendingRequests()
    }

    func refreshStatus(allowDuringTransition: Bool = false) async {
        guard allowDuringTransition || !currentStatus.isTransitioning else {
            reportEventLog(
                "Ignored WireGuard status refresh during a tunnel transition.",
                level: .debug
            )
            return
        }
        let operationID = beginOperation()
        do {
            if let manager = try await loadThruRNDISManager(
                operationID: operationID
            ) {
                let context = trackConnection(
                    manager.connection,
                    operationID: operationID,
                    ignoresDisconnectError: false
                )
                await updateStatus(
                    from: manager.connection.status,
                    connection: manager.connection,
                    context: context
                )
            } else {
                try ensureOperationIsCurrent(operationID)
                setStatus(.unconfigured)
            }
        } catch is CancellationError {
            return
        } catch WireGuardTunnelError.operationSuperseded {
            return
        } catch {
            guard activeOperationID == operationID else { return }
            fail(action: "status refresh", error: error)
        }
    }

    func connect(configuration: WireGuardConnectionConfiguration) async {
        let statusBeforeOperation = currentStatus
        let operationID = beginOperation()
        do {
            try Task.checkCancellation()
            let configurationEncoder = PropertyListEncoder()
            configurationEncoder.outputFormat = .binary
            let configurationData = try configurationEncoder.encode(configuration)
            let extensionBundleIdentifier = try systemExtensionBundleIdentifier()
            guard !areSystemExtensionOperationsInvalidated else {
                throw CancellationError()
            }
            setStatus(.connecting)
            do {
                guard !isSystemExtensionActivationInProgress else {
                    throw WireGuardSystemExtensionActivationError.activationAlreadyInProgress
                }

                isSystemExtensionActivationInProgress = true
                defer { isSystemExtensionActivationInProgress = false }

                let systemExtensionOperationID = beginSystemExtensionOperation()
                do {
                    let verifiedStatus = try await activateAndVerifySystemExtensionStatus(
                        bundleIdentifier: extensionBundleIdentifier,
                        operationID: systemExtensionOperationID
                    )
                    setSystemExtensionStatus(verifiedStatus)
                    guard verifiedStatus.isActive else {
                        throw WireGuardSystemExtensionActivationError.extensionRemainsDisabled
                    }
                } catch let error as CancellationError {
                    scheduleSystemExtensionStatusReconciliation(
                        after: systemExtensionOperationID
                    )
                    throw error
                } catch WireGuardSystemExtensionActivationError.restartRequired {
                    guard !areSystemExtensionOperationsInvalidated,
                          activeSystemExtensionOperationID == systemExtensionOperationID else {
                        throw WireGuardTunnelError.operationSuperseded
                    }
                    setSystemExtensionStatus(.inactive(.restartRequired(.activation)))
                    throw WireGuardSystemExtensionActivationError.restartRequired
                } catch WireGuardSystemExtensionActivationError.extensionRemainsDisabled {
                    throw WireGuardSystemExtensionActivationError.extensionRemainsDisabled
                } catch WireGuardTunnelError.operationSuperseded {
                    throw WireGuardTunnelError.operationSuperseded
                } catch {
                    guard !areSystemExtensionOperationsInvalidated,
                          activeSystemExtensionOperationID == systemExtensionOperationID else {
                        throw WireGuardTunnelError.operationSuperseded
                    }
                    setSystemExtensionStatus(
                        .unknown(Self.diagnosticDescription(for: error))
                    )
                    throw error
                }
            }
            try ensureOperationIsCurrent(operationID)

            let manager = try await configureAndSaveTunnelManager(
                connectionConfiguration: configuration,
                operationID: operationID
            )
            try await startTunnel(
                manager: manager,
                configurationData: configurationData,
                operationID: operationID
            )
            reportEventLog(
                "WireGuard tunnel start requested with the current connection settings.",
                level: .debug
            )
        } catch is CancellationError {
            reportEventLog(
                "Cancelled a pending WireGuard tunnel start.",
                level: .debug
            )
        } catch WireGuardTunnelError.operationSuperseded {
            reportEventLog(
                "Superseded a pending WireGuard tunnel operation.",
                level: .debug
            )
        } catch {
            guard activeOperationID == operationID else { return }
            fail(
                action: "start", error: error,
                restoring: lifecycleStatusAfterFailure(fallback: statusBeforeOperation)
            )
        }
    }

    @discardableResult
    func disconnect(waitUntilStopped: Bool = false) async -> Bool {
        let statusBeforeOperation = currentStatus
        let operationID = beginOperation()
        do {
            guard let manager = try await loadThruRNDISManager(
                operationID: operationID
            ) else {
                setStatus(.unconfigured)
                return true
            }
            try ensureOperationIsCurrent(operationID)
            _ = trackConnection(
                manager.connection,
                operationID: operationID,
                ignoresDisconnectError: true
            )

            let connectionStatus = manager.connection.status
            guard connectionStatus != .disconnected,
                  connectionStatus != .invalid else {
                setStatus(connectionStatus == .disconnected ? .disconnected : .unconfigured)
                return true
            }

            guard let session = manager.connection as? NETunnelProviderSession else {
                throw WireGuardTunnelError.sessionUnavailable
            }

            setStatus(.disconnecting)
            if connectionStatus != .disconnecting {
                session.stopTunnel()
                reportEventLog(
                    "WireGuard tunnel stop requested.",
                    level: .debug
                )
            }

            guard waitUntilStopped else {
                return true
            }

            guard try await waitForInactiveConnection(
                manager: manager,
                operationID: operationID
            ) else {
                throw WireGuardTunnelError.stopTimedOut
            }

            setStatus(.disconnected)
            reportEventLog(
                "WireGuard tunnel stopped.",
                level: .debug
            )
            return true
        } catch is CancellationError {
            return false
        } catch WireGuardTunnelError.operationSuperseded {
            return false
        } catch {
            guard activeOperationID == operationID else { return false }
            fail(
                action: "stop", error: error,
                restoring: lifecycleStatusAfterFailure(fallback: statusBeforeOperation)
            )
            return false
        }
    }

    func disconnectForApplicationTermination() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: Self.applicationTerminationStopTimeout
        )
        let (results, resultContinuation) =
            AsyncStream<(didFinish: Bool, didStop: Bool)>.makeStream()
        let disconnectTask = Task { @MainActor in
            let didStop = await disconnect(waitUntilStopped: true)
            resultContinuation.yield((true, didStop))
        }
        let timeoutTask = Task.detached {
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            resultContinuation.yield((false, false))
        }

        var iterator = results.makeAsyncIterator()
        let result = await iterator.next() ?? (false, false)
        resultContinuation.finish()
        timeoutTask.cancel()

        guard result.didFinish else {
            disconnectTask.cancel()
            _ = beginOperation()
            reportEventLog(
                "WireGuard tunnel stop timed out after five seconds during application termination.",
                level: .error
            )
            return false
        }
        return result.didStop
    }

    @discardableResult
    func removeSavedTunnelIfNeeded() async -> Bool {
        let operationID = beginOperation()
        do {
            guard let manager = try await loadThruRNDISManager(
                operationID: operationID
            ) else {
                setStatus(.unconfigured)
                return true
            }
            try ensureOperationIsCurrent(operationID)
            _ = trackConnection(
                manager.connection,
                operationID: operationID,
                ignoresDisconnectError: true
            )
            try await removeFromPreferences(manager)
            try ensureOperationIsCurrent(operationID)
            cachedManager = nil
            setStatus(.unconfigured)
            reportEventLog(
                "Removed the saved ThruRNDIS WireGuard tunnel profile.",
                level: .debug
            )
            return true
        } catch is CancellationError {
            return false
        } catch WireGuardTunnelError.operationSuperseded {
            return false
        } catch {
            guard activeOperationID == operationID else { return false }
            fail(action: "profile removal", error: error)
            return false
        }
    }

    private func configureAndSaveTunnelManager(
        connectionConfiguration: WireGuardConnectionConfiguration,
        operationID: UUID
    ) async throws -> NETunnelProviderManager {
        let manager = try await loadThruRNDISManager(
            operationID: operationID
        ) ?? NETunnelProviderManager()
        try ensureOperationIsCurrent(operationID)
        cachedManager = manager
        guard let protocolConfiguration = NETunnelProviderProtocol(
            wireGuardConfiguration: connectionConfiguration
        ) else {
            throw WireGuardTunnelError.configurationCreationFailed
        }

        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = WireGuardTunnelContract.displayName
        manager.isEnabled = true
        try await saveToPreferences(manager)
        try ensureOperationIsCurrent(operationID)
        try await loadFromPreferences(manager)
        try ensureOperationIsCurrent(operationID)
        return manager
    }

    private func startTunnel(
        manager: NETunnelProviderManager,
        configurationData: Data,
        operationID: UUID
    ) async throws {
        try ensureOperationIsCurrent(operationID)
        if manager.connection.status == .connected ||
            manager.connection.status == .connecting ||
            manager.connection.status == .reasserting {
            _ = trackConnection(
                manager.connection,
                operationID: operationID,
                ignoresDisconnectError: true
            )
            (manager.connection as? NETunnelProviderSession)?.stopTunnel()
            guard try await waitForInactiveConnection(
                manager: manager,
                operationID: operationID
            ) else {
                throw WireGuardTunnelError.stopTimedOut
            }
        }

        try await loadFromPreferences(manager)
        try ensureOperationIsCurrent(operationID)
        try await startTunnelSession(
            manager: manager,
            configurationData: configurationData,
            operationID: operationID
        )
    }

    private func startTunnelSession(
        manager: NETunnelProviderManager,
        configurationData: Data,
        operationID: UUID
    ) async throws {
        var didRetryStaleConfiguration = false

        while true {
            try ensureOperationIsCurrent(operationID)
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw WireGuardTunnelError.sessionUnavailable
            }
            _ = trackConnection(
                session,
                operationID: operationID,
                ignoresDisconnectError: false
            )

            do {
                let options: [String: NSObject] = [
                    WireGuardTunnelContract.tunnelConfigurationOptionKey:
                        configurationData as NSData,
                ]
                try session.startTunnel(options: options)
                setStatus(.connecting)
                return
            } catch let error as NEVPNError
                where !didRetryStaleConfiguration && error.code == .configurationStale {
                reportEventLog(
                    "Retrying WireGuard tunnel start once after reloading a stale configuration: " +
                        Self.diagnosticDescription(for: error),
                    level: .debug
                )
                try await loadFromPreferences(manager)
                try ensureOperationIsCurrent(operationID)
                didRetryStaleConfiguration = true
            }
        }
    }

    private func waitForInactiveConnection(
        manager: NETunnelProviderManager,
        operationID: UUID
    ) async throws -> Bool {
        for attempt in 0...10 {
            try ensureOperationIsCurrent(operationID)
            if manager.connection.status == .disconnected ||
                manager.connection.status == .invalid {
                return true
            }

            guard attempt < 10 else {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await loadFromPreferences(manager)
            try ensureOperationIsCurrent(operationID)
            _ = trackConnection(
                manager.connection,
                operationID: operationID,
                ignoresDisconnectError: true
            )
        }
        return false
    }

    private func loadThruRNDISManager(
        operationID: UUID
    ) async throws -> NETunnelProviderManager? {
        try ensureOperationIsCurrent(operationID)
        if let cachedManager,
           isThruRNDISManager(cachedManager) {
            return cachedManager
        }

        let managers = try await loadAllManagers()
        try ensureOperationIsCurrent(operationID)
        let manager = managers.first(where: isThruRNDISManager)
        cachedManager = manager
        return manager
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func saveToPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func loadFromPreferences(
        _ manager: NETunnelProviderManager
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func removeFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private nonisolated func isThruRNDISManager(
        _ manager: NETunnelProviderManager
    ) -> Bool {
        guard manager.localizedDescription == WireGuardTunnelContract.displayName,
              let providerProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        return providerProtocol.providerBundleIdentifier ==
            WireGuardTunnelContract.providerBundleIdentifier(derivedFrom: bundleIdentifier)
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        activeOperationID = operationID
        connectionObservationContexts.removeAll(keepingCapacity: true)
        return operationID
    }

    private func beginSystemExtensionOperation() -> UUID {
        let operationID = UUID()
        activeSystemExtensionOperationID = operationID
        return operationID
    }

    private func scheduleSystemExtensionStatusReconciliation(
        after operationID: UUID
    ) {
        guard !areSystemExtensionOperationsInvalidated,
              activeSystemExtensionOperationID == operationID else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self,
                  !self.areSystemExtensionOperationsInvalidated,
                  self.activeSystemExtensionOperationID == operationID else {
                return
            }
            await self.refreshSystemExtensionStatus()
        }
    }

    private func activateAndVerifySystemExtensionStatus(
        bundleIdentifier: String,
        operationID: UUID
    ) async throws -> WireGuardSystemExtensionStatus {
        systemExtensionActivator.onEventLog = onEventLog
        systemExtensionActivator.onActivationNeedsUserApproval = { [weak self] in
            guard let self,
                  !self.areSystemExtensionOperationsInvalidated,
                  self.activeSystemExtensionOperationID == operationID else {
                return
            }
            self.setSystemExtensionStatus(.inactive(.awaitingUserApproval))
        }

        try await systemExtensionActivator.activate(
            bundleIdentifier: bundleIdentifier
        )
        try ensureSystemExtensionOperationIsCurrent(operationID)

        let verifiedStatus = try await systemExtensionActivator.status(
            bundleIdentifier: bundleIdentifier
        )
        try ensureSystemExtensionOperationIsCurrent(operationID)
        return verifiedStatus
    }

    private func systemExtensionBundleIdentifier() throws -> String {
        guard let mainBundleIdentifier = Bundle.main.bundleIdentifier else {
            throw WireGuardTunnelError.bundleIdentifierUnavailable
        }
        return WireGuardTunnelContract.providerBundleIdentifier(
            derivedFrom: mainBundleIdentifier
        )
    }

    private func ensureOperationIsCurrent(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard activeOperationID == operationID else {
            throw WireGuardTunnelError.operationSuperseded
        }
    }

    private func ensureSystemExtensionOperationIsCurrent(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard !areSystemExtensionOperationsInvalidated,
              activeSystemExtensionOperationID == operationID else {
            throw WireGuardTunnelError.operationSuperseded
        }
    }

    @discardableResult
    private func trackConnection(
        _ connection: NEVPNConnection,
        operationID: UUID,
        ignoresDisconnectError: Bool
    ) -> ConnectionObservationContext {
        let context = ConnectionObservationContext(
            operationID: operationID,
            ignoresDisconnectError: ignoresDisconnectError
        )
        connectionObservationContexts[ObjectIdentifier(connection)] = context
        return context
    }

    private func updateStatus(
        from status: NEVPNStatus,
        connection: NEVPNConnection,
        context: ConnectionObservationContext
    ) async {
        let connectionID = ObjectIdentifier(connection)
        guard activeOperationID == context.operationID,
              connectionObservationContexts[connectionID] == context,
              connection.status == status else {
            return
        }
        guard status == .disconnected else {
            do {
                setStatus(
                    try Self.status(from: status),
                    clearingFailure: status != .disconnecting
                )
            } catch {
                fail(action: "status update", error: error)
            }
            return
        }

        guard !context.ignoresDisconnectError else {
            setStatus(.disconnected)
            return
        }

        let disconnectError = await fetchLastDisconnectError(connection)
        guard activeOperationID == context.operationID,
              connectionObservationContexts[connectionID] == context,
              connection.status == .disconnected else {
            return
        }

        if let disconnectError {
            fail(action: "provider disconnect", error: disconnectError, restoring: .disconnected)
        } else {
            setStatus(.disconnected)
        }
    }

    private func fetchLastDisconnectError(_ connection: NEVPNConnection) async -> Error? {
        await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error)
            }
        }
    }

    private func setStatus(_ status: WireGuardTunnelStatus, clearingFailure: Bool = true) {
        if clearingFailure {
            onFailureChange?(nil)
        }
        guard status != currentStatus else {
            return
        }
        currentStatus = status
        onStatusChange?(status)
    }

    private func lifecycleStatusAfterFailure(
        fallback: WireGuardTunnelStatus
    ) -> WireGuardTunnelStatus {
        guard let cachedManager else { return fallback }
        return (try? Self.status(from: cachedManager.connection.status)) ?? fallback
    }

    private func setSystemExtensionStatus(
        _ status: WireGuardSystemExtensionStatus
    ) {
        guard status != currentSystemExtensionStatus else {
            return
        }
        currentSystemExtensionStatus = status
        onSystemExtensionStatusChange?(status)
    }

    private func failSystemExtension(action: String, error: Error) {
        let diagnostic = Self.diagnosticDescription(for: error)
        setSystemExtensionStatus(.unknown(diagnostic))
        reportEventLog(
            "Network extension \(action) failed: \(diagnostic)",
            level: .error
        )
    }

    private func fail(
        action: String, error: Error, restoring status: WireGuardTunnelStatus? = nil
    ) {
        let diagnostic = Self.diagnosticDescription(for: error)
        onFailureChange?(WireGuardTunnelFailure(message: diagnostic))
        if let status {
            setStatus(status, clearingFailure: false)
        }
        reportEventLog(
            "WireGuard tunnel \(action) failed: \(diagnostic)",
            level: .error
        )
    }

    private func reportEventLog(
        _ message: String,
        level: EventLogLevel
    ) {
        onEventLog?(message, level)
    }

    static func diagnosticDescription(for error: Error) -> String {
        EventLogErrorFormatter.description(for: error)
    }

    private nonisolated static func status(
        from status: NEVPNStatus
    ) throws -> WireGuardTunnelStatus {
        switch status {
        case .invalid:
            return .unconfigured
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .reasserting:
            return .connecting
        case .disconnecting:
            return .disconnecting
        @unknown default:
            throw WireGuardTunnelError.unknownNetworkExtensionStatus
        }
    }
}

private enum WireGuardTunnelError: LocalizedError {
    case bundleIdentifierUnavailable
    case configurationCreationFailed
    case operationSuperseded
    case sessionUnavailable
    case stopTimedOut
    case unknownNetworkExtensionStatus

    var errorDescription: String? {
        switch self {
        case .bundleIdentifierUnavailable:
            return String(localized: "The ThruRNDIS bundle identifier is unavailable.")
        case .configurationCreationFailed:
            return String(localized: "Could not create the WireGuard packet tunnel configuration.")
        case .operationSuperseded:
            return String(localized: "A newer WireGuard tunnel operation superseded this request.")
        case .sessionUnavailable:
            return String(localized: "The saved WireGuard tunnel is not a packet tunnel session.")
        case .stopTimedOut:
            return String(localized: "The WireGuard tunnel did not stop within five seconds.")
        case .unknownNetworkExtensionStatus:
            return "Unknown NetworkExtension status."
        }
    }
}
