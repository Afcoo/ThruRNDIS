/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum ManagedIPv4RouteScope: Hashable, Sendable {
    case global
    case interfaceScoped
}

struct ManagedIPv4Route: Hashable, Sendable {
    let prefix: String
    let destination: String
    let mask: String
    let scope: ManagedIPv4RouteScope

    static let prefixes = [
        "0.0.0.0/1",
        "128.0.0.0/1",
    ]

    private static let globalLower = Self(
        prefix: prefixes[0],
        destination: "0.0.0.0",
        mask: "128.0.0.0",
        scope: .global
    )
    private static let scopedLower = Self(
        prefix: prefixes[0],
        destination: "0.0.0.0",
        mask: "128.0.0.0",
        scope: .interfaceScoped
    )
    private static let scopedUpper = Self(
        prefix: prefixes[1],
        destination: "128.0.0.0",
        mask: "128.0.0.0",
        scope: .interfaceScoped
    )
    private static let globalUpper = Self(
        prefix: prefixes[1],
        destination: "128.0.0.0",
        mask: "128.0.0.0",
        scope: .global
    )

    // Keep one global entry as a rediscovery anchor while the scoped entries
    // are added or removed. This prevents a helper restart from leaving only
    // interface-scoped entries that cannot be found without a known interface.
    static let installationOrder = [
        globalLower,
        scopedLower,
        scopedUpper,
        globalUpper,
    ]
    static let removalOrder = Array(installationOrder.reversed())
    static let rediscoveryAnchor = globalLower
    static let all = installationOrder
    static let global = [globalLower, globalUpper]

    static func entries(for prefix: String) -> [Self] {
        all.filter { $0.prefix == prefix }
    }

    func diagnosticName(interfaceName: String) -> String {
        switch scope {
        case .global:
            "global \(prefix)"
        case .interfaceScoped:
            "\(interfaceName)-scoped \(prefix)"
        }
    }

    var netstatDestinations: Set<String> {
        switch prefix {
        case "0.0.0.0/1":
            ["0/1", "0.0.0.0/1"]
        case "128.0.0.0/1":
            ["128.0/1", "128.0.0.0/1"]
        default:
            []
        }
    }
}

enum RouteCommandRunnerError: LocalizedError {
    case commandFailed(arguments: [String], status: Int32, output: String)
    case conflictingRoute(String)
    case routeTableInspectionFailed(status: Int32, output: String)
    case ambiguousRouteTableEntries(String)
    case missingInterfaceName

    var errorDescription: String? {
        switch self {
        case .commandFailed(let arguments, let status, let output):
            let detail = output.isEmpty ? "no diagnostic output" : output
            return "route \(arguments.joined(separator: " ")) failed with status \(status): \(detail)"
        case .conflictingRoute(let prefix):
            return "An existing \(prefix) route is not owned by ThruRNDIS."
        case .routeTableInspectionFailed(let status, let output):
            let detail = output.isEmpty ? "no diagnostic output" : output
            return "netstat -rn -f inet failed with status \(status): \(detail)"
        case .ambiguousRouteTableEntries(let description):
            return "More than one matching managed route entry was found: \(description)"
        case .missingInterfaceName:
            return "An interface name is required for an interface-scoped route."
        }
    }
}

struct RouteCommandRunner: Sendable {
    func add(
        _ route: ManagedIPv4Route,
        gateway: String,
        interfaceName: String
    ) throws {
        var arguments = ["-n", "add", "-net"]
        try appendScopeArguments(
            for: route,
            interfaceName: interfaceName,
            to: &arguments
        )
        arguments.append(contentsOf: [
            "-static", "-proto1", "-proto2", route.prefix, gateway,
        ])
        try run(arguments)
    }

    func delete(
        _ route: ManagedIPv4Route,
        gateway: String,
        interfaceName: String
    ) throws {
        var arguments = ["-n", "delete", "-net"]
        try appendScopeArguments(
            for: route,
            interfaceName: interfaceName,
            to: &arguments
        )
        arguments.append(contentsOf: [route.prefix, gateway])
        try run(arguments)
    }

    func inspection(
        of route: ManagedIPv4Route,
        gateway: String,
        interfaceName: String
    ) throws -> ManagedRouteInspection {
        let routeTable = try readIPv4RouteTable()
        return try inspection(
            of: route,
            gateway: gateway,
            interfaceName: interfaceName,
            routeTable: routeTable
        )
    }

