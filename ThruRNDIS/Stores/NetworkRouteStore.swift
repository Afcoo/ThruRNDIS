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
    @Published private(set) var usesSelectedSubnets: Bool
    @Published private(set) var subnetSpecification: String
    @Published private var isStopQueued = false
    @Published private var shouldRunManagedNetwork = false

    private let client: NetworkRoutePrivilegedHelperClient
    private let eventLog: EventLogStore
    private let defaults: UserDefaults
    private enum DefaultsKey {
        static let usesSelectedSubnets = "NetworkRoute.usesSelectedSubnets"
        static let subnetSpecification = "NetworkRoute.subnetSpecification"
    }
    private var reconciliationGeneration: UInt64 = 0
    private var needsReconciliationAfterRefresh = false
    private var helperCancellables: Set<AnyCancellable> = []

    init(
        eventLog: EventLogStore,
        helper: NetworkRouteHelperStore? = nil,
        client: NetworkRoutePrivilegedHelperClient? = nil,
        defaults: UserDefaults = .standard
    ) {
        let helper = helper ?? NetworkRouteHelperStore(eventLog: eventLog)
        self.helper = helper
        self.client = client ?? NetworkRoutePrivilegedHelperClient()
        self.eventLog = eventLog
        self.defaults = defaults
        usesSelectedSubnets = defaults.bool(forKey: DefaultsKey.usesSelectedSubnets)
        subnetSpecification = defaults.string(forKey: DefaultsKey.subnetSpecification) ?? ""
        self.client.onLeaseInvalidated = { [weak self] in
            self?.routeLeaseDidInvalidate()
        }

        Publishers.CombineLatest(
            helper.$registrationStatus,
            helper.$operation
        )
        .dropFirst()
        .sink { [weak self] registrationStatus, helperOperation in
            self?.helperStatusDidChange(
                registrationStatus: registrationStatus,
                helperOperation: helperOperation
            )
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
            && subnetValidationError == nil
    }

    var canEditRoutingPolicy: Bool { !isOperationInProgress && !hasManagedNetwork }

    private func routingPolicy() throws -> NetworkRoutePolicy {
        try NetworkRoutePolicy(selectedSubnets: usesSelectedSubnets ? subnetSpecification : nil)
    }

    var subnetValidationError: String? {
        do {
            _ = try routingPolicy()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setUsesSelectedSubnets(_ enabled: Bool) {
        guard canEditRoutingPolicy else { return }
        usesSelectedSubnets = enabled
        defaults.set(enabled, forKey: DefaultsKey.usesSelectedSubnets)
    }

    func setSubnetSpecification(_ value: String) {
        guard canEditRoutingPolicy else { return }
        subnetSpecification = value
        defaults.set(value, forKey: DefaultsKey.subnetSpecification)
    }

    var canRestart: Bool {
        !isOperationInProgress && snapshot?.state == .active && subnetValidationError == nil
    }

    private var hasManagedNetwork: Bool {
        snapshot?.state == .active || snapshot?.state == .degraded
    }

    var canStop: Bool {
        if isStopQueued { return shouldRunManagedNetwork }
        return !isOperationInProgress && (hasManagedNetwork || shouldRunManagedNetwork)
    }

    func refresh() {
        helper.refresh()
        guard helper.isAvailable, !helper.isOperationInProgress else {
            if !helper.isAvailable {
                snapshot = nil
            }
            return
        }
        refreshRouteStatus()
    }

    private func refreshRouteStatus() {
        guard operation == nil, !isStopQueued else { return }

        needsReconciliationAfterRefresh = false
        let generation = beginOperation(.refreshing)
        Task { @MainActor [weak self] in
            guard let self,
                  self.reconciliationGeneration == generation else { return }
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
        appendEventLog(
            isReady
                ? "Guest RNDIS route reported ready."
                : "Guest RNDIS route is no longer ready.",
            level: isReady ? .info : .warning
        )
        if !isReady, operation != .stopping,
           operation == .starting || hasManagedNetwork {
            stopPreservingDesiredState(
                reason: "guest RNDIS route became unavailable"
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
        shouldRunManagedNetwork = false
        stopPreservingDesiredState(reason: "manual stop requested")
    }

    @discardableResult
    func resetForVMStart() -> Bool {
        cancelStatusRefreshIfNeeded()
        clearDesiredNetworkState()
        guard !isOperationInProgress,
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
        usesSelectedSubnets = false
        subnetSpecification = ""
        defaults.removeObject(forKey: DefaultsKey.usesSelectedSubnets)
        defaults.removeObject(forKey: DefaultsKey.subnetSpecification)
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
            let didStop = await self.performStop(reason: reason)
            if !didStop {
                self.shouldRunManagedNetwork = false
            }
            self.isStopQueued = false
            if didStop {
                self.reconcileIfNeeded(reason: "Network Routing stop completed")
            }
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
            "Disabling the managed Network Service and removing its VM bridge member, Bond, and feth pair: \(reason).",
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
            return didStop
        } catch {
            guard finishOperation(generation) else { return false }
            report(error, context: "Could not stop Network Routing")
            return false
        }
    }

    private func clearDesiredNetworkState() {
        needsReconciliationAfterRefresh = false
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

    private func helperStatusDidChange(
        registrationStatus: NetworkRouteHelperRegistrationStatus,
        helperOperation: NetworkRouteHelperOperation?
    ) {
        // @Published emits before the stored property changes. Decide from
        // the emitted pair so registration immediately triggers a status read.
        guard helperOperation == nil else { return }
        if registrationStatus == .enabled {
            refreshRouteStatus()
        } else {
            reconciliationGeneration &+= 1
            needsReconciliationAfterRefresh = false
            snapshot = nil
            operation = nil
        }
    }

    private func routeLeaseDidInvalidate() {
        reconciliationGeneration &+= 1
        needsReconciliationAfterRefresh = false
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
        guard !isStopQueued, helper.isAvailable, !helper.isOperationInProgress else { return }
        guard operation == nil else {
            if operation == .refreshing {
                needsReconciliationAfterRefresh = true
            }
            return
        }
        guard let guestIPv4Address,
              let vznatGatewayIPv4Address,
              isRNDISRouteReady else {
            if hasManagedNetwork {
                stopPreservingDesiredState(reason: reason)
            }
            return
        }
        guard shouldRunManagedNetwork else { return }
        let policy: NetworkRoutePolicy
        do {
            policy = try routingPolicy()
        } catch {
            shouldRunManagedNetwork = false
            report(error, context: "Invalid IPv4 subnet selection")
            if hasManagedNetwork { queueStop(reason: "invalid IPv4 subnet selection") }
            return
        }
        guard snapshot?.state != .active
                || snapshot?.selectedSubnets != policy.subnetSpecification
                || snapshot?.guestIPv4Address != guestIPv4Address
                || snapshot?.vznatGatewayIPv4Address
                    != vznatGatewayIPv4Address else {
            return
        }

        if snapshot?.state == .active {
            stopPreservingDesiredState(reason: "managed network configuration changed")
            return
        }

        let generation = beginOperation(.starting)
        lastErrorMessage = nil
        appendEventLog(
            "Creating the feth bridge network and activating the managed "
                + "Network Service through "
                + "\(ThruRNDISNetworkRoute.routerIPv4Address): \(reason).",
            level: .debug
        )
        Task { @MainActor [weak self] in
            guard let self, self.reconciliationGeneration == generation else { return }
            guard self.helper.isAvailable, !self.helper.isOperationInProgress else {
                self.operation = nil
                return
            }
            do {
                let snapshot = try await self.client.start(
                    guestIPv4Address: guestIPv4Address,
                    vznatGatewayIPv4Address: vznatGatewayIPv4Address,
                    policy: policy
                )
                guard self.finishOperation(generation) else {
                    self.queueStop(reason: "stale network start completed")
                    return
                }
                self.apply(snapshot)
                // A readiness loss may have queued cleanup before the start reply.
                guard !self.isStopQueued else { return }
                guard self.shouldRunManagedNetwork,
                      self.guestIPv4Address == guestIPv4Address,
                      self.vznatGatewayIPv4Address
                        == vznatGatewayIPv4Address,
                      self.isRNDISRouteReady else {
                    self.queueStop(
                        reason: "network start completed after desired state changed"
                    )
                    return
                }
                self.appendEventLog(
                    "The managed IPv4 network path is active through \(snapshot.bondInterfaceName ?? "unknown Bond") and \(snapshot.bridgeInterfaceName ?? "unknown bridge") to guest \(guestIPv4Address).",
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
