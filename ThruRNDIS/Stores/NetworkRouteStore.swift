/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

enum NetworkRouteOperation: Equatable {
    case refreshing
    case checkingRoutes
    case reapplyingRoutes
    case starting
    case stopping

    var title: String {
        switch self {
        case .refreshing, .checkingRoutes:
            String(localized: "Checking")
        case .starting:
            String(localized: "Starting")
        case .reapplyingRoutes:
            String(localized: "Repairing")
        case .stopping:
            String(localized: "Stopping")
        }
    }
}

@MainActor
final class NetworkRouteStore: ObservableObject {
    let helper: NetworkRouteHelperStore

    @Published private(set) var snapshot: NetworkRouteSnapshot?
    @Published private(set) var operation: NetworkRouteOperation?
    @Published private(set) var guestIPv4Address: String?
    @Published private(set) var vznatGatewayIPv4Address: String?
    @Published private(set) var rndisIPv4Address: String?
    @Published private(set) var isRNDISRouteReady = false
    @Published private(set) var lastErrorMessage: String?
    @Published private var isStopQueued = false

    private let client: NetworkRoutePrivilegedHelperClient
    private let eventLog: EventLogStore
    private let networkPathMonitor: NetworkPathMonitorService
    private var reconciliationGeneration: UInt64 = 0
    private var shouldRunManagedNetwork = false
    private var needsReconciliationAfterRefresh = false
    private var isNetworkPathMonitoring = false
    private var hasPendingNetworkPathRecovery = false
    private var networkPathDebounceTask: Task<Void, Never>?
    private var helperCancellables: Set<AnyCancellable> = []

    private struct NetworkPathRecoveryContext {
        let guestIPv4Address: String
        let vznatGatewayIPv4Address: String
        let bondInterfaceName: String
    }

    init(
        eventLog: EventLogStore,
        networkPathMonitor: NetworkPathMonitorService,
        helper: NetworkRouteHelperStore? = nil,
        client: NetworkRoutePrivilegedHelperClient? = nil
    ) {
        let helper = helper ?? NetworkRouteHelperStore(eventLog: eventLog)
        self.helper = helper
        self.client = client ?? NetworkRoutePrivilegedHelperClient()
        self.eventLog = eventLog
        self.networkPathMonitor = networkPathMonitor
        self.client.onLeaseInvalidated = { [weak self] in
            self?.routeLeaseDidInvalidate()
        }
        self.networkPathMonitor.onPathChange = { [weak self] in
            self?.networkPathDidChange()
        }

        Publishers.CombineLatest(
            helper.$registrationStatus,
            helper.$operation
        )
        .dropFirst()
        .sink { [weak self] _, _ in
            self?.helperStatusDidChange()
        }
        .store(in: &helperCancellables)
    }

    var isOperationInProgress: Bool {
        (operation != nil && operation != .refreshing)
            || helper.isOperationInProgress
            || isStopQueued
    }

    private var isReadyToRoute: Bool {
        helper.isAvailable
            && guestIPv4Address != nil
            && vznatGatewayIPv4Address != nil
            && isRNDISRouteReady
    }

    var canStart: Bool {
        isReadyToRoute
            && !isOperationInProgress
            && snapshot?.state != .active
    }

    var canRestart: Bool {
        !isOperationInProgress && snapshot?.state == .active
    }

    var canStop: Bool {
        !isOperationInProgress
            && (snapshot?.state == .active || snapshot?.state == .degraded)
    }

    func refresh() {
        helper.refresh()
        requestRouteStatusRefresh()
    }

    func startNetworkPathMonitoring() {
        guard !isNetworkPathMonitoring else { return }
        isNetworkPathMonitoring = true
        networkPathMonitor.start()
    }

    func stopNetworkPathMonitoring() {
        isNetworkPathMonitoring = false
        networkPathMonitor.cancel()
        clearPendingNetworkPathRecovery()
    }