    /// Classifies the complete managed route set from one route-table read.
    /// This prevents a network change from producing a mixed result assembled
    /// from route-table snapshots captured at different times.
    func inspections(
        gateway: String,
        interfaceName: String
    ) throws -> ManagedIPv4RouteSetInspection {
        let routeTable = try readIPv4RouteTable()
        var result: [ManagedIPv4Route: ManagedRouteInspection] = [:]
        for route in ManagedIPv4Route.all {
            result[route] = try inspection(
                of: route,
                gateway: gateway,
                interfaceName: interfaceName,
                routeTable: routeTable
            )
        }
        for route in ManagedIPv4Route.all
        where route.scope == .interfaceScoped {
            let hasUnexpectedScope = routeTableRecords(
                for: route,
                in: routeTable
            ).contains {
                $0.isInterfaceScoped
                    && $0.interfaceName != interfaceName
            }
            if hasUnexpectedScope {
                result[route] = .conflicting
            }
        }
        return ManagedIPv4RouteSetInspection(entries: result)
    }

    private func inspection(
        of route: ManagedIPv4Route,
        gateway: String,
        interfaceName: String,
        routeTable: String
    ) throws -> ManagedRouteInspection {
        guard let record = try lookup(
            route,
            interfaceName: interfaceName,
            routeTable: routeTable
        ) else {
            return .absent
        }
        guard record.gateway == gateway,
              record.interfaceName == interfaceName else {
            return .conflicting
        }
        return record.isOwned ? .owned : .conflicting
    }

    private func lookup(
        _ route: ManagedIPv4Route,
        interfaceName: String?,
        routeTable: String
    ) throws -> RouteLookupRecord? {
        if route.scope == .interfaceScoped,
           interfaceName?.isEmpty != false {
            throw RouteCommandRunnerError.missingInterfaceName
        }

        let expectedScope = route.scope == .interfaceScoped
        let records = routeTableRecords(
            for: route,
            in: routeTable
        ).filter { record in
            guard record.isInterfaceScoped == expectedScope else {
                return false
            }
            if expectedScope {
                return record.interfaceName == interfaceName
            }
            return true
        }
        guard records.count <= 1 else {
            let description = records.map {
                "\($0.gateway) on \($0.interfaceName)"
            }.joined(separator: ", ")
            throw RouteCommandRunnerError.ambiguousRouteTableEntries(
                description
            )
        }
        return records.first
    }

    func firstExistingRoute(
        matching routes: [ManagedIPv4Route]
    ) throws -> ManagedIPv4Route? {
        let routeTable = try readIPv4RouteTable()
        return routes.first { route in
            !routeTableRecords(
                for: route,
                in: routeTable
            ).isEmpty
        }
    }

    private func appendScopeArguments(
        for route: ManagedIPv4Route,
        interfaceName: String?,
        to arguments: inout [String]
    ) throws {
        guard route.scope == .interfaceScoped else { return }
        guard let interfaceName, !interfaceName.isEmpty else {
            throw RouteCommandRunnerError.missingInterfaceName
        }
        arguments.append(contentsOf: ["-ifscope", interfaceName])
    }

    private func routeTableRecords(
        for route: ManagedIPv4Route,
        in routeTable: String
    ) -> [RouteLookupRecord] {
        routeTable.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 4,
                  route.netstatDestinations.contains(String(columns[0])) else {
                return nil
            }

            let flags = String(columns[2])
            return RouteLookupRecord(
                gateway: String(columns[1]),
                interfaceName: String(columns[3]),
                isOwned: flags.contains("1") && flags.contains("2"),
                isInterfaceScoped: flags.contains("I")
            )
        }
    }

    private func readIPv4RouteTable() throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", "inet"]
        process.environment = [
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(
            data: outputData,
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw RouteCommandRunnerError.routeTableInspectionFailed(
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }

    private func run(_ arguments: [String]) throws {
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
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(
            data: outputData,
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
    }
}

enum ManagedRouteInspection: Equatable, Sendable {
    case absent
    case owned
    case conflicting

    var diagnosticName: String {
        switch self {
        case .absent:
            "absent"
        case .owned:
            "owned"
        case .conflicting:
            "conflicting"
        }
    }
}

struct ManagedIPv4RouteSetInspection: Sendable {
    let entries: [ManagedIPv4Route: ManagedRouteInspection]

    subscript(route: ManagedIPv4Route) -> ManagedRouteInspection? {
        entries[route]
    }

    var isFullyOwned: Bool {
        ManagedIPv4Route.all.allSatisfy { entries[$0] == .owned }
    }

    var firstConflictingRoute: ManagedIPv4Route? {
        ManagedIPv4Route.installationOrder.first {
            entries[$0] == .conflicting
        }
    }
}

private struct RouteLookupRecord {
    let gateway: String
    let interfaceName: String
    let isOwned: Bool
    let isInterfaceScoped: Bool
}
