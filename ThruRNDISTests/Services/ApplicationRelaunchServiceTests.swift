/*
Copyright (C) 2026 Afcoo.
*/

import XCTest
@testable import ThruRNDIS

final class ApplicationRelaunchServiceTests: XCTestCase {
    func testRelaunchHelperUsesBoundedPIDWaitBeforeOpeningApplication() throws {
        var capturedExecutableURL: URL?
        var capturedArguments: [String] = []
        let service = ApplicationRelaunchService(
            helperLauncher: { executableURL, arguments in
                capturedExecutableURL = executableURL
                capturedArguments = arguments
            }
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/ThruRNDIS Test.app")

        try service.scheduleRelaunch(
            applicationURL: applicationURL,
            afterProcessExits: 12_345
        )

        XCTAssertEqual(capturedExecutableURL?.path, "/bin/sh")
        XCTAssertEqual(capturedArguments.count, 6)
        guard capturedArguments.count == 6 else {
            return
        }
        XCTAssertEqual(capturedArguments[0], "-c")
        XCTAssertTrue(capturedArguments[1].contains("remainingAttempts=300"))
        XCTAssertTrue(capturedArguments[1].contains("/bin/kill -0 \"$1\""))
        XCTAssertTrue(capturedArguments[1].contains("exec \"$@\""))
        XCTAssertEqual(capturedArguments[2], "ThruRNDISRelauncher")
        XCTAssertEqual(capturedArguments[3], "12345")
        XCTAssertEqual(capturedArguments[4], "/usr/bin/open")
        XCTAssertEqual(capturedArguments[5], applicationURL.path)
    }
}
