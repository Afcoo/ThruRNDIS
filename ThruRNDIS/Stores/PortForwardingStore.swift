/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

struct PortForwardingPortSet: Equatable {
    enum ValidationError: LocalizedError {
        case invalidElement
        case portOutOfRange
        case descendingRange

        var errorDescription: String? {
            switch self {
            case .invalidElement:
                String(localized: "The input format is invalid.")
            case .portOutOfRange:
                String(localized: "A value is outside the allowed range.")
            case .descendingRange:
                String(localized: "The range order is invalid.")
            }
        }
    }

    private static let validPortRange = 1...65_535

    private let ranges: [ClosedRange<Int>]

    init(_ value: String) throws {
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError.invalidElement
        }
        let elements = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        )

        var parsedRanges: [ClosedRange<Int>] = []
        for rawElement in elements {
            let element = rawElement.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !element.isEmpty else {
                throw ValidationError.invalidElement
            }

            let bounds = element.split(
                separator: "-",
                omittingEmptySubsequences: false
            )
            switch bounds.count {
            case 1:
                let port = try Self.parsePort(String(bounds[0]))
                parsedRanges.append(port...port)
            case 2:
                let lower = try Self.parsePort(String(bounds[0]))
                let upper = try Self.parsePort(String(bounds[1]))
                guard lower <= upper else {
                    throw ValidationError.descendingRange
                }
                parsedRanges.append(lower...upper)
            default:
                throw ValidationError.invalidElement
            }
        }

        ranges = Self.merged(parsedRanges)
    }

    var canonicalString: String {
        ranges.map { range in
            range.lowerBound == range.upperBound
                ? String(range.lowerBound)
                : "\(range.lowerBound)-\(range.upperBound)"
        }
        .joined(separator: ",")
    }

    private static func parsePort(_ rawValue: String) throws -> Int {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in byte >= 48 && byte <= 57 }) else {
            throw ValidationError.invalidElement
        }
        guard let port = Int(value), validPortRange.contains(port) else {
            throw ValidationError.portOutOfRange
        }
        return port
    }

    private static func merged(
        _ ranges: [ClosedRange<Int>]
    ) -> [ClosedRange<Int>] {
        let sortedRanges = ranges.sorted { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound {
                return lhs.upperBound < rhs.upperBound
            }
            return lhs.lowerBound < rhs.lowerBound
        }

        var result: [ClosedRange<Int>] = []
        for range in sortedRanges {
            guard let previous = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound <= previous.upperBound + 1 {
                result[result.count - 1] = previous.lowerBound...max(
                    previous.upperBound,
                    range.upperBound
                )
            } else {
                result.append(range)
            }
        }
        return result
    }
}

enum PortForwardingConfiguration {
    static let bootArgumentKey = "thrurndis.port_forward"
    static let isEnabledByDefault = false
    static let defaultPortSpecification = "80,443,47980-48000"

    static func bootArgument(for ports: PortForwardingPortSet) -> String {
        "\(Self.bootArgumentKey)=\(ports.canonicalString)"
    }
}

enum GuestPortForwardingState: Equatable {
    case inactive
    case pending(PortForwardingPortSet)
    case active(PortForwardingPortSet)
    case error(String)

    init?(markerValue: String) {
        if markerValue == "inactive" {
            self = .inactive
            return
        }
        if markerValue.hasPrefix("error:") {
            let code = markerValue.dropFirst("error:".count)
            guard !code.isEmpty else { return nil }
            self = .error(String(code.prefix(80)))
            return
        }

        let components = markerValue.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let ports = try? PortForwardingPortSet(String(components[1])) else {
            return nil
        }
        switch components[0] {
        case "pending":
            self = .pending(ports)
        case "active":
            self = .active(ports)
        default:
            return nil
        }
    }
}

enum PortForwardingRuntimeState: Equatable {
    case disabled
    case saved
    case pending
    case active
    case failed(String)
}

