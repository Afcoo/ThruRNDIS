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
                expectedStage: .inactive,
                expectedTitle: String(
                    localized: "menuBar.combinedStatus.notRunning",
                    defaultValue: "Not Running"
                )
            ),
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: false,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .partiallyActive,
                expectedStage: .inactive,
                expectedTitle: String(
                    localized: "menuBar.combinedStatus.notRunning",
                    defaultValue: "Not Running"
                )
            ),
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: true,
                wireGuardTunnelStatus: .disconnected,
                expectedActivity: .partiallyActive,
                expectedStage: .inactive,
                expectedTitle: String(
                    localized: "menuBar.combinedStatus.notRunning",
                    defaultValue: "Not Running"
                )
            ),
            .init(
                vmRuntimeState: .stopped,
                isUSBAttached: true,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .partiallyActive,
                expectedStage: .inactive,
                expectedTitle: String(
                    localized: "menuBar.combinedStatus.notRunning",
                    defaultValue: "Not Running"
                )
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: false,
                wireGuardTunnelStatus: .disconnected,
                expectedActivity: .partiallyActive,
                expectedStage: .usbNotAttached,
                expectedTitle: String(localized: "USB Not Attached")
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: false,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .partiallyActive,
                expectedStage: .usbNotAttached,
                expectedTitle: String(localized: "USB Not Attached")
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                wireGuardTunnelStatus: .disconnected,
                expectedActivity: .partiallyActive,
                expectedStage: .wireGuardDisconnected,
                expectedTitle: String(localized: "WireGuard Disconnected")
            ),
            .init(
                vmRuntimeState: .running,
                isUSBAttached: true,
                wireGuardTunnelStatus: .connected,
                expectedActivity: .active,
                expectedStage: .active,
                expectedTitle: String(
                    localized: "menuBar.combinedStatus.running",
                    defaultValue: "Running"
                )
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
            XCTAssertEqual(status.title, scenario.expectedTitle)
        }
    }

    func testOnlyRunningVMStateIsActive() {
        let inactiveVMRuntimeStates: [VMRuntimeState] = [
            .idle,
            .starting,
            .stopping,
            .stopped,
            .failed,
        ]

        for vmRuntimeState in inactiveVMRuntimeStates {
            let status = MenuBarCombinedStatus(
                vmRuntimeState: vmRuntimeState,
                isUSBAttached: true,
                wireGuardTunnelStatus: .connected
            )

            XCTAssertEqual(status.activity, .partiallyActive)
            XCTAssertEqual(status.stage, .inactive)
            XCTAssertEqual(
                status.title,
                String(
                    localized: "menuBar.combinedStatus.notRunning",
                    defaultValue: "Not Running"
                )
            )
        }

        let runningStatus = MenuBarCombinedStatus(
            vmRuntimeState: .running,
            isUSBAttached: true,
            wireGuardTunnelStatus: .connected
        )
        XCTAssertEqual(runningStatus.activity, .active)
        XCTAssertEqual(runningStatus.stage, .active)
    }

    func testOnlyConnectedWireGuardStatusIsActive() {
        let inactiveTunnelStatuses: [HostWireGuardTunnelStatus] = [
            .unconfigured,
            .disconnected,
            .activatingSystemExtension,
            .connecting,
            .disconnecting,
            .reasserting,
            .failed("Test failure"),
        ]

        for wireGuardTunnelStatus in inactiveTunnelStatuses {
            let status = MenuBarCombinedStatus(
                vmRuntimeState: .running,
                isUSBAttached: true,
                wireGuardTunnelStatus: wireGuardTunnelStatus
            )

            XCTAssertEqual(status.activity, .partiallyActive)
            XCTAssertEqual(status.stage, .wireGuardDisconnected)
            XCTAssertEqual(
                status.title,
                String(localized: "WireGuard Disconnected")
            )
        }

        let connectedStatus = MenuBarCombinedStatus(
            vmRuntimeState: .running,
            isUSBAttached: true,
            wireGuardTunnelStatus: .connected
        )
        XCTAssertEqual(connectedStatus.activity, .active)
        XCTAssertEqual(connectedStatus.stage, .active)
    }

    func testKoreanCombinedStageTitlesAreBundled() throws {
        let localizationURL = try XCTUnwrap(
            Bundle.main.url(forResource: "ko", withExtension: "lproj")
        )
        let koreanBundle = try XCTUnwrap(Bundle(url: localizationURL))

        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "menuBar.combinedStatus.notRunning",
                value: nil,
                table: nil
            ),
            "비활성화됨"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "USB Not Attached",
                value: nil,
                table: nil
            ),
            "USB 연결 안 됨"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "WireGuard Disconnected",
                value: nil,
                table: nil
            ),
            "WireGuard 연결 안 됨"
        )
        XCTAssertEqual(
            koreanBundle.localizedString(
                forKey: "menuBar.combinedStatus.running",
                value: nil,
                table: nil
            ),
            "활성화됨"
        )
    }
}

private struct CombinedStatusScenario {
    let vmRuntimeState: VMRuntimeState
    let isUSBAttached: Bool
    let wireGuardTunnelStatus: HostWireGuardTunnelStatus
    let expectedActivity: MenuBarCombinedStatus.Activity
    let expectedStage: MenuBarCombinedStatus.Stage
    let expectedTitle: String
}
