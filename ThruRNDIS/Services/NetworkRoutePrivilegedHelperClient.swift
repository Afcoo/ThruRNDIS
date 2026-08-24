/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum NetworkRoutePrivilegedHelperClientError: Error, Equatable, LocalizedError {
    case applicationBundleIdentifierUnavailable
    case remoteObjectUnavailable(message: String?)
    case malformedResponse
    case requestTimedOut
    case helperFailure(message: String)

    var errorDescription: String? {
        switch self {
        case .applicationBundleIdentifierUnavailable:
            String(localized: "The ThruRNDIS bundle identifier is unavailable.")
        case .remoteObjectUnavailable(let message):
            if let message, !message.isEmpty {
                String(localized: "The Network Helper is unavailable. \(message)")
            } else {
                String(localized: "The Network Helper is unavailable.")
            }
        case .malformedResponse:
            String(localized: "The Network Helper returned an incomplete response.")
        case .requestTimedOut:
            String(localized: "The Network Helper did not respond before the request timed out.")
        case .helperFailure(let message):
            message
        }
    }

    var diagnosticDescription: String {
        errorDescription ?? String(describing: self)
    }
}

@MainActor
final class NetworkRoutePrivilegedHelperClient {
    private static let statusRequestTimeout: DispatchTimeInterval = .seconds(5)
    private static let startRequestTimeout: DispatchTimeInterval = .seconds(30)
    private static let stopRequestTimeout: DispatchTimeInterval = .seconds(15)
    private static let terminationStopRequestTimeout: DispatchTimeInterval =
        .seconds(5)

    var onLeaseInvalidated: (() -> Void)?

    private var leaseConnection: NSXPCConnection?
    private var isLeaseActive = false

    func status() async throws -> NetworkRouteSnapshot {
        try await sendTransientRequest(
            timeout: Self.statusRequestTimeout
        ) { proxy, reply in
            proxy.status(withReply: reply)
        }
    }

    func start(
        guestIPv4Address: String,
        vznatGatewayIPv4Address: String
    ) async throws -> NetworkRouteSnapshot {
        let hadActiveLease = isLeaseActive
        let connection: NSXPCConnection
        let shouldActivate: Bool
        if let leaseConnection {
            connection = leaseConnection
            shouldActivate = false
        } else {
            connection = try makeConnection()
            leaseConnection = connection
            isLeaseActive = false
            shouldActivate = true
        }

        do {
            let snapshot = try await sendRequest(
                over: connection,
                timeout: Self.startRequestTimeout,
                invalidateOnReply: false,
                monitorLease: true,
                activateConnection: shouldActivate
            ) { proxy, reply in
                proxy.start(
                    guestIPv4Address: guestIPv4Address,
                    vznatGatewayIPv4Address: vznatGatewayIPv4Address,
                    withReply: reply
                )
            }

            guard leaseConnection === connection else {
                if !hadActiveLease {
                    onLeaseInvalidated?()
                }
                _ = try? await sendTransientStop(
                    timeout: Self.stopRequestTimeout
                )
                throw NetworkRoutePrivilegedHelperClientError
                    .remoteObjectUnavailable(message: nil)
            }
            isLeaseActive = true
            return snapshot
        } catch {
            abandonLease(connection, notify: false)
            // A timeout or transport failure can race a successful helper-side
            // start. A fresh connection lets a restarted helper rediscover and
            // remove only the routes carrying our ownership signature.
            _ = try? await sendTransientStop(timeout: Self.stopRequestTimeout)
            throw error
        }
    }

    func stop() async throws -> NetworkRouteSnapshot {
        try await stop(timeout: Self.stopRequestTimeout)
    }

    func stopForApplicationTermination() async throws -> NetworkRouteSnapshot {
        try await stop(timeout: Self.terminationStopRequestTimeout)
    }

    func stopRegisteredHelperBeforeReplacement() async throws {
        _ = try await sendTransientDataRequest(
            timeout: Self.stopRequestTimeout
        ) { proxy, reply in
            proxy.stop(withReply: reply)
        }
    }

