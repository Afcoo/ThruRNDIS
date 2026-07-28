/*
Copyright (C) 2026 Afcoo.
*/

import XCTest
@testable import ThruRNDIS

final class MenuBarCombinedStatusTests: XCTestCase {
    func testCombinedStatusTruthTable() {
        let scenarios: [CombinedStatusScenario] = [
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: false,
                wireGuardTunnelStatus: .disconnected,
                expectedActivity: .inactive,
                expectedStage: .inactive
            ),
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: false,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .partiallyActive,
                expectedStage: .inactive
            ),
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: true,
                wireGuardTunnelStatus: .disconnected,
                expectedActivity: .partiallyActive,
                expectedStage: .inactive
            ),
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: true,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .partiallyActive,
                expectedStage: .inactive
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: false,
                wireGuardTunnelStatus: .disconnected,
                expectedActivity: .partiallyActive,
                expectedStage: .usbNotAttached
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: false,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .partiallyActive,
                expectedStage: .usbNotAttached
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                wireGuardTunnelStatus: .disconnected,
                expectedActivity: .partiallyActive,
                expectedStage: .wireGuardDisconnected
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .active,
                expectedStage: .active
            ),
        ]

        for scenario in scenarios {
            let status = MenuBarCombinedStatus(
                vmRuntimeState: scenario.vmRuntimeState,
                isUSBAttached: scenario.isUSBAttached,
                wireGuardTunnelStatus: scenario.wireGuardTunnelStatus
            )

            XCTAssertEqual(status.activity, scenario.expectedActivity)
            XCTAssertEqual(status.stage, scenario.expectedStage)
        }
    }
}

private struct CombinedStatusScenario {
    let vmRuntimeState: VMRuntimeState
    let isUSBAttached: Bool
    let wireGuardTunnelStatus: HostWireGuardTunnelStatus
    let expectedActivity: MenuBarCombinedStatus.Activity
    let expectedStage: MenuBarCombinedStatus.Stage
}
