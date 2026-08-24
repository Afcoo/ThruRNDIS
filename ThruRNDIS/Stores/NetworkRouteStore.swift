/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

enum NetworkRouteOperation: Equatable {
    case refreshing
    case starting
    case stopping

    var title: String {
        switch self {
        case .refreshing:
            String(localized: "Checking")
        case .starting:
            String(localized: "Starting")
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
    private var reconciliationGeneration: UInt64 = 0
    private var shouldRunManagedNetwork = false
    private var helperCancellables: Set<AnyCancellable> = []

    init(
        eventLog: EventLogStore,
        helper: NetworkRouteHelperStore? = nil,
        client: NetworkRoutePrivilegedHelperClient? = nil
    ) {
        let helper = helper ?? NetworkRouteHelperStore(eventLog: eventLog)
        self.helper = helper
        self.client = client ?? NetworkRoutePrivilegedHelperClient()
        self.eventLog = eventLog
        self.client.onLeaseInvalidated = { [weak self] in
            self?.routeLeaseDidInvalidate()
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

    var canStop: Bool {
        !isOperationInProgress
            && (snapshot?.state == .active || snapshot?.state == .degraded)
    }

    func refresh() {
        helper.refresh()
        requestRouteStatusRefresh()
    }

    private func requestRouteStatusRefresh() {
        guard helper.isAvailable, operation == nil else {
            if !helper.isAvailable {
                snapshot = nil
            }
            return
        }

        let generation = beginOperation(.refreshing)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.status()
                guard self.finishOperation(generation) else { return }
                self.apply(snapshot)
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(error, context: "VM network status refresh failed")
            }
        }
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
        if operation == .starting {
            stopPreservingDesiredState(
                reason: "guest VZNAT network changed during network start"
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
            shouldRunManagedNetwork = false
        }
        appendEventLog(
            isReady
                ? "Guest RNDIS route reported ready."
                : "Guest RNDIS route is no longer ready.",
            level: isReady ? .info : .warning
        )
        if !isReady, operation == .starting {
            stopPreservingDesiredState(
                reason: "guest RNDIS route became unavailable during network start"
            )
            return
        }
        reconcileIfNeeded(reason: "guest RNDIS readiness changed")
    }

    func usbDidAttach() {
        cancelStatusRefreshIfNeeded()
        shouldRunManagedNetwork = true
        lastErrorMessage = nil
        reconcileIfNeeded(reason: "USB accessory attached")
    }

    func usbDidDetach() {
        shouldRunManagedNetwork = false
    }

    func startManually() {
        guard canStart else { return }
        cancelStatusRefreshIfNeeded()
        shouldRunManagedNetwork = true
        lastErrorMessage = nil
        reconcileIfNeeded(reason: "manual start requested")
    }

    func stopManually() {
        guard canStop else { return }
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
                "Managed network cleanup could not be verified because the Network Helper is unavailable.",
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
                context: "Could not remove the managed network during application termination"
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
                "Managed network cleanup could not be verified because the Network Helper is unavailable: \(reason).",
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
                appendEventLog("Managed host network removed.", level: .info)
            } else {
                lastErrorMessage = String(
                    localized: "The managed host network did not become inactive."
                )
            }
            reconcileIfNeeded(reason: "managed network stop completed")
            return didStop
        } catch {
            guard finishOperation(generation) else { return false }
            report(error, context: "Could not remove the managed host network")
            return false
        }
    }

    private func clearDesiredNetworkState() {
        shouldRunManagedNetwork = false
        guestIPv4Address = nil
        vznatGatewayIPv4Address = nil
        rndisIPv4Address = nil
        isRNDISRouteReady = false
    }

    private func cancelStatusRefreshIfNeeded() {
        guard operation == .refreshing else { return }
        reconciliationGeneration &+= 1
        operation = nil
    }

    private func helperStatusDidChange() {
        if helper.isAvailable {
            requestRouteStatusRefresh()
        } else if !helper.isOperationInProgress {
            reconciliationGeneration &+= 1
            snapshot = nil
            operation = nil
        }
    }

    private func routeLeaseDidInvalidate() {
        reconciliationGeneration &+= 1
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
                localized: "The managed VM network lease ended while the Network Helper was unavailable."
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
                    "The managed VM network was removed after the helper lease interruption.",
                    level: .info
                )
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(
                    error,
                    context: "Could not remove the managed VM network after the helper lease interruption"
                )
            }
        }
    }

    private func reconcileIfNeeded(reason: String) {
        guard operation == nil else { return }
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
                self.report(error, context: "Could not create the managed VM network")
            }
        }
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
            String(localized: "The managed VM network could not be removed.")
        case .helperRemovalIncomplete:
            String(localized: "The Network Helper remained registered.")
        }
    }
}
