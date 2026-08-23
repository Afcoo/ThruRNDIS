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
    @Published private(set) var isRNDISRouteReady = false
    @Published private(set) var lastErrorMessage: String?

    private let client: NetworkRoutePrivilegedHelperClient
    private let eventLog: EventLogStore
    private var reconciliationGeneration: UInt64 = 0
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
        operation != nil || helper.isOperationInProgress
    }

    var isActive: Bool {
        snapshot?.state == .active
    }

    var isReadyToRoute: Bool {
        helper.isAvailable && guestIPv4Address != nil && isRNDISRouteReady
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
                self.reconcileIfNeeded(reason: "status refreshed")
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(error, context: "Network route status refresh failed")
            }
        }
    }

    func updateGuestIPv4Address(_ address: String) {
        guard guestIPv4Address != address else { return }
        guestIPv4Address = address
        appendEventLog(
            "Guest VZNAT IPv4 address discovered: \(address).",
            level: .info
        )
        if operation == .starting {
            stop(reason: "guest VZNAT address changed during route start")
            return
        }
        reconcileIfNeeded(reason: "guest VZNAT address discovered")
    }

    func updateRNDISRouteReady(_ isReady: Bool) {
        guard isRNDISRouteReady != isReady else { return }
        isRNDISRouteReady = isReady
        appendEventLog(
            isReady
                ? "Guest RNDIS route reported ready."
                : "Guest RNDIS route is no longer ready.",
            level: isReady ? .info : .warning
        )
        if !isReady, operation == .starting {
            stop(reason: "guest RNDIS route became unavailable during route start")
            return
        }
        reconcileIfNeeded(reason: "guest RNDIS readiness changed")
    }

    func resetForVMStart() {
        guestIPv4Address = nil
        isRNDISRouteReady = false
        stop(reason: "VM session starting")
    }

    func vmDidStop() {
        guestIPv4Address = nil
        isRNDISRouteReady = false
        stop(reason: "VM stopped")
    }

    func guestControlPathDidFail(reason: String) {
        guestIPv4Address = nil
        isRNDISRouteReady = false
        stop(reason: reason)
    }

    func stop(reason: String) {
        guard operation != .stopping else { return }
        guard helper.isAvailable else {
            reconciliationGeneration &+= 1
            operation = nil
            snapshot = nil
            return
        }

        let generation = beginOperation(.stopping)
        appendEventLog("Removing managed IPv4 routes: \(reason).", level: .debug)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.stop()
                guard self.finishOperation(generation) else { return }
                self.apply(snapshot)
                self.appendEventLog("Managed IPv4 routes removed.", level: .info)
                self.reconcileIfNeeded(reason: "route stop completed")
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(error, context: "Could not remove managed IPv4 routes")
            }
        }
    }

    func stopForApplicationTermination() async -> Bool {
        reconciliationGeneration &+= 1
        operation = .stopping
        defer { operation = nil }
        guard helper.isAvailable else {
            appendEventLog(
                "Managed route cleanup could not be verified because the network route helper is unavailable.",
                level: .error
            )
            return false
        }

        do {
            apply(try await client.stopForApplicationTermination())
            return snapshot?.state == .inactive
        } catch {
            report(
                error,
                context: "Could not remove managed IPv4 routes during application termination"
            )
            return false
        }
    }

    func resetForAppSettings() async throws {
        reconciliationGeneration &+= 1
        guestIPv4Address = nil
        isRNDISRouteReady = false

        helper.refresh()
        if helper.isAvailable {
            apply(try await client.stop())
            guard snapshot?.state == .inactive else {
                throw NetworkRouteSettingsResetError.routeRemovalIncomplete
            }
        }

        let status = try await helper.removeForAppSettings()
        guard status == .notRegistered || status == .notFound else {
            throw NetworkRouteSettingsResetError.helperRemovalIncomplete
        }
        snapshot = nil
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
        isRNDISRouteReady = false
        appendEventLog(
            "The privileged helper route lease was interrupted; clearing the guest route control path and attempting fail-safe cleanup.",
            level: .error
        )

        guard helper.isAvailable else {
            lastErrorMessage = String(
                localized: "The managed route lease ended while the network route helper was unavailable."
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
                    "Managed IPv4 routes were removed after the helper lease interruption.",
                    level: .info
                )
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(
                    error,
                    context: "Could not remove managed IPv4 routes after the helper lease interruption"
                )
            }
        }
    }

    private func reconcileIfNeeded(reason: String) {
        guard operation == nil else { return }
        guard helper.isAvailable else { return }
        guard let guestIPv4Address, isRNDISRouteReady else {
            if snapshot?.state == .active || snapshot?.state == .degraded {
                stop(reason: reason)
            }
            return
        }
        guard snapshot?.state != .active
                || snapshot?.guestIPv4Address != guestIPv4Address else {
            return
        }

        if snapshot?.state == .active {
            stop(reason: "guest VZNAT address changed")
            return
        }

        let generation = beginOperation(.starting)
        lastErrorMessage = nil
        appendEventLog(
            "Installing global and interface-scoped entries for "
                + "0.0.0.0/1 and 128.0.0.0/1 through guest "
                + "\(guestIPv4Address): \(reason).",
            level: .debug
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.start(
                    guestIPv4Address: guestIPv4Address
                )
                guard self.finishOperation(generation) else {
                    _ = try? await self.client.stop()
                    self.reconcileIfNeeded(
                        reason: "stale route start was cleaned up"
                    )
                    return
                }
                guard self.guestIPv4Address == guestIPv4Address,
                      self.isRNDISRouteReady else {
                    _ = try? await self.client.stop()
                    self.apply(.inactive)
                    self.reconcileIfNeeded(
                        reason: "route start completed after desired state changed"
                    )
                    return
                }
                self.apply(snapshot)
                self.appendEventLog(
                    "IPv4 traffic is routed through VZNAT guest \(guestIPv4Address) on \(snapshot.interfaceName ?? "unknown interface").",
                    level: .info
                )
            } catch {
                guard self.finishOperation(generation) else { return }
                self.report(error, context: "Could not install managed IPv4 routes")
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
            String(localized: "Wait for the current network helper operation to finish.")
        case .routeRemovalIncomplete:
            String(localized: "The managed IPv4 routes could not be removed.")
        case .helperRemovalIncomplete:
            String(localized: "The network route helper remained registered.")
        }
    }
}
