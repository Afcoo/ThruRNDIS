/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum DummyEthernetPrivilegedHelperClientError: Error, Equatable, LocalizedError {
    case applicationBundleIdentifierUnavailable
    case remoteObjectUnavailable(message: String?)
    case malformedResponse
    case requestTimedOut
    case helperFailure(message: String)

    var errorDescription: String? {
        switch self {
        case .applicationBundleIdentifierUnavailable:
            return String(
                localized: "The ThruRNDIS bundle identifier is unavailable."
            )
        case .remoteObjectUnavailable(let message):
            let summary = String(
                localized: "The Dummy Ethernet helper XPC interface is unavailable."
            )
            if let message, !message.isEmpty {
                return "\(summary) \(message)"
            }
            return summary
        case .malformedResponse:
            return String(
                localized: "The Dummy Ethernet helper returned an incomplete response."
            )
        case .requestTimedOut:
            return String(
                localized: "The Dummy Ethernet helper did not respond before the request timed out."
            )
        case .helperFailure(let message):
            return message
        }
    }
}

@MainActor
final class DummyEthernetPrivilegedHelperClient {
    private static let statusRequestTimeout: DispatchTimeInterval = .seconds(10)
    // A normal start may spend 3 seconds waiting for its Bond and another
    // 12 seconds waiting for the wired network path before replying.
    private static let startRequestTimeout: DispatchTimeInterval = .seconds(20)
    private static let stopRequestTimeout: DispatchTimeInterval = .seconds(10)

    func status() async throws -> DummyEthernetNetworkSnapshot {
        try await sendRequest(
            timeout: Self.statusRequestTimeout
        ) { proxy, reply in
            proxy.status(withReply: reply)
        }
    }

    func start(
        configuration: DummyEthernetConfiguration
    ) async throws -> DummyEthernetNetworkSnapshot {
        do {
            return try await sendRequest(
                timeout: Self.startRequestTimeout
            ) { proxy, reply in
                proxy.start(
                    hostIPv4Address: configuration.hostIPv4Address,
                    memberInterfaceName: configuration.memberInterfaceName,
                    peerInterfaceName: configuration.peerInterfaceName,
                    withReply: reply
                )
            }
        } catch let error as DummyEthernetPrivilegedHelperClientError
            where error == .requestTimedOut {
            // The helper may still finish a queued Start after the client timeout.
            // Queue a bounded Stop so that late completion cannot leave it active.
            _ = try? await stop()
            throw error
        }
    }

    func stop() async throws -> DummyEthernetNetworkSnapshot {
        try await sendRequest(
            timeout: Self.stopRequestTimeout
        ) { proxy, reply in
            proxy.stop(withReply: reply)
        }
    }

    private static func decodeSnapshot(
        from data: Data
    ) throws -> DummyEthernetNetworkSnapshot {
        do {
            return try JSONDecoder().decode(
                DummyEthernetNetworkSnapshot.self,
                from: data
            )
        } catch {
            throw DummyEthernetPrivilegedHelperClientError.malformedResponse
        }
    }

    private func sendRequest(
        timeout requestTimeout: DispatchTimeInterval,
        _ request: @escaping (
            DummyEthernetPrivilegedHelperProtocol,
            @escaping DummyEthernetPrivilegedHelperReply
        ) -> Void
    ) async throws -> DummyEthernetNetworkSnapshot {
        let connection = try makeConnection()
        let data: Data = try await withCheckedThrowingContinuation {
            continuation in
            let reply = DummyEthernetXPCReply(
                connection: connection,
                continuation: continuation
            )
            connection.interruptionHandler = {
                reply.resume(with: .failure(
                    DummyEthernetPrivilegedHelperClientError
                        .remoteObjectUnavailable(message: nil)
                ))
            }
            connection.invalidationHandler = {
                reply.resume(with: .failure(
                    DummyEthernetPrivilegedHelperClientError
                        .remoteObjectUnavailable(message: nil)
                ))
            }
            connection.activate()

            let remoteObject = connection.remoteObjectProxyWithErrorHandler {
                error in
                reply.resume(with: .failure(
                    DummyEthernetPrivilegedHelperClientError
                        .remoteObjectUnavailable(
                            message: error.localizedDescription
                        )
                ))
            }
            guard let proxy = remoteObject
                as? DummyEthernetPrivilegedHelperProtocol else {
                reply.resume(with: .failure(
                    DummyEthernetPrivilegedHelperClientError
                        .remoteObjectUnavailable(message: nil)
                ))
                return
            }
            request(proxy) { data, failureMessage in
                if let failureMessage {
                    reply.resume(with: .failure(
                        DummyEthernetPrivilegedHelperClientError.helperFailure(
                            message: failureMessage
                        )
                    ))
                } else if let data {
                    reply.resume(with: .success(data))
                } else {
                    reply.resume(with: .failure(
                        DummyEthernetPrivilegedHelperClientError
                            .malformedResponse
                    ))
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + requestTimeout
            ) { [weak reply] in
                reply?.resume(with: .failure(
                    DummyEthernetPrivilegedHelperClientError.requestTimedOut
                ))
            }
        }
        return try Self.decodeSnapshot(from: data)
    }

    private func makeConnection() throws -> NSXPCConnection {
        guard let applicationBundleIdentifier = Bundle.main.bundleIdentifier,
              !applicationBundleIdentifier.isEmpty else {
            throw DummyEthernetPrivilegedHelperClientError
                .applicationBundleIdentifierUnavailable
        }
        let helperIdentifier = ThruRNDISDummyEthernet.helperBundleIdentifier(
            derivedFrom: applicationBundleIdentifier
        )
        let connection = NSXPCConnection(
            machServiceName: helperIdentifier,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: DummyEthernetPrivilegedHelperProtocol.self
        )
        connection.setCodeSigningRequirement(
            try PeerCodeSigningRequirementBuilder.requirement(
                forPeerIdentifier: helperIdentifier
            )
        )
        return connection
    }
}

private final class DummyEthernetXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var continuation: CheckedContinuation<Data, Error>?

    init(
        connection: NSXPCConnection,
        continuation: CheckedContinuation<Data, Error>
    ) {
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
        connection?.invalidate()
        continuation.resume(with: result)
    }
}
