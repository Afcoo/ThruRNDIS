/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

final class NetworkRoutePrivilegedHelperService: NSObject,
    NetworkRoutePrivilegedHelperProtocol {
    private let controller: NetworkRouteController
    private let leaseState = NetworkRouteConnectionLeaseState()

    init(controller: NetworkRouteController) {
        self.controller = controller
        super.init()
    }

    func status(withReply reply: @escaping NetworkRoutePrivilegedHelperReply) {
        controller.status { result in
            Self.send(result, to: reply)
        }
    }

    func start(
        guestIPv4Address: String,
        vznatGatewayIPv4Address: String,
        withReply reply: @escaping NetworkRoutePrivilegedHelperReply
    ) {
        controller.start(
            guestIPv4Address: guestIPv4Address,
            vznatGatewayIPv4Address: vznatGatewayIPv4Address,
            leaseOwnerIdentifier: leaseState.identifier
        ) { [self] result in
            if case .success = result,
               leaseState.markStartSucceeded() {
                // The connection disappeared while start was in flight. The
                // serialized controller call runs after start and is keyed to
                // this lease, so it cannot remove a newer owner's routes.
                controller.stop(
                    leaseOwnerIdentifier: leaseState.identifier
                ) { _ in }
            }
            Self.send(result, to: reply)
        }
    }

    func stop(withReply reply: @escaping NetworkRoutePrivilegedHelperReply) {
        controller.stop(
            leaseOwnerIdentifier: leaseState.ownerIdentifierForStop()
        ) { [self] result in
            if case .success = result {
                leaseState.markStopSucceeded()
            }
            Self.send(result, to: reply)
        }
    }

    func connectionDidTerminate() {
        guard leaseState.markConnectionTerminated() else { return }
        controller.stop(leaseOwnerIdentifier: leaseState.identifier) { _ in }
    }

    private static func send(
        _ result: Result<NetworkRouteSnapshot, Error>,
        to reply: @escaping NetworkRoutePrivilegedHelperReply
    ) {
        switch result {
        case .success(let snapshot):
            do {
                reply(try JSONEncoder().encode(snapshot), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        case .failure(let error):
            reply(nil, error.localizedDescription)
        }
    }
}

private final class NetworkRouteConnectionLeaseState: @unchecked Sendable {
    let identifier = UUID()

    private let lock = NSLock()
    private var connectionTerminated = false
    private var ownsLease = false

    /// Returns true when cleanup must be scheduled after a successful start.
    func markStartSucceeded() -> Bool {
        lock.lock()
        ownsLease = true
        let shouldCleanUp = connectionTerminated
        lock.unlock()
        return shouldCleanUp
    }

    func ownerIdentifierForStop() -> UUID? {
        lock.lock()
        let result = ownsLease ? identifier : nil
        lock.unlock()
        return result
    }

    func markStopSucceeded() {
        lock.lock()
        ownsLease = false
        lock.unlock()
    }

    /// Returns true exactly once when this connection already owns a lease.
    func markConnectionTerminated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !connectionTerminated else { return false }
        connectionTerminated = true
        return ownsLease
    }
}

final class NetworkRoutePrivilegedHelperListenerDelegate: NSObject,
    NSXPCListenerDelegate {
    private let controller: NetworkRouteController

    init(controller: NetworkRouteController) {
        self.controller = controller
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: NetworkRoutePrivilegedHelperProtocol.self
        )
        let service = NetworkRoutePrivilegedHelperService(
            controller: controller
        )
        newConnection.exportedObject = service
        newConnection.interruptionHandler = { [service] in
            service.connectionDidTerminate()
        }
        newConnection.invalidationHandler = { [service] in
            service.connectionDidTerminate()
        }
        newConnection.activate()
        return true
    }
}