@MainActor
final class PortForwardingStore: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var portSpecification: String
    @Published private(set) var runtimeState: PortForwardingRuntimeState

    private let defaults: UserDefaults
    private let eventLog: EventLogStore
    private var isConfigurationLocked = false

    init(
        eventLog: EventLogStore,
        defaults: UserDefaults = .standard
    ) {
        let isEnabled = defaults.object(forKey: DefaultsKey.isEnabled) == nil
            ? PortForwardingConfiguration.isEnabledByDefault
            : defaults.bool(forKey: DefaultsKey.isEnabled)
        let storedPortSpecification = defaults.string(
            forKey: DefaultsKey.portSpecification
        )
        let portSpecification = Self.nonEmptyPortSpecification(
            storedPortSpecification
        )
        self.eventLog = eventLog
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.portSpecification = portSpecification
        self.runtimeState = isEnabled ? .saved : .disabled
        if isEnabled || storedPortSpecification != nil {
            defaults.set(
                portSpecification,
                forKey: DefaultsKey.portSpecification
            )
        }
    }

    private var validatedPortSet: PortForwardingPortSet? {
        try? PortForwardingPortSet(portSpecification)
    }

    var validationErrorMessage: String? {
        guard isEnabled else { return nil }
        do {
            _ = try PortForwardingPortSet(portSpecification)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var isReadyForVMStart: Bool {
        !isEnabled || validatedPortSet != nil
    }

    func setEnabled(_ isEnabled: Bool) {
        guard !isConfigurationLocked, self.isEnabled != isEnabled else {
            return
        }
        self.isEnabled = isEnabled
        defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
        if isEnabled {
            defaults.set(
                portSpecification,
                forKey: DefaultsKey.portSpecification
            )
        }
        runtimeState = isEnabled ? .saved : .disabled

        let description = validatedPortSet?.canonicalString
            ?? portSpecification
        eventLog.append(
            isEnabled
                ? "TCP and UDP port forwarding enabled for the next VM start: ports \(description)."
                : "TCP and UDP port forwarding disabled for the next VM start.",
            level: .info,
            category: .network
        )
    }

    func setPortSpecification(_ specification: String) {
        let specification = Self.nonEmptyPortSpecification(specification)
        guard !isConfigurationLocked,
              portSpecification != specification else {
            return
        }
        portSpecification = specification
        defaults.set(specification, forKey: DefaultsKey.portSpecification)
        if isEnabled {
            runtimeState = .saved
        }
    }

    func prepareBootCommandLine(applyingTo commandLine: String) -> String {
        isConfigurationLocked = true
        runtimeState = isEnabled ? .pending : .disabled

        guard isEnabled, let ports = validatedPortSet else {
            return commandLine
        }
        return commandLine + " "
            + PortForwardingConfiguration.bootArgument(for: ports)
    }

    func vmDidStop() {
        isConfigurationLocked = false
        runtimeState = isEnabled ? .saved : .disabled
    }

    func apply(_ guestState: GuestPortForwardingState) {
        guard isConfigurationLocked else { return }

        switch guestState {
        case .inactive:
            if isEnabled {
                reportGuestFailure(
                    String(localized: "The VM did not enable the configured TCP and UDP port forwarding ports.")
                )
            } else if runtimeState != .disabled {
                runtimeState = .disabled
            }
        case .pending(let ports):
            guard isEnabled, ports == validatedPortSet else {
                reportGuestConfigurationMismatch(ports)
                return
            }
            guard runtimeState != .pending else { return }
            runtimeState = .pending
        case .active(let ports):
            guard isEnabled, ports == validatedPortSet else {
                reportGuestConfigurationMismatch(ports)
                return
            }
            guard runtimeState != .active else { return }
            runtimeState = .active
            eventLog.append(
                "TCP and UDP port forwarding active: ports \(ports.canonicalString).",
                level: .info,
                category: .network
            )
        case .error(let code):
            reportGuestFailure(
                String(
                    localized: "The VM rejected the configured TCP and UDP port forwarding ports (\(code))."
                )
            )
        }
    }

    func reset() {
        defaults.set(
            PortForwardingConfiguration.isEnabledByDefault,
            forKey: DefaultsKey.isEnabled
        )
        defaults.removeObject(forKey: DefaultsKey.portSpecification)
        isConfigurationLocked = false
        isEnabled = PortForwardingConfiguration.isEnabledByDefault
        portSpecification = PortForwardingConfiguration.defaultPortSpecification
        runtimeState = .disabled
    }

    private static func nonEmptyPortSpecification(
        _ specification: String?
    ) -> String {
        guard let specification,
              !specification.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return PortForwardingConfiguration.defaultPortSpecification
        }
        return specification
    }

    private func reportGuestConfigurationMismatch(
        _ ports: PortForwardingPortSet
    ) {
        reportGuestFailure(
            String(
                localized: "The VM reported unexpected TCP and UDP port forwarding ports: \(ports.canonicalString)."
            )
        )
    }

    private func reportGuestFailure(_ message: String) {
        guard runtimeState != .failed(message) else { return }
        runtimeState = .failed(message)
        eventLog.append(message, level: .error, category: .network)
    }

    private enum DefaultsKey {
        static let isEnabled = "Network.portForwardingEnabled"
        static let portSpecification = "Network.portForwardingPortSpecification"
    }
}
