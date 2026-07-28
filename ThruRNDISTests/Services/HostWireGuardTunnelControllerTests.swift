import XCTest
@preconcurrency import SystemExtensions
@testable import ThruRNDIS

@MainActor
final class HostWireGuardTunnelControllerTests: XCTestCase {
    func testSystemExtensionPropertiesRequireEnabledNonUninstallingVersion() {
        XCTAssertEqual(
            WireGuardSystemExtensionActivator.status(from: []),
            .inactive
        )
        XCTAssertEqual(
            WireGuardSystemExtensionActivator.status(from: [
                WireGuardSystemExtensionPropertySnapshot(
                    isEnabled: false,
                    isAwaitingUserApproval: false,
                    isUninstalling: false
                ),
            ]),
            .inactive
        )
        XCTAssertEqual(
            WireGuardSystemExtensionActivator.status(from: [
                WireGuardSystemExtensionPropertySnapshot(
                    isEnabled: false,
                    isAwaitingUserApproval: true,
                    isUninstalling: false
                ),
            ]),
            .awaitingUserApproval
        )
        XCTAssertEqual(
            WireGuardSystemExtensionActivator.status(from: [
                WireGuardSystemExtensionPropertySnapshot(
                    isEnabled: true,
                    isAwaitingUserApproval: false,
                    isUninstalling: true
                ),
            ]),
            .uninstalling
        )
        XCTAssertEqual(
            WireGuardSystemExtensionActivator.status(from: [
                WireGuardSystemExtensionPropertySnapshot(
                    isEnabled: true,
                    isAwaitingUserApproval: false,
                    isUninstalling: false
                ),
            ]),
            .active
        )
    }

    func testActivationInvalidatesPreActivationStatusRequest() async throws {
        var submittedRequests: [OSSystemExtensionRequest] = []
        let activator = WireGuardSystemExtensionActivator { request in
            submittedRequests.append(request)
        }
        let bundleIdentifier = "com.example.ThruRNDIS.network-extension"

        let firstStatusTask = Task {
            try await activator.status(bundleIdentifier: bundleIdentifier)
        }
        await Task.yield()
        let firstStatusRequest = try XCTUnwrap(submittedRequests.first)

        let activationTask = Task {
            try await activator.activate(bundleIdentifier: bundleIdentifier)
        }
        await Task.yield()

        XCTAssertEqual(submittedRequests.count, 2)
        do {
            _ = try await firstStatusTask.value
            XCTFail("The pre-activation status request should be cancelled.")
        } catch is CancellationError {
            // Expected: activation supersedes the pre-activation snapshot.
        }

        let activationRequest = submittedRequests[1]
        activator.request(activationRequest, didFinishWithResult: .completed)
        try await activationTask.value

        var didCompleteSecondStatus = false
        let secondStatusTask = Task {
            let status = try await activator.status(bundleIdentifier: bundleIdentifier)
            didCompleteSecondStatus = true
            return status
        }
        await Task.yield()

        XCTAssertEqual(submittedRequests.count, 3)
        let secondStatusRequest = submittedRequests[2]

        activator.request(firstStatusRequest, foundProperties: [])
        await Task.yield()
        XCTAssertFalse(didCompleteSecondStatus)

        activator.request(secondStatusRequest, foundProperties: [])
        let secondStatus = try await secondStatusTask.value
        XCTAssertEqual(secondStatus, .inactive)
        XCTAssertTrue(didCompleteSecondStatus)
    }