    private func requestRouteStatusRefresh() {
        guard helper.isAvailable, operation == nil else {
            if !helper.isAvailable {
                snapshot = nil
            }
            return
        }

        needsReconciliationAfterRefresh = false
        let generation = beginOperation(.refreshing)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.status()
                guard self.finishOperation(generation) else { return }
                self.apply(snapshot)
                self.reconcileAfterStatusRefreshIfNeeded(
                    reason: "Network Routing status refresh completed"
                )
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(error, context: "Network Routing status refresh failed")
                self.reconcileAfterStatusRefreshIfNeeded(
                    reason: "Network Routing status refresh failed"
                )
            }
        }
    }

    private func networkPathDidChange() {
        // Keep changes that arrive after helper-side installation but before
        // the start reply marks the app's retained connection as the lease.
        let hasLeaseOrPendingStart = client.hasActiveLease
            || operation == .starting
        guard isNetworkPathMonitoring,
              shouldRunManagedNetwork,
              hasLeaseOrPendingStart,
              helper.isAvailable,
              isRNDISRouteReady,
              guestIPv4Address != nil,
              vznatGatewayIPv4Address != nil else {
            return
        }

        hasPendingNetworkPathRecovery = true
        networkPathDebounceTask?.cancel()
        networkPathDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.networkPathDebounceTask = nil
            self.performPendingNetworkPathRecoveryIfPossible()
        }
    }

    private func performPendingNetworkPathRecoveryIfPossible() {
        guard hasPendingNetworkPathRecovery,
              networkPathDebounceTask == nil else { return }
        guard operation == nil,
              !helper.isOperationInProgress,
              !isStopQueued else {
            return
        }
        guard isNetworkPathMonitoring,
              shouldRunManagedNetwork,
              client.hasActiveLease,
              helper.isAvailable,
              isRNDISRouteReady,
              let guestIPv4Address,
              let vznatGatewayIPv4Address,
              let snapshot,
              snapshot.guestIPv4Address == guestIPv4Address,
              snapshot.vznatGatewayIPv4Address
                == vznatGatewayIPv4Address,
              let bondInterfaceName = snapshot.bondInterfaceName else {
            clearPendingNetworkPathRecovery()
            return
        }

        hasPendingNetworkPathRecovery = false
        recoverManagedRoutesAfterNetworkPathChange(.init(
            guestIPv4Address: guestIPv4Address,
            vznatGatewayIPv4Address: vznatGatewayIPv4Address,
            bondInterfaceName: bondInterfaceName
        ))
    }

    private func recoverManagedRoutesAfterNetworkPathChange(
        _ context: NetworkPathRecoveryContext
    ) {
        let generation = beginOperation(.checkingRoutes)
        appendEventLog(
            "Checking the managed /1 routes after a macOS network path change.",
            level: .debug
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failureContext =
                "Could not check Network Routing after the macOS network path changed"
            do {
                let checked = try await self.client.status()
                guard self.reconciliationGeneration == generation else {
                    return
                }
                self.apply(checked)
                guard self.isNetworkPathRecoveryDesiredAndCurrent(
                    context
                ) else {
                    self.finishOperation(generation)
                    return
                }
                guard self.snapshotMatchesNetworkPathRecovery(
                    checked,
                    context: context
                ) else {
                    self.finishOperation(generation)
                    self.disarmNetworkPathRecovery(
                        after: checked,
                        expectedBondInterfaceName: context.bondInterfaceName
                    )
                    return
                }
                guard checked.installedPrefixes
                    != ThruRNDISNetworkRoute.managedIPv4Prefixes else {
                    self.finishOperation(generation)
                    self.appendEventLog(
                        "The managed /1 routes remain scoped to \(context.bondInterfaceName).",
                        level: .debug
                    )
                    return
                }

                self.operation = .reapplyingRoutes
                self.lastErrorMessage = nil
                self.appendEventLog(
                    "Reapplying the managed global and \(context.bondInterfaceName)-scoped /1 routes after a macOS network path change.",
                    level: .warning
                )
                failureContext =
                    "Could not reapply Network Routing after the macOS network path changed"
                let repaired = try await self.client.reapplyRoutes(
                    guestIPv4Address: context.guestIPv4Address,
                    vznatGatewayIPv4Address:
                        context.vznatGatewayIPv4Address
                )
                guard self.finishOperation(generation) else { return }
                self.apply(repaired)
                guard self.isNetworkPathRecoveryDesiredAndCurrent(
                    context
                ) else {
                    return
                }
                self.appendEventLog(
                    "Restored the managed /1 routes on \(context.bondInterfaceName).",
                    level: .info
                )
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(
                    error,
                    context: failureContext
                )
            }
        }
    }

    private func snapshotMatchesNetworkPathRecovery(
        _ snapshot: NetworkRouteSnapshot,
        context: NetworkPathRecoveryContext
    ) -> Bool {
        snapshot.guestIPv4Address == context.guestIPv4Address
            && snapshot.vznatGatewayIPv4Address
                == context.vznatGatewayIPv4Address
            && snapshot.bondInterfaceName == context.bondInterfaceName
    }

    private func isNetworkPathRecoveryDesiredAndCurrent(
        _ context: NetworkPathRecoveryContext
    ) -> Bool {
        isNetworkPathMonitoring
            && shouldRunManagedNetwork
            && client.hasActiveLease
            && helper.isAvailable
            && isRNDISRouteReady
            && guestIPv4Address == context.guestIPv4Address
            && vznatGatewayIPv4Address
                == context.vznatGatewayIPv4Address
    }

    private func disarmNetworkPathRecovery(
        after checked: NetworkRouteSnapshot,
        expectedBondInterfaceName: String
    ) {
        shouldRunManagedNetwork = false
        clearPendingNetworkPathRecovery()
        lastErrorMessage = String(localized: "Needs Attention")
        appendEventLog(
            "Network Routing recovery was disarmed because the helper reported state=\(checked.state.rawValue), guest=\(checked.guestIPv4Address ?? "missing"), gateway=\(checked.vznatGatewayIPv4Address ?? "missing"), bond=\(checked.bondInterfaceName ?? "missing") instead of the active \(expectedBondInterfaceName) configuration.",
            level: .error
        )
    }

    private func clearPendingNetworkPathRecovery() {
        networkPathDebounceTask?.cancel()
        networkPathDebounceTask = nil
        hasPendingNetworkPathRecovery = false
    }

    func updateVZNATNetwork(
        guestIPv4Address: String,
        vznatGatewayIPv4Address: String
    ) {
        guard self.guestIPv4Address != guestIPv4Address
                || self.vznatGatewayIPv4Address
                    != vznatGatewayIPv4Address else {
            return
        }
        self.guestIPv4Address = guestIPv4Address
        self.vznatGatewayIPv4Address = vznatGatewayIPv4Address
        appendEventLog(
            "Guest VZNAT network discovered: guest=\(guestIPv4Address), gateway=\(vznatGatewayIPv4Address).",
            level: .info
        )
        if operation == .starting
            || operation == .checkingRoutes
            || operation == .reapplyingRoutes {
            stopPreservingDesiredState(
                reason: "guest VZNAT network changed during a Network Routing operation"
            )
            return
        }
        reconcileIfNeeded(reason: "guest VZNAT network discovered")
    }

    func updateRNDISIPv4Address(_ address: String) {
        guard isRNDISRouteReady, rndisIPv4Address != address else { return }
        rndisIPv4Address = address
        appendEventLog(
            "Guest RNDIS IPv4 address discovered: \(address).",
            level: .info
        )
    }

    func clearRNDISIPv4Address() {
        rndisIPv4Address = nil
    }

    func updateRNDISRouteReady(_ isReady: Bool) {
        if !isReady {
            rndisIPv4Address = nil
        }
        guard isRNDISRouteReady != isReady else { return }
        isRNDISRouteReady = isReady
        if !isReady {
            clearPendingNetworkPathRecovery()
            shouldRunManagedNetwork = false
        }
        appendEventLog(
            isReady
                ? "Guest RNDIS route reported ready."
                : "Guest RNDIS route is no longer ready.",
            level: isReady ? .info : .warning
        )
        if !isReady,
           operation == .starting
            || operation == .checkingRoutes
            || operation == .reapplyingRoutes {
            stopPreservingDesiredState(
                reason: "guest RNDIS route became unavailable during a Network Routing operation"
            )
            return
        }
        reconcileIfNeeded(reason: "guest RNDIS readiness changed")
    }

    func usbDidAttach(allowsAutomaticNetworkRoutingStart: Bool) {
        cancelStatusRefreshIfNeeded()
        shouldRunManagedNetwork = allowsAutomaticNetworkRoutingStart
        lastErrorMessage = nil
        guard allowsAutomaticNetworkRoutingStart else { return }
        reconcileIfNeeded(reason: "USB accessory attached")
    }

    func usbDidDetach() {
        clearPendingNetworkPathRecovery()
        shouldRunManagedNetwork = false
    }

    func startManually() {
        guard canStart else { return }
        cancelStatusRefreshIfNeeded()
        shouldRunManagedNetwork = true
        lastErrorMessage = nil
        reconcileIfNeeded(reason: "manual start requested")
    }

    func restartManually() {
        guard canRestart else { return }
        shouldRunManagedNetwork = true
        lastErrorMessage = nil
        stopPreservingDesiredState(reason: "manual restart requested")
    }

    func stopManually() {
        guard canStop else { return }
        clearPendingNetworkPathRecovery()
        shouldRunManagedNetwork = false
        stopPreservingDesiredState(reason: "manual stop requested")
    }

    @discardableResult
    func resetForVMStart() -> Bool {
        cancelStatusRefreshIfNeeded()
        clearDesiredNetworkState()
        guard operation == nil,
              !helper.isOperationInProgress,
              snapshot?.state == .inactive else {
            stop(reason: "VM session starting")
            return false
        }
        return true
    }

    func vmDidStop() {
        clearDesiredNetworkState()
        stop(reason: "VM stopped")
    }

    func guestControlPathDidFail(reason: String) {
        clearDesiredNetworkState()
        stop(reason: reason)
    }

    private func stop(reason: String) {
        clearDesiredNetworkState()
        queueStop(reason: reason)
    }

    @discardableResult
    func stopAndWait(reason: String) async -> Bool {
        cancelStatusRefreshIfNeeded()
        clearDesiredNetworkState()
        return await performStop(reason: reason)
    }

    func stopForApplicationTermination() async -> Bool {
        cancelStatusRefreshIfNeeded()
        clearDesiredNetworkState()
        while operation != nil || helper.isOperationInProgress {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        if snapshot?.state == .inactive { return true }
        reconciliationGeneration &+= 1
        let generation = reconciliationGeneration
        operation = .stopping
        guard helper.isAvailable else {
            operation = nil
            appendEventLog(
                "Network Routing cleanup could not be verified because the Network Helper is unavailable.",
                level: .error
            )
            return false
        }

        do {
            let stopped = try await client.stopForApplicationTermination()
            guard finishOperation(generation) else { return false }
            apply(stopped)
            return snapshot?.state == .inactive
        } catch {
            guard finishOperation(generation) else { return false }
            report(
                error,
                context: "Could not stop Network Routing during application termination"
            )
            return false
        }
    }

    func resetForAppSettings() async throws {
        clearDesiredNetworkState()

        helper.refresh()
        if helper.isAvailable {
            guard await performStop(reason: "app settings reset") else {
                throw NetworkRouteSettingsResetError.routeRemovalIncomplete
            }
        }

        let status = try await helper.removeForAppSettings()
        guard status == .notRegistered || status == .notFound else {
            throw NetworkRouteSettingsResetError.helperRemovalIncomplete
        }
        // Preserve the proven cleanup result. App reset subsequently runs the
        // normal termination preparation after unregistering the helper.
        snapshot = .inactive
    }

    private func stopPreservingDesiredState(reason: String) {
        queueStop(reason: reason)
    }

    private func queueStop(reason: String) {
        cancelStatusRefreshIfNeeded()
        guard operation != nil || snapshot?.state != .inactive else { return }
        guard !isStopQueued else { return }
        isStopQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.performStop(reason: reason)
            self.isStopQueued = false
        }
    }

    private func performStop(reason: String) async -> Bool {
        while operation != nil || helper.isOperationInProgress {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        if snapshot?.state == .inactive { return true }

        guard helper.isAvailable else {
            reconciliationGeneration &+= 1
            operation = nil
            snapshot = nil
            appendEventLog(
                "Network Routing cleanup could not be verified because the Network Helper is unavailable: \(reason).",
                level: .error
            )
            return false
        }

        let generation = beginOperation(.stopping)
        appendEventLog(
            "Removing the managed routes, VM bridge member, Bond, and feth pair: \(reason).",
            level: .debug
        )
        do {
            let stopped = try await client.stop()
            guard finishOperation(generation) else { return false }
            apply(stopped)
            let didStop = stopped.state == .inactive
            if didStop {
                appendEventLog("Network Routing stopped.", level: .info)
            } else {
                lastErrorMessage = String(
                    localized: "Network Routing did not become inactive."
                )
            }
            reconcileIfNeeded(reason: "Network Routing stop completed")
            return didStop
        } catch {
            guard finishOperation(generation) else { return false }
            report(error, context: "Could not stop Network Routing")
            return false
        }
    }

    private func clearDesiredNetworkState() {
        needsReconciliationAfterRefresh = false
        clearPendingNetworkPathRecovery()
        shouldRunManagedNetwork = false
        guestIPv4Address = nil
        vznatGatewayIPv4Address = nil
        rndisIPv4Address = nil
        isRNDISRouteReady = false
    }

    private func cancelStatusRefreshIfNeeded() {
        guard operation == .refreshing else { return }
        reconciliationGeneration &+= 1
        needsReconciliationAfterRefresh = false
        operation = nil
    }

    private func helperStatusDidChange() {
        if helper.isAvailable {
            requestRouteStatusRefresh()
        } else if !helper.isOperationInProgress {
            reconciliationGeneration &+= 1
            needsReconciliationAfterRefresh = false
            clearPendingNetworkPathRecovery()
            snapshot = nil
            operation = nil
        }
    }

    private func routeLeaseDidInvalidate() {
        reconciliationGeneration &+= 1
        needsReconciliationAfterRefresh = false
        clearPendingNetworkPathRecovery()
        operation = nil
        snapshot = nil
        guestIPv4Address = nil
        vznatGatewayIPv4Address = nil
        rndisIPv4Address = nil
        isRNDISRouteReady = false
        shouldRunManagedNetwork = false
        appendEventLog(
            "The Network Helper lease was interrupted; clearing the guest control path and attempting fail-safe cleanup.",
            level: .error
        )

        guard helper.isAvailable else {
            lastErrorMessage = String(
                localized: "The Network Routing lease ended while the Network Helper was unavailable."
            )
            return
        }

        let generation = beginOperation(.stopping)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.stop()
                guard self.finishOperation(generation) else { return }
                self.apply(snapshot)
                self.appendEventLog(
                    "Network Routing was removed after the helper lease interruption.",
                    level: .info
                )
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(
                    error,
                    context: "Could not remove Network Routing after the helper lease interruption"
                )
            }
        }
    }

    private func reconcileIfNeeded(reason: String) {
        guard operation == nil else {
            if operation == .refreshing {
                needsReconciliationAfterRefresh = true
            }
            return
        }
        guard helper.isAvailable else { return }
        guard let guestIPv4Address,
              let vznatGatewayIPv4Address,
              isRNDISRouteReady else {
            if snapshot?.state == .active || snapshot?.state == .degraded {
                stopPreservingDesiredState(reason: reason)
            }
            return
        }
        guard shouldRunManagedNetwork else { return }
        guard snapshot?.state != .active
                || snapshot?.guestIPv4Address != guestIPv4Address
                || snapshot?.vznatGatewayIPv4Address
                    != vznatGatewayIPv4Address else {
            return
        }

        if snapshot?.state == .active {
            stopPreservingDesiredState(reason: "guest VZNAT network changed")
            return
        }

        let generation = beginOperation(.starting)
        lastErrorMessage = nil
        appendEventLog(
            "Creating the feth bridge network and installing global and "
                + "interface-scoped /1 routes through "
                + "\(ThruRNDISNetworkRoute.routerIPv4Address): \(reason).",
            level: .debug
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.start(
                    guestIPv4Address: guestIPv4Address,
                    vznatGatewayIPv4Address: vznatGatewayIPv4Address
                )
                guard self.finishOperation(generation) else {
                    _ = await self.performStop(
                        reason: "stale network start completed"
                    )
                    self.reconcileIfNeeded(
                        reason: "stale network start was cleaned up"
                    )
                    return
                }
                self.apply(snapshot)
                guard self.guestIPv4Address == guestIPv4Address,
                      self.vznatGatewayIPv4Address
                        == vznatGatewayIPv4Address,
                      self.isRNDISRouteReady else {
                    _ = await self.performStop(
                        reason: "network start completed after desired state changed"
                    )
                    self.reconcileIfNeeded(
                        reason: "stale network start cleanup completed"
                    )
                    return
                }
                self.appendEventLog(
                    "IPv4 traffic is routed through \(snapshot.bondInterfaceName ?? "unknown Bond") and \(snapshot.bridgeInterfaceName ?? "unknown bridge") to guest \(guestIPv4Address).",
                    level: .info
                )
            } catch {
                guard self.finishOperation(generation) else { return }
                self.shouldRunManagedNetwork = false
                self.report(error, context: "Could not start Network Routing")
            }
        }
    }

    private func reconcileAfterStatusRefreshIfNeeded(reason: String) {
        guard needsReconciliationAfterRefresh else { return }
        needsReconciliationAfterRefresh = false
        reconcileIfNeeded(reason: reason)
    }

    private func beginOperation(_ operation: NetworkRouteOperation) -> UInt64 {
        reconciliationGeneration &+= 1
        self.operation = operation
        return reconciliationGeneration
    }

    @discardableResult
    private func finishOperation(_ generation: UInt64) -> Bool {
        guard reconciliationGeneration == generation else { return false }
        operation = nil
        if hasPendingNetworkPathRecovery {
            DispatchQueue.main.async { [weak self] in
                self?.performPendingNetworkPathRecoveryIfPossible()
            }
        }
        return true
    }

    private func apply(_ snapshot: NetworkRouteSnapshot) {
        self.snapshot = snapshot
        if snapshot.state != .degraded {
            lastErrorMessage = nil
        }
    }

    private func report(_ error: Error, context: String) {
        let detail: String
        if let clientError = error as? NetworkRoutePrivilegedHelperClientError {
            detail = clientError.diagnosticDescription
        } else {
            detail = EventLogErrorFormatter.description(for: error)
        }
        lastErrorMessage = "\(context): \(error.localizedDescription)"
        appendEventLog("\(context): \(detail)", level: .error)
    }

    private func appendEventLog(
        _ message: String,
        level: EventLogLevel
    ) {
        eventLog.append(message, level: level, category: .network)
    }
}

enum NetworkRouteSettingsResetError: LocalizedError {
    case operationInProgress
    case routeRemovalIncomplete
    case helperRemovalIncomplete

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            String(localized: "Wait for the current Network Helper operation to finish.")
        case .routeRemovalIncomplete:
            String(localized: "Network Routing could not be removed.")
        case .helperRemovalIncomplete:
            String(localized: "The Network Helper remained registered.")
        }
    }
}
