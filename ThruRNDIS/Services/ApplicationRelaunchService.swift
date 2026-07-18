/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct ApplicationRelaunchService {
    typealias HelperLauncher = (_ executableURL: URL, _ arguments: [String]) throws -> Void
    typealias RelaunchCommandBuilder = (_ applicationURL: URL) -> [String]

    private static let helperExecutableURL = URL(fileURLWithPath: "/bin/sh")
    private static let helperScript = """
    remainingAttempts=300
    while /bin/kill -0 "$1" 2>/dev/null; do
        if [ "$remainingAttempts" -eq 0 ]; then
            exit 1
        fi
        remainingAttempts=$((remainingAttempts - 1))
        /bin/sleep 0.1
    done
    shift
    exec "$@"
    """

    private let helperLauncher: HelperLauncher
    private let relaunchCommandBuilder: RelaunchCommandBuilder

    init(
        helperLauncher: @escaping HelperLauncher = ApplicationRelaunchService.launchHelper,
        relaunchCommandBuilder: @escaping RelaunchCommandBuilder =
            ApplicationRelaunchService.makeRelaunchCommand
    ) {
        self.helperLauncher = helperLauncher
        self.relaunchCommandBuilder = relaunchCommandBuilder
    }

    func scheduleRelaunch(
        applicationURL: URL,
        afterProcessExits processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let relaunchCommand = relaunchCommandBuilder(applicationURL)
        precondition(!relaunchCommand.isEmpty)
        try helperLauncher(
            Self.helperExecutableURL,
            [
                "-c",
                Self.helperScript,
                "ThruRNDISRelauncher",
                String(processIdentifier),
            ] + relaunchCommand
        )
    }

    private static func makeRelaunchCommand(applicationURL: URL) -> [String] {
        ["/usr/bin/open", applicationURL.path]
    }

    private static func launchHelper(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
