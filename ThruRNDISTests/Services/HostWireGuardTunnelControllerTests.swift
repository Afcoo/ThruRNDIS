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

}
