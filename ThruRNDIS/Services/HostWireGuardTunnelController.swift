/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
@preconcurrency import NetworkExtension
import WireGuardKit

private struct ConnectionObservationContext: Equatable {
    let operationID: UUID
    let ignoresDisconnectError: Bool
}

@MainActor
protocol HostWireGuardTunnelControlling: AnyObject {
    var onStatusChange: ((HostWireGuardTunnelStatus) -> Void)? { get set }
    var onSystemExtensionStatusChange: ((WireGuardSystemExtensionStatus) -> Void)? { get set }
    var onEventLog: ((String) -> Void)? { get set }

    func refreshStatus() async
    func refreshSystemExtensionStatus() async
    func activateSystemExtension() async
    func invalidateSystemExtensionOperations()
    func connect(wgQuickConfiguration: String) async
    @discardableResult func disconnect(waitUntilStopped: Bool) async -> Bool
    @discardableResult func removeSavedTunnelIfNeeded() async -> Bool
}

@MainActor
final class HostWireGuardTunnelController: HostWireGuardTunnelControlling {
    var onStatusChange: ((HostWireGuardTunnelStatus) -> Void)?
    var onSystemExtensionStatusChange: ((WireGuardSystemExtensionStatus) -> Void)?
    var onEventLog: ((String) -> Void)?

    private let systemExtensionActivator: any WireGuardSystemExtensionActivating
    private var vpnStatusObserverToken: NSObjectProtocol?
    private var activeOperationID = UUID()
    private var currentStatus: HostWireGuardTunnelStatus = .unconfigured
    private var activeSystemExtensionOperationID = UUID()
    private var currentSystemExtensionStatus: WireGuardSystemExtensionStatus = .unknown
    private var isSystemExtensionActivationInProgress = false
    private var areSystemExtensionOperationsInvalidated = false
    private var cachedManager: NETunnelProviderManager?
    private var connectionObservationContexts: [
        ObjectIdentifier: ConnectionObservationContext
    ] = [:]

    init(
        systemExtensionActivator: any WireGuardSystemExtensionActivating
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
            onEventLog?(
                "Skipped network extension status refresh during activation."
            )
            return
        }

