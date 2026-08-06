/*
Copyright (C) 2026 Afcoo.
*/

import XCTest
@testable import ThruRNDIS

final class MenuBarCombinedStatusTests: XCTestCase {
    func testCombinedStatusOrdersWireGuardBeforeDummyEthernet() {
        let scenarios: [CombinedStatusScenario] = [
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: true,
                dummyEthernetState: .active,
                wireGuardTunnelStatus: .connected,
                expectedStage: .inactive
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: false,
                dummyEthernetState: .active,
                wireGuardTunnelStatus: .connected,
                expectedStage: .usbNotAttached
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                dummyEthernetState: .helperProblem,
                wireGuardTunnelStatus: .connected,
                expectedStage: .dummyEthernetHelperProblem
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                dummyEthernetState: .notChecked,
                wireGuardTunnelStatus: .connected,
                expectedStage: .dummyEthernetNotChecked
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                dummyEthernetState: .stopped,
                wireGuardTunnelStatus: .disconnected,
                expectedStage: .wireGuardDisconnected
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                dummyEthernetState: .needsAttention,
                wireGuardTunnelStatus: .connected,
                expectedStage: .dummyEthernetNeedsAttention
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                dummyEthernetState: .active,
                wireGuardTunnelStatus: .disconnected,
                expectedStage: .wireGuardDisconnected
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                dummyEthernetState: .active,
                wireGuardTunnelStatus: .connected,
                expectedStage: .active
            ),
        ]

        for scenario in scenarios {
            let status = MenuBarCombinedStatus(
                vmRuntimeState: scenario.vmRuntimeState,
                isUSBAttached: scenario.isUSBAttached,
                dummyEthernetState: scenario.dummyEthernetState,
                wireGuardTunnelStatus: scenario.wireGuardTunnelStatus
            )

            XCTAssertEqual(status.stage, scenario.expectedStage)
        }
    }

    func testCombinedStatusActivityIncludesDummyEthernet() {
        let inactiveStatus = MenuBarCombinedStatus(
            vmRuntimeState: .stopped,
            isUSBAttached: false,
            dummyEthernetState: .stopped,
            wireGuardTunnelStatus: .disconnected
        )
        XCTAssertEqual(inactiveStatus.activity, .inactive)

        let dummyEthernetStoppedStatus = MenuBarCombinedStatus(
            vmRuntimeState: .running,
            isUSBAttached: true,
            dummyEthernetState: .stopped,
            wireGuardTunnelStatus: .connected
        )
        XCTAssertEqual(dummyEthernetStoppedStatus.activity, .partiallyActive)

        let helperUnavailableStatus = MenuBarCombinedStatus(
            vmRuntimeState: .running,
            isUSBAttached: true,
            dummyEthernetState: .helperProblem,
            wireGuardTunnelStatus: .connected
        )
        XCTAssertEqual(helperUnavailableStatus.activity, .partiallyActive)
        XCTAssertEqual(
            helperUnavailableStatus.stage,
            .dummyEthernetHelperProblem
        )

        let activeStatus = MenuBarCombinedStatus(
            vmRuntimeState: .running,
            isUSBAttached: true,
            dummyEthernetState: .active,
            wireGuardTunnelStatus: .connected
        )
        XCTAssertEqual(activeStatus.activity, .active)
    }
}

private struct CombinedStatusScenario {
    let vmRuntimeState: VMRuntimeState
    let isUSBAttached: Bool
    let dummyEthernetState: MenuBarCombinedStatus.DummyEthernetState
    let wireGuardTunnelStatus: HostWireGuardTunnelStatus
    let expectedStage: MenuBarCombinedStatus.Stage
}