    private func stop(
        timeout: DispatchTimeInterval
    ) async throws -> NetworkRouteSnapshot {
        guard let connection = leaseConnection else {
            return try await sendTransientStop(timeout: timeout)
        }

        do {
            let snapshot = try await sendRequest(
                over: connection,
                timeout: timeout,
                invalidateOnReply: false,
                monitorLease: true,
                activateConnection: false
            ) { proxy, reply in
                proxy.stop(withReply: reply)
            }
            if leaseConnection === connection {
                leaseConnection = nil
                isLeaseActive = false
                connection.interruptionHandler = nil
                connection.invalidationHandler = nil
                connection.invalidate()
            }
            return snapshot
        } catch let error as NetworkRoutePrivilegedHelperClientError {
            switch error {
            case .requestTimedOut, .remoteObjectUnavailable, .malformedResponse:
                abandonLease(connection, notify: true)
            case .applicationBundleIdentifierUnavailable, .helperFailure:
                break
            }
            throw error
        }
    }

    private func sendTransientStop(
        timeout: DispatchTimeInterval
    ) async throws -> NetworkRouteSnapshot {
        try await sendTransientRequest(timeout: timeout) { proxy, reply in
            proxy.stop(withReply: reply)
        }
    }

    private func sendTransientRequest(
        timeout: DispatchTimeInterval,
        _ request: @escaping (
            NetworkRoutePrivilegedHelperProtocol,
            @escaping NetworkRoutePrivilegedHelperReply
        ) -> Void
    ) async throws -> NetworkRouteSnapshot {
        let data = try await sendTransientDataRequest(
            timeout: timeout,
            request
        )
        return try decodeSnapshot(data)
    }

    private func sendTransientDataRequest(
        timeout: DispatchTimeInterval,
        _ request: @escaping (
            NetworkRoutePrivilegedHelperProtocol,
            @escaping NetworkRoutePrivilegedHelperReply
        ) -> Void
    ) async throws -> Data {
        let connection = try makeConnection()
        return try await sendDataRequest(
            over: connection,
            timeout: timeout,
            invalidateOnReply: true,
            monitorLease: false,
            activateConnection: true,
            request
        )
    }

    private func sendRequest(
        over connection: NSXPCConnection,
        timeout: DispatchTimeInterval,
        invalidateOnReply: Bool,
        monitorLease: Bool,
        activateConnection: Bool,
        _ request: @escaping (
            NetworkRoutePrivilegedHelperProtocol,
            @escaping NetworkRoutePrivilegedHelperReply
        ) -> Void
    ) async throws -> NetworkRouteSnapshot {
        let data = try await sendDataRequest(
            over: connection,
            timeout: timeout,
            invalidateOnReply: invalidateOnReply,
            monitorLease: monitorLease,
            activateConnection: activateConnection,
            request
        )
        return try decodeSnapshot(data)
    }

