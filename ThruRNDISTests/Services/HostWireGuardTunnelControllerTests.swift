import XCTest
@testable import ThruRNDIS

@MainActor
final class HostWireGuardTunnelControllerTests: XCTestCase {
    func testTransitionStatesExposeExpectedActions() {
        XCTAssertTrue(HostWireGuardTunnelStatus.activatingSystemExtension.canRequestStop)
        XCTAssertTrue(HostWireGuardTunnelStatus.reasserting.isTransitioning)
        XCTAssertTrue(HostWireGuardTunnelStatus.reasserting.canRequestStop)
        XCTAssertFalse(HostWireGuardTunnelStatus.disconnecting.canRequestStop)
        XCTAssertTrue(HostWireGuardTunnelStatus.failed("ambiguous provider state").canRequestStop)
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

    func testProviderEventLogDescriptionsRemainEnglish() {
        XCTAssertEqual(
            HostWireGuardTunnelStatus.unconfigured.eventLogDescription,
            "Not configured — Start the VM and wait for its WireGuard endpoint."
        )
        XCTAssertEqual(
            HostWireGuardTunnelStatus.failed("domain=Test; code=1").eventLogDescription,
            "Failed — domain=Test; code=1"
        )
        XCTAssertEqual(
            HostWireGuardTunnelStatus.missingPacketTunnelEntitlement.eventLogDescription,
            "Failed — NetworkExtension packet tunnel entitlement is missing."
        )
        XCTAssertEqual(
            HostWireGuardTunnelStatus.missingSystemExtensionInstallEntitlement.eventLogDescription,
            "Failed — System Extension installation entitlement is missing."
        )
    }
}
