/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct ManagedIPv4Route: Hashable, Sendable {
    let prefix: String
    let destination: String
    let mask: String

    static let all = [
        Self(
            prefix: "0.0.0.0/1",
            destination: "0.0.0.0",
            mask: "128.0.0.0"
        ),
        Self(
            prefix: "128.0.0.0/1",
            destination: "128.0.0.0",
            mask: "128.0.0.0"
        ),
    ]
}

enum RouteCommandRunnerError: LocalizedError {
    case commandFailed(arguments: [String], status: Int32, output: String)
    case conflictingRoute(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let arguments, let status, let output):
            let detail = output.isEmpty ? "no diagnostic output" : output
            return "route \(arguments.joined(separator: " ")) failed with status \(status): \(detail)"
        case .conflictingRoute(let prefix):
            return "An existing \(prefix) route is not owned by ThruRNDIS."
        }
    }
}

struct RouteCommandRunner: Sendable {
    func add(
        _ route: ManagedIPv4Route,
        gateway: String,
        interfaceName: String
    ) throws {
        _ = try run([
            "-n", "add", "-net",
            "-static", "-proto1", "-proto2",
            route.prefix, gateway,
        ])
    }

    func delete(
        _ route: ManagedIPv4Route,
        gateway: String,
        interfaceName: String
    ) throws {
        _ = try run([
            "-n", "delete", "-net",
            route.prefix, gateway,
        ])
    }

    func inspection(
        of route: ManagedIPv4Route,
        gateway: String,
        interfaceName: String
    ) throws -> ManagedRouteInspection {
        guard let record = try lookup(route) else {
            return .absent
        }
        guard record.gateway == gateway,
              record.interfaceName == interfaceName else {
            return .conflicting
        }
        return record.isOwned ? .owned : .conflicting
    }

    func lookup(_ route: ManagedIPv4Route) throws -> RouteLookupRecord? {
        let result: CommandResult
        do {
            result = try run(["-n", "get", "-net", route.prefix])
        } catch let error as RouteCommandRunnerError {
            if case .commandFailed(_, _, let output) = error,
               Self.isAbsentRouteDiagnostic(output) {
                return nil
            }
            throw error
        }

        let fields = Self.fields(from: result.output)
        guard Self.isExactRoute(fields, expected: route),
              let gateway = fields["gateway"],
              let interfaceName = fields["interface"] else {
            return nil
        }
        let flags = fields["flags"]?.uppercased() ?? ""
        return RouteLookupRecord(
            gateway: gateway,
            interfaceName: interfaceName,
            isOwned: flags.contains("PROTO1") && flags.contains("PROTO2")
        )
    }

    private static func isAbsentRouteDiagnostic(_ output: String) -> Bool {
        // `run` forces the C locale. Keep this allowlist exact so permission,
        // routing-socket, syntax, and other command failures never look absent.
        switch output {
        case "route: writing to routing socket: not in table",
             "route: not in table",
             "route: route has not been found",
             "route: not found":
            true
        default:
            false
        }
    }

    private func run(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = arguments
        process.environment = [
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw RouteCommandRunnerError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                output: output
            )
        }
        return CommandResult(output: output)
    }

    private static func fields(from output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    private static func isExactRoute(
        _ fields: [String: String],
        expected route: ManagedIPv4Route
    ) -> Bool {
        let destination = fields["destination"]
        let destinationMatches = destination == route.destination
            || (route.destination == "0.0.0.0" && destination == "default")
        return destinationMatches && fields["mask"] == route.mask
    }

    private struct CommandResult {
        let output: String
    }
}

enum ManagedRouteInspection: Equatable {
    case absent
    case owned
    case conflicting
}

struct RouteLookupRecord: Equatable, Sendable {
    let gateway: String
    let interfaceName: String
    let isOwned: Bool
}