    private func sendDataRequest(
        over connection: NSXPCConnection,
        timeout: DispatchTimeInterval,
        invalidateOnReply: Bool,
        monitorLease: Bool,
        activateConnection: Bool,
        _ request: @escaping (
            NetworkRoutePrivilegedHelperProtocol,
            @escaping NetworkRoutePrivilegedHelperReply
        ) -> Void
    ) async throws -> Data {
        let data: Data = try await withCheckedThrowingContinuation {
            continuation in
            let reply = NetworkRouteXPCReply(
                connection: connection,
                invalidateOnReply: invalidateOnReply,
                continuation: continuation
            )
            connection.interruptionHandler = { [weak self, weak connection] in
                reply.resume(
                    with: .failure(
                        NetworkRoutePrivilegedHelperClientError
                            .remoteObjectUnavailable(message: nil)
                    )
                )
                guard monitorLease, let connection else { return }
                DispatchQueue.main.async { [weak self, weak connection] in
                    guard let connection else { return }
                    self?.leaseConnectionDidTerminate(connection)
                }
            }
            connection.invalidationHandler = { [weak self, weak connection] in
                reply.resume(
                    with: .failure(
                        NetworkRoutePrivilegedHelperClientError
                            .remoteObjectUnavailable(message: nil)
                    )
                )
                guard monitorLease, let connection else { return }
                DispatchQueue.main.async { [weak self, weak connection] in
                    guard let connection else { return }
                    self?.leaseConnectionDidTerminate(connection)
                }
            }
            if activateConnection {
                connection.activate()
            }

            let remoteObject = connection.remoteObjectProxyWithErrorHandler {
                error in
                let nsError = error as NSError
                reply.resume(
                    with: .failure(
                        NetworkRoutePrivilegedHelperClientError
                            .remoteObjectUnavailable(
                                message: "domain=\(nsError.domain), code=\(nsError.code)"
                            )
                    )
                )
            }
            guard let proxy = remoteObject
                as? NetworkRoutePrivilegedHelperProtocol else {
                reply.resume(
                    with: .failure(
                        NetworkRoutePrivilegedHelperClientError
                            .remoteObjectUnavailable(message: nil)
                    )
                )
                return
            }

            request(proxy) { data, failureMessage in
                if let failureMessage {
                    reply.resume(
                        with: .failure(
                            NetworkRoutePrivilegedHelperClientError
                                .helperFailure(message: failureMessage)
                        )
                    )
                } else if let data {
                    reply.resume(with: .success(data))
                } else {
                    reply.resume(
                        with: .failure(
                            NetworkRoutePrivilegedHelperClientError
                                .malformedResponse
                        )
                    )
                }
            }

            DispatchQueue.global().asyncAfter(
                deadline: DispatchTime.now() + timeout
            ) { [weak reply] in
                reply?.resume(
                    with: .failure(
                        NetworkRoutePrivilegedHelperClientError.requestTimedOut
                    )
                )
            }
        }

        return data
    }

    private func decodeSnapshot(_ data: Data) throws -> NetworkRouteSnapshot {
        do {
            return try JSONDecoder().decode(NetworkRouteSnapshot.self, from: data)
        } catch {
            throw NetworkRoutePrivilegedHelperClientError.malformedResponse
        }
    }

    private func leaseConnectionDidTerminate(_ connection: NSXPCConnection) {
        guard leaseConnection === connection else { return }
        let shouldNotify = isLeaseActive
        leaseConnection = nil
        isLeaseActive = false
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
        if shouldNotify {
            onLeaseInvalidated?()
        }
    }

    private func abandonLease(
        _ connection: NSXPCConnection,
        notify: Bool
    ) {
        guard leaseConnection === connection else { return }
        let shouldNotify = notify && isLeaseActive
        leaseConnection = nil
        isLeaseActive = false
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
        if shouldNotify {
            onLeaseInvalidated?()
        }
    }

    private func makeConnection() throws -> NSXPCConnection {
        guard let applicationBundleIdentifier = Bundle.main.bundleIdentifier,
              !applicationBundleIdentifier.isEmpty else {
            throw NetworkRoutePrivilegedHelperClientError
                .applicationBundleIdentifierUnavailable
        }
        let helperIdentifier = ThruRNDISNetworkRoute.helperBundleIdentifier(
            derivedFrom: applicationBundleIdentifier
        )
        let connection = NSXPCConnection(
            machServiceName: helperIdentifier,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: NetworkRoutePrivilegedHelperProtocol.self
        )
        connection.setCodeSigningRequirement(
            try PeerCodeSigningRequirementBuilder.requirement(
                forPeerIdentifier: helperIdentifier
            )
        )
        return connection
    }
}

private final class NetworkRouteXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private let invalidateOnReply: Bool
    private var connection: NSXPCConnection?
    private var continuation: CheckedContinuation<Data, Error>?

    init(
        connection: NSXPCConnection,
        invalidateOnReply: Bool,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.invalidateOnReply = invalidateOnReply
        self.connection = connection
        self.continuation = continuation
    }

    func resume(with result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation
        let connection = self.connection
        self.continuation = nil
        self.connection = nil
        lock.unlock()

        guard let continuation else { return }
        if invalidateOnReply {
            connection?.invalidate()
        }
        continuation.resume(with: result)
    }
}
