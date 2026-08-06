/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum IfconfigRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case commandFailed(arguments: [String], output: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not launch /sbin/ifconfig: \(reason)"
        case .commandFailed(let arguments, let output):
            let command = "ifconfig " + arguments.joined(separator: " ")
            return output.isEmpty ? "\(command) failed." : "\(command) failed: \(output)"
        }
    }
}

/// Executes the helper's only external command without a shell.
struct IfconfigRunner: Sendable {
    func run(_ arguments: [String]) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.environment = ["LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw IfconfigRunnerError.launchFailed(
                error.localizedDescription
            )
        }
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        try? outputPipe.fileHandleForReading.close()

        guard process.terminationStatus == 0 else {
            throw IfconfigRunnerError.commandFailed(
                arguments: arguments,
                output: output
            )
        }
    }
}
