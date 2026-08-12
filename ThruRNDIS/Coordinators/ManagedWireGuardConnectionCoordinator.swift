/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

private enum ManagedWireGuardConnectionState: Equatable {
    case idle
    case preparingDummyEthernet(operationID: UUID)
    case waitingForTunnel(operationID: UUID)
    case stoppingDummyEthernet(operationID: UUID)

    var operationID: UUID? {
        switch self {
        case .preparingDummyEthernet(let operationID),
             .waitingForTunnel(let operationID),
             .stoppingDummyEthernet(let operationID):
            operationID
        case .idle:
            nil
        }
    }
}

@MainActor
final class ManagedWireGuardConnectionCoordinator {
    struct Actions {
        let refreshRuntimeEntitlements: () -> Void
        let canConnectWireGuardTunnel: () -> Bool
        let connectWireGuardTunnel: () -> Bool
    }

    private let wireGuardSession: WireGuardSessionStore
    private let dummyEthernet: DummyEthernetStore?
    private let eventLog: EventLogStore
    private let prepareDummyEthernet: (@MainActor () async -> Bool)?
    private let deactivateDummyEthernet: (@MainActor () async -> Void)?
    private let actions: Actions

    private var state: ManagedWireGuardConnectionState = .idle
    private var connectionTask: Task<Void, Never>?
    private var connectionTaskID: UUID?

    init(
        wireGuardSession: WireGuardSessionStore,
        dummyEthernet: DummyEthernetStore?,
        eventLog: EventLogStore,
        prepareDummyEthernet: (@MainActor () async -> Bool)?,
        deactivateDummyEthernet: (@MainActor () async -> Void)?,
        actions: Actions
    ) {
        self.wireGuardSession = wireGuardSession
        self.dummyEthernet = dummyEthernet
        self.eventLog = eventLog
        self.prepareDummyEthernet = prepareDummyEthernet
        self.deactivateDummyEthernet = deactivateDummyEthernet
        self.actions = actions
    }

    func connect() {
        guard actions.canConnectWireGuardTunnel() else { return }

        guard prepareDummyEthernet != nil || dummyEthernet != nil else {
            _ = actions.connectWireGuardTunnel()
            return
        }
        guard connectionTask == nil else { return }

        let operationID = UUID()
        state = .preparingDummyEthernet(operationID: operationID)
        connectionTaskID = operationID
        appendEventLog(
            "Preparing Dummy Ethernet before starting the WireGuard tunnel.",
            level: .debug
        )

        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.connectionTaskID == operationID {
                    self.connectionTask = nil
                    self.connectionTaskID = nil
                }
                if self.state.operationID == operationID {
                    self.state = .idle
                }
            }

            let isDummyEthernetActive: Bool
            if let prepareDummyEthernet {
                isDummyEthernetActive = await prepareDummyEthernet()
            } else if let dummyEthernet {
                isDummyEthernetActive = await dummyEthernet.startAndWaitUntilActive()
            } else {
                return
            }

            guard !Task.isCancelled,
                  self.state == .preparingDummyEthernet(operationID: operationID) else {
                return
            }
            guard isDummyEthernetActive else {
                self.appendEventLog(
                    "WireGuard tunnel not started: Dummy Ethernet did not become active.",
                    level: .error
                )
                return
            }

            self.actions.refreshRuntimeEntitlements()
            guard self.actions.canConnectWireGuardTunnel() else { return }
            guard self.actions.connectWireGuardTunnel() else { return }
            self.state = .waitingForTunnel(operationID: operationID)

            let tunnelUpdates = Publishers.CombineLatest(
                self.wireGuardSession.$tunnelStatus,
                self.wireGuardSession.$tunnelFailure
            )
            for await (status, failure) in tunnelUpdates.dropFirst().values {
                guard !Task.isCancelled,
                      self.state.operationID == operationID else {
                    return
                }
                guard failure == nil else {
                    return
                }

                switch status {
                case .connected:
                    self.state = .stoppingDummyEthernet(operationID: operationID)
                    self.appendEventLog(
                        "WireGuard tunnel connected; stopping automatically prepared Dummy Ethernet.",
                        level: .debug
                    )
                    if let deactivateDummyEthernet {
                        await deactivateDummyEthernet()
                    } else if let dummyEthernet {
                        _ = await dummyEthernet.stopAfterCurrentOperation()
                    }
                    return
                case .connecting:
                    continue
                case .disconnecting, .unconfigured, .disconnected:
                    return
                }
            }
        }
    }

    func cancel(reason: String) {
        guard connectionTask != nil || state.operationID != nil else {
            return
        }

        connectionTask?.cancel()
        connectionTask = nil
        connectionTaskID = nil
        state = .idle
        appendEventLog(
            "Pending automatic WireGuard connection cancelled: \(reason).",
            level: .debug
        )
    }

    private func appendEventLog(_ message: String, level: EventLogLevel) {
        eventLog.append(message, level: level, category: .wireGuard)
    }
}
