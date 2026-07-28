/*
Copyright (C) 2026 Afcoo.
*/

import XCTest
@testable import ThruRNDIS

final class ApplicationRelaunchServiceTests: XCTestCase {
    func testRelaunchHelperUsesBoundedWaitAndSeparateCommandArguments() throws {
        var capturedExecutableURL: URL?
        var capturedArguments: [String] = []
        let service = ApplicationRelaunchService(
            helperLauncher: { executableURL, arguments in
                capturedExecutableURL = executableURL
                capturedArguments = arguments
            }
        )
        let applicationURL = URL(
            fileURLWithPath: "/Applications/ThruRNDIS Test; echo injected.app"
        )

        try service.scheduleRelaunch(
            applicationURL: applicationURL,
            afterProcessExits: 12_345
        )

        XCTAssertEqual(capturedExecutableURL?.path, "/bin/sh")
        XCTAssertEqual(capturedArguments.first, "-c")
        let script = try XCTUnwrap(capturedArguments.dropFirst().first)
        XCTAssertTrue(script.contains("remainingAttempts=300"))
        XCTAssertTrue(script.contains("/bin/kill -0 \"$1\""))
        XCTAssertTrue(script.contains("exec \"$@\""))
        XCTAssertFalse(script.contains(applicationURL.path))
        XCTAssertEqual(
            Array(capturedArguments.dropFirst(2)),
            [
                "ThruRNDISRelauncher",
                "12345",
                "/usr/bin/open",
                applicationURL.path,
            ]
        )
    }
}
