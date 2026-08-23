/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum NetworkInterfaceCommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case commandFailed(arguments: [String], status: Int32, output: String)
    case malformedBridgeStatus(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not launch /sbin/ifconfig: \(reason)"
        case .commandFailed(let arguments, let status, let output):
            let command = "ifconfig " + arguments.joined(separator: " ")
            let detail = output.isEmpty ? "no diagnostic output" : output
            return "\(command) failed with status \(status): \(detail)"
        case .malformedBridgeStatus(let interfaceName):
            return "Could not verify the members of \(interfaceName)."
        }
    }
}

/// Executes only the fixed absolute ifconfig tool without a shell.
struct NetworkInterfaceCommandRunner: Sendable {
    func run(_ arguments: [String]) throws {
        _ = try execute(arguments)
    }

    func bridgeMembers(interfaceName: String) throws -> Set<String> {
        let output = try execute([interfaceName])
        var members: Set<String> = []
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.first == "member:" else { continue }
            guard fields.count >= 2 else {
                throw NetworkInterfaceCommandRunnerError
                    .malformedBridgeStatus(interfaceName)
            }
            members.insert(String(fields[1]))
        }
        return members
    }

    func bondRuntime(interfaceName: String) throws -> BondRuntimeSnapshot {
        let output = try execute(["-b", interfaceName])
        var mode: String?
        var members: Set<String> = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("bond mode: ") {
                mode = String(trimmed.dropFirst("bond mode: ".count))
                continue
            }
            if trimmed.hasPrefix("bond interface: ") {
                let remainder = trimmed.dropFirst("bond interface: ".count)
                if let member = Self.interfaceName(in: String(remainder)) {
                    members.insert(member)
                }
            }
        }
        return BondRuntimeSnapshot(mode: mode, members: members)
    }

    func fethPeer(interfaceName: String) throws -> String? {
        let output = try execute([interfaceName])
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("peer: ") else { continue }
            let peer = String(trimmed.dropFirst("peer: ".count))
            return peer == "<none>" ? nil : peer
        }
        return nil
    }

    private static func interfaceName(in value: String) -> String? {
        guard let field = value.split(
            whereSeparator: \.isWhitespace
        ).first else {
            return nil
        }
        let name = String(field)
        let unit = name.dropFirst("feth".count)
        guard name.hasPrefix("feth"),
              !unit.isEmpty,
              unit.allSatisfy(\.isNumber) else {
            return nil
        }
        return name
    }

    private func execute(_ arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: "/",
            isDirectory: true
        )
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw NetworkInterfaceCommandRunnerError.launchFailed(
                error.localizedDescription
            )
        }
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        try? outputPipe.fileHandleForReading.close()

        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw NetworkInterfaceCommandRunnerError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}

struct BondRuntimeSnapshot: Sendable {
    let mode: String?
    let members: Set<String>
}