        let operationID = beginSystemExtensionOperation()
        setSystemExtensionStatus(.checking)
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
            onEventLog?("Ignored a duplicate network extension activation request.")
            return
        }

        isSystemExtensionActivationInProgress = true
        defer { isSystemExtensionActivationInProgress = false }

        let operationID = beginSystemExtensionOperation()
        setSystemExtensionStatus(.activationRequested)
        do {
            let bundleIdentifier = try systemExtensionBundleIdentifier()
            let verifiedStatus = try await activateAndVerifySystemExtensionStatus(
                bundleIdentifier: bundleIdentifier,
                operationID: operationID
            )
            setSystemExtensionStatus(verifiedStatus)
        } catch is CancellationError {
            return
        } catch HostWireGuardTunnelError.operationSuperseded {
            return
        } catch WireGuardSystemExtensionActivationError.restartRequired {
            guard activeSystemExtensionOperationID == operationID else {
                return
            }
            setSystemExtensionStatus(.restartRequired)
            onEventLog?("Network extension activation requires a macOS restart.")
        } catch {
            guard activeSystemExtensionOperationID == operationID else {
                return
            }
            failSystemExtension(action: "activation", error: error)
        }
    }

    func invalidateSystemExtensionOperations() {
        areSystemExtensionOperationsInvalidated = true
        _ = beginSystemExtensionOperation()
        systemExtensionActivator.cancelPendingRequests()
    }

    func refreshStatus() async {
        guard !currentStatus.isTransitioning else {
            onEventLog?("Ignored Host WireGuard status refresh during a tunnel transition.")
            return
        }
        let operationID = beginOperation()
        do {
            if let manager = try await loadThruRNDISManager() {
                try ensureOperationIsCurrent(operationID)
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
        } catch HostWireGuardTunnelError.operationSuperseded {
            return
        } catch {
            fail(action: "status refresh", error: error)
        }
    }

    func connect(wgQuickConfiguration: String) async {
        let operationID = beginOperation()
        do {
            try Task.checkCancellation()
            let tunnelConfiguration = try TunnelConfiguration(
                fromWgQuickConfig: wgQuickConfiguration,
                called: ThruRNDISTunnel.displayName
            )
            let extensionBundleIdentifier = try systemExtensionBundleIdentifier()
            guard !areSystemExtensionOperationsInvalidated else {
                throw CancellationError()
            }
            setStatus(.activatingSystemExtension)
            do {
                guard !isSystemExtensionActivationInProgress else {
                    throw WireGuardSystemExtensionActivationError.activationAlreadyInProgress
                }

                isSystemExtensionActivationInProgress = true
                defer { isSystemExtensionActivationInProgress = false }

                let systemExtensionOperationID = beginSystemExtensionOperation()
                setSystemExtensionStatus(.activationRequested)
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
                        throw HostWireGuardTunnelError.operationSuperseded
                    }
                    setSystemExtensionStatus(.restartRequired)
                    throw WireGuardSystemExtensionActivationError.restartRequired
                } catch WireGuardSystemExtensionActivationError.extensionRemainsDisabled {
                    throw WireGuardSystemExtensionActivationError.extensionRemainsDisabled
                } catch HostWireGuardTunnelError.operationSuperseded {
                    throw HostWireGuardTunnelError.operationSuperseded
                } catch {
                    guard !areSystemExtensionOperationsInvalidated,
                          activeSystemExtensionOperationID == systemExtensionOperationID else {
                        throw HostWireGuardTunnelError.operationSuperseded
                    }
                    setSystemExtensionStatus(.failed(Self.diagnosticDescription(for: error)))
                    throw error
                }
            }
            try ensureOperationIsCurrent(operationID)

            setStatus(.connecting)
            let manager = try await configureAndSaveTunnelManager(
                tunnelConfiguration: tunnelConfiguration,
                operationID: operationID
            )
            try await startTunnel(
                manager: manager,
                wgQuickConfiguration: wgQuickConfiguration,
                operationID: operationID
            )
            onEventLog?("Host WireGuard tunnel start requested with the current connection settings.")
        } catch is CancellationError {
            onEventLog?("Cancelled a pending Host WireGuard tunnel start.")
        } catch HostWireGuardTunnelError.operationSuperseded {
            onEventLog?("Superseded a pending Host WireGuard tunnel operation.")
        } catch {
            fail(action: "start", error: error)
        }
    }

    @discardableResult
    func disconnect(waitUntilStopped: Bool = false) async -> Bool {
        let operationID = beginOperation()
        do {
            guard let manager = try await loadThruRNDISManager() else {
                try ensureOperationIsCurrent(operationID)
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
                setStatus(Self.status(from: connectionStatus))
                return true
            }

            guard let session = manager.connection as? NETunnelProviderSession else {
                throw HostWireGuardTunnelError.sessionUnavailable
            }

            setStatus(.disconnecting)
            if connectionStatus != .disconnecting {
                session.stopTunnel()
                onEventLog?("Host WireGuard tunnel stop requested.")
            }

            guard waitUntilStopped else {
                return true
            }

            guard try await waitForInactiveConnection(
                manager: manager,
                operationID: operationID
            ) else {
                throw HostWireGuardTunnelError.stopTimedOut
            }

            setStatus(.disconnected)
            onEventLog?("Host WireGuard tunnel stopped.")
            return true
        } catch is CancellationError {
            return false
        } catch HostWireGuardTunnelError.operationSuperseded {
            return false
        } catch {
            fail(action: "stop", error: error)
            return false
        }
    }

    @discardableResult
    func removeSavedTunnelIfNeeded() async -> Bool {
        let operationID = beginOperation()
        do {
            guard let manager = try await loadThruRNDISManager() else {
                try ensureOperationIsCurrent(operationID)
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
            onEventLog?("Removed the saved ThruRNDIS WireGuard tunnel profile.")
            return true
        } catch is CancellationError {
            return false
        } catch HostWireGuardTunnelError.operationSuperseded {
            return false
        } catch {
            fail(action: "profile removal", error: error)
            return false
        }
    }

    private func configureAndSaveTunnelManager(
        tunnelConfiguration: TunnelConfiguration,
        operationID: UUID
    ) async throws -> NETunnelProviderManager {
        let manager = try await loadThruRNDISManager() ?? NETunnelProviderManager()
        cachedManager = manager
        try ensureOperationIsCurrent(operationID)
        guard let protocolConfiguration = NETunnelProviderProtocol(
            thruRNDISConfiguration: tunnelConfiguration
        ) else {
            throw HostWireGuardTunnelError.configurationCreationFailed
        }

        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = ThruRNDISTunnel.displayName
        manager.isEnabled = true
        try await saveToPreferences(manager)
        try ensureOperationIsCurrent(operationID)
        try await loadFromPreferences(manager)
        try ensureOperationIsCurrent(operationID)
        return manager
    }

    private func startTunnel(
        manager: NETunnelProviderManager,
        wgQuickConfiguration: String,
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
                throw HostWireGuardTunnelError.stopTimedOut
            }
        }

        try await loadFromPreferences(manager)
        try ensureOperationIsCurrent(operationID)
        try await startTunnelSession(
            manager: manager,
            wgQuickConfiguration: wgQuickConfiguration,
            operationID: operationID
        )
    }

    private func startTunnelSession(
        manager: NETunnelProviderManager,
        wgQuickConfiguration: String,
        operationID: UUID
    ) async throws {
        var retryCount: UInt = 0

        while true {
            try ensureOperationIsCurrent(operationID)
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw HostWireGuardTunnelError.sessionUnavailable
            }
            _ = trackConnection(
                session,
                operationID: operationID,
                ignoresDisconnectError: false
            )

            do {
                let options: [String: NSObject] = [
                    ThruRNDISTunnel.wireGuardConfigurationOptionKey:
                        Data(wgQuickConfiguration.utf8) as NSData,
                ]
                try session.startTunnel(options: options)
                setStatus(.connecting)
                return
            } catch let error as NEVPNError
                where retryCount < 8 &&
                (error.code == .configurationInvalid || error.code == .configurationStale) {
                try await loadFromPreferences(manager)
                try ensureOperationIsCurrent(operationID)
                retryCount += 1
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

    private func loadThruRNDISManager() async throws -> NETunnelProviderManager? {
        if let cachedManager,
           isThruRNDISManager(cachedManager) {
            return cachedManager
        }

        let managers = try await loadAllManagers()
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
        guard manager.localizedDescription == ThruRNDISTunnel.displayName,
              let providerProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        return providerProtocol.providerBundleIdentifier ==
            ThruRNDISTunnel.providerBundleIdentifier(derivedFrom: bundleIdentifier)
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
            self.setSystemExtensionStatus(.awaitingUserApproval)
        }

        try await systemExtensionActivator.activate(
            bundleIdentifier: bundleIdentifier
        )
        try ensureSystemExtensionOperationIsCurrent(operationID)

        let verifiedStatus = try await systemExtensionActivator.status(
            bundleIdentifier: bundleIdentifier
        )
        try ensureSystemExtensionOperationIsCurrent(operationID)
        if !verifiedStatus.isActive {
            onEventLog?(
                "Network extension activation request completed; " +
                    "verified status: \(verifiedStatus.eventLogDescription)"
            )
        }
        return verifiedStatus
    }

    private func systemExtensionBundleIdentifier() throws -> String {
        guard let mainBundleIdentifier = Bundle.main.bundleIdentifier else {
            throw HostWireGuardTunnelError.bundleIdentifierUnavailable
        }
        return ThruRNDISTunnel.providerBundleIdentifier(
            derivedFrom: mainBundleIdentifier
        )
    }

    private func ensureOperationIsCurrent(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard activeOperationID == operationID else {
            throw HostWireGuardTunnelError.operationSuperseded
        }
    }

    private func ensureSystemExtensionOperationIsCurrent(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard !areSystemExtensionOperationsInvalidated,
              activeSystemExtensionOperationID == operationID else {
            throw HostWireGuardTunnelError.operationSuperseded
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
            setStatus(Self.status(from: status))
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
            fail(action: "provider disconnect", error: disconnectError)
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

    private func setStatus(_ status: HostWireGuardTunnelStatus) {
        guard status != currentStatus else {
            return
        }
        currentStatus = status
        onStatusChange?(status)
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
        setSystemExtensionStatus(.failed(diagnostic))
        onEventLog?(
            "Network extension \(action) failed: \(diagnostic)"
        )
    }

    private func fail(action: String, error: Error) {
        let diagnostic = Self.diagnosticDescription(for: error)
        setStatus(.failed(diagnostic))
        onEventLog?("Host WireGuard tunnel \(action) failed: \(diagnostic)")
    }

    static func diagnosticDescription(for error: Error) -> String {
        EventLogErrorFormatter.description(for: error)
    }

    private nonisolated static func status(
        from status: NEVPNStatus
    ) -> HostWireGuardTunnelStatus {
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
            return .reasserting
        case .disconnecting:
            return .disconnecting
        @unknown default:
            return .failed("Unknown NetworkExtension status.")
        }
    }
}

private enum HostWireGuardTunnelError: LocalizedError {
    case bundleIdentifierUnavailable
    case configurationCreationFailed
    case operationSuperseded
    case sessionUnavailable
    case stopTimedOut

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
        }
    }
}
