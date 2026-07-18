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

    func testRelaunchHelperRunsCommandOnlyAfterWatchedProcessExits() throws {
        let testDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

        let helperReadyURL = testDirectoryURL.appendingPathComponent("helper-ready")
        let markerURL = testDirectoryURL.appendingPathComponent("relaunched")
        let watchedProcess = Process()
        watchedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        watchedProcess.arguments = ["5"]
        try watchedProcess.run()
        var helperProcess: Process?
        defer {
            if watchedProcess.isRunning {
                watchedProcess.terminate()
                watchedProcess.waitUntilExit()
            }
            if let helperProcess {
                if helperProcess.isRunning {
                    helperProcess.terminate()
                }
                helperProcess.waitUntilExit()
            }
        }

        let service = ApplicationRelaunchService(
            helperLauncher: { executableURL, arguments in
                var instrumentedArguments = arguments
                let helperScript = try XCTUnwrap(arguments.dropFirst().first)
                let loopHeader = "while /bin/kill -0 \"$1\" 2>/dev/null; do"
                let instrumentedHelperScript = helperScript.replacingOccurrences(
                    of: loopHeader,
                    with: """
                    \(loopHeader)
                        /usr/bin/touch "$THRURNDIS_RELAUNCH_TEST_READY_PATH"
                    """
                )
                XCTAssertNotEqual(instrumentedHelperScript, helperScript)
                instrumentedArguments[1] = instrumentedHelperScript

                let process = Process()
                process.executableURL = executableURL
                process.arguments = instrumentedArguments
                var environment = ProcessInfo.processInfo.environment
                environment["THRURNDIS_RELAUNCH_TEST_READY_PATH"] = helperReadyURL.path
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                helperProcess = process
            },
            relaunchCommandBuilder: { _ in
                ["/usr/bin/touch", markerURL.path]
            }
        )
        try service.scheduleRelaunch(
            applicationURL: URL(fileURLWithPath: "/Applications/Unused.app"),
            afterProcessExits: watchedProcess.processIdentifier
        )

        guard waitForFile(at: helperReadyURL) else {
            return
        }
        XCTAssertTrue(watchedProcess.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        watchedProcess.terminate()
        watchedProcess.waitUntilExit()

        guard waitForFile(at: markerURL) else {
            return
        }
        helperProcess?.waitUntilExit()
    }

    @discardableResult
    private func waitForFile(
        at fileURL: URL,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: fileURL.path)
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for \(fileURL.lastPathComponent)."
        )
        return result == .completed
    }
}