    func testCompletedActivationPublishesVerifiedInactiveStatus() async throws {
        var submittedRequests: [OSSystemExtensionRequest] = []
        let activator = WireGuardSystemExtensionActivator { request in
            submittedRequests.append(request)
        }
        let controller = HostWireGuardTunnelController(
            systemExtensionActivator: activator
        )
        var statuses: [WireGuardSystemExtensionStatus] = []
        controller.onSystemExtensionStatusChange = { statuses.append($0) }

        let activationTask = Task {
            await controller.activateSystemExtension()
        }
        await Task.yield()

        let activationRequest = try XCTUnwrap(submittedRequests.first)
        activator.request(activationRequest, didFinishWithResult: .completed)
        for _ in 0..<10 {
            guard submittedRequests.count < 2 else {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(submittedRequests.count, 2)
        let propertiesRequest = submittedRequests[1]
        activator.request(propertiesRequest, foundProperties: [])
        await activationTask.value

        XCTAssertEqual(statuses, [.activationRequested, .inactive])
        XCTAssertFalse(statuses.contains(.active))
    }

    func testApprovalCallbackDoesNotOverrideVerifiedInactiveStatus() async throws {
        var submittedRequests: [OSSystemExtensionRequest] = []
        let activator = WireGuardSystemExtensionActivator { request in
            submittedRequests.append(request)
        }
        let controller = HostWireGuardTunnelController(
            systemExtensionActivator: activator
        )
        var statuses: [WireGuardSystemExtensionStatus] = []
        controller.onSystemExtensionStatusChange = { statuses.append($0) }

        let activationTask = Task {
            await controller.activateSystemExtension()
        }
        await Task.yield()

        let activationRequest = try XCTUnwrap(submittedRequests.first)
        activator.requestNeedsUserApproval(activationRequest)
        activator.request(activationRequest, didFinishWithResult: .completed)
        for _ in 0..<10 {
            guard submittedRequests.count < 2 else {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(submittedRequests.count, 2)
        let propertiesRequest = submittedRequests[1]
        activator.request(propertiesRequest, foundProperties: [])
        await activationTask.value

        XCTAssertEqual(
            statuses,
            [.activationRequested, .awaitingUserApproval, .inactive]
        )
        XCTAssertFalse(statuses.contains(.active))
    }

    func testActivationStatusVerificationFailureFailsClosed() async throws {
        var submittedRequests: [OSSystemExtensionRequest] = []
        let activator = WireGuardSystemExtensionActivator { request in
            submittedRequests.append(request)
        }
        let controller = HostWireGuardTunnelController(
            systemExtensionActivator: activator
        )
        var statuses: [WireGuardSystemExtensionStatus] = []
        controller.onSystemExtensionStatusChange = { statuses.append($0) }

        let activationTask = Task {
            await controller.activateSystemExtension()
        }
        await Task.yield()

        let activationRequest = try XCTUnwrap(submittedRequests.first)
        activator.request(activationRequest, didFinishWithResult: .completed)
        for _ in 0..<10 {
            guard submittedRequests.count < 2 else {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(submittedRequests.count, 2)
        let propertiesRequest = submittedRequests[1]
        activator.request(
            propertiesRequest,
            didFailWithError: NSError(
                domain: "SystemExtensionProperties",
                code: 17
            )
        )
        await activationTask.value

        XCTAssertEqual(statuses.first, .activationRequested)
        guard case .failed = statuses.last else {
            return XCTFail("A failed post-activation status query must fail closed.")
        }
        XCTAssertFalse(statuses.contains(.active))
    }

    func testInvalidationDuringActivationVerificationIgnoresLateProperties() async throws {
        var submittedRequests: [OSSystemExtensionRequest] = []
        let activator = WireGuardSystemExtensionActivator { request in
            submittedRequests.append(request)
        }
        let controller = HostWireGuardTunnelController(
            systemExtensionActivator: activator
        )
        var statuses: [WireGuardSystemExtensionStatus] = []
        controller.onSystemExtensionStatusChange = { statuses.append($0) }

        let activationTask = Task {
            await controller.activateSystemExtension()
        }
        await Task.yield()

        let activationRequest = try XCTUnwrap(submittedRequests.first)
        activator.request(activationRequest, didFinishWithResult: .completed)
        for _ in 0..<10 {
            guard submittedRequests.count < 2 else {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(submittedRequests.count, 2)
        let propertiesRequest = submittedRequests[1]
        controller.invalidateSystemExtensionOperations()
        activator.request(propertiesRequest, foundProperties: [])
        await activationTask.value

        XCTAssertEqual(statuses, [.activationRequested])
        XCTAssertFalse(statuses.contains(.inactive))
        XCTAssertFalse(statuses.contains(.active))
    }

    func testConnectFailsClosedForEveryNonActiveSystemExtensionStatus() async {
        let nonActiveStatuses: [WireGuardSystemExtensionStatus] = [
            .unknown,
            .checking,
            .inactive,
            .activationRequested,
            .awaitingUserApproval,
            .uninstalling,
            .restartRequired,
            .failed("query failed"),
        ]

        for status in nonActiveStatuses {
            let activator = ImmediateWireGuardSystemExtensionActivator(status: status)
            let controller = HostWireGuardTunnelController(
                systemExtensionActivator: activator
            )
            var providerStatuses: [HostWireGuardTunnelStatus] = []
            var systemExtensionStatuses: [WireGuardSystemExtensionStatus] = []
            controller.onStatusChange = { providerStatuses.append($0) }
            controller.onSystemExtensionStatusChange = {
                systemExtensionStatuses.append($0)
            }

            await controller.connect(wgQuickConfiguration: """
            [Interface]
            PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            Address = 10.100.0.2/32

            [Peer]
            PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            AllowedIPs = 0.0.0.0/0
            Endpoint = 192.168.64.2:51820
            """)

            XCTAssertEqual(activator.activationCallCount, 1)
            XCTAssertEqual(activator.statusCallCount, 1)
            XCTAssertEqual(systemExtensionStatuses.last, status)
            XCTAssertFalse(providerStatuses.contains(.connecting))
            guard case .failed = providerStatuses.last else {
                XCTFail("Connect must fail before starting a provider for \(status).")
                continue
            }
        }
    }

    func testCancelledConnectRefreshesTransientSystemExtensionStatus() async throws {
        var submittedRequests: [OSSystemExtensionRequest] = []
        let activator = WireGuardSystemExtensionActivator { request in
            submittedRequests.append(request)
        }
        let controller = HostWireGuardTunnelController(
            systemExtensionActivator: activator
        )
        var statuses: [WireGuardSystemExtensionStatus] = []
        controller.onSystemExtensionStatusChange = { statuses.append($0) }

        let connectTask = Task {
            await controller.connect(wgQuickConfiguration: """
            [Interface]
            PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            Address = 10.100.0.2/32

            [Peer]
            PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            AllowedIPs = 0.0.0.0/0
            Endpoint = 192.168.64.2:51820
            """)
        }
        await Task.yield()

        let activationRequest = try XCTUnwrap(submittedRequests.first)
        XCTAssertEqual(statuses, [.activationRequested])

        connectTask.cancel()
        activator.request(activationRequest, didFinishWithResult: .completed)
        for _ in 0..<10 {
            guard submittedRequests.count < 2 else {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(submittedRequests.count, 2)
        let propertiesRequest = submittedRequests[1]
        activator.request(propertiesRequest, foundProperties: [])
        await connectTask.value
        for _ in 0..<10 {
            guard statuses.last != .inactive else {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(statuses, [.activationRequested, .checking, .inactive])
    }

    func testInvalidationIgnoresLateActivationApprovalAndCompletion() async throws {
        var submittedRequests: [OSSystemExtensionRequest] = []
        let activator = WireGuardSystemExtensionActivator { request in
            submittedRequests.append(request)
        }
        let controller = HostWireGuardTunnelController(
            systemExtensionActivator: activator
        )
        var statuses: [WireGuardSystemExtensionStatus] = []
        controller.onSystemExtensionStatusChange = { statuses.append($0) }

        let activationTask = Task {
            await controller.activateSystemExtension()
        }
        await Task.yield()

        let request = try XCTUnwrap(submittedRequests.first)
        XCTAssertEqual(statuses, [.activationRequested])
        XCTAssertEqual(activator.replacementAction(for: request), .replace)

        controller.invalidateSystemExtensionOperations()
        XCTAssertEqual(activator.replacementAction(for: request), .cancel)
        activator.requestNeedsUserApproval(request)
        activator.request(request, didFinishWithResult: .completed)
        await activationTask.value

        XCTAssertFalse(statuses.contains(.awaitingUserApproval))
        XCTAssertFalse(statuses.contains(.active))
    }

    func testDisconnectDiagnosticPreservesDomainCodeAndUnderlyingError() {
        let underlying = NSError(
            domain: "WireGuardBackend",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "백엔드 실패"]
        )
        let error = NSError(
            domain: "NetworkExtension",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "프로바이더 연결 해제",
                NSUnderlyingErrorKey: underlying,
            ]
        )

        let diagnostic = HostWireGuardTunnelController.diagnosticDescription(for: error)

        XCTAssertTrue(diagnostic.contains("domain=NetworkExtension"))
        XCTAssertTrue(diagnostic.contains("code=42"))
        XCTAssertTrue(diagnostic.contains("underlyingDomain=WireGuardBackend"))
        XCTAssertTrue(diagnostic.contains("underlyingCode=7"))
        XCTAssertFalse(diagnostic.contains("프로바이더"))
        XCTAssertFalse(diagnostic.contains("백엔드"))
    }

}

@MainActor
private final class ImmediateWireGuardSystemExtensionActivator:
    WireGuardSystemExtensionActivating {
    var onEventLog: EventLogHandler?
    var onActivationNeedsUserApproval: (() -> Void)?
    private(set) var statusCallCount = 0
    private(set) var activationCallCount = 0

    private let currentStatus: WireGuardSystemExtensionStatus

    init(status: WireGuardSystemExtensionStatus) {
        currentStatus = status
    }

    func status(bundleIdentifier: String) async throws -> WireGuardSystemExtensionStatus {
        statusCallCount += 1
        return currentStatus
    }

    func activate(bundleIdentifier: String) async throws {
        activationCallCount += 1
    }

    func cancelPendingRequests() {}
}
