/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

struct ConsoleOutputState: Equatable {
    var data = Data()
    var outputSequence = 0
    var resetSequence = 0
}

enum GuestRNDISIPv4AddressUpdate: Equatable {
    case available(String)
    case unavailable
}

struct GuestNetworkConsoleUpdate: Equatable {
    let guestIPv4Address: String?
    let vznatGatewayIPv4Address: String?
    let rndisIPv4AddressUpdate: GuestRNDISIPv4AddressUpdate?
    let isRNDISRouteReady: Bool?
    let portForwardingState: GuestPortForwardingState?
}

@MainActor
final class ConsoleSessionStore: ObservableObject {
    @Published private(set) var output = ConsoleOutputState()

    private static let markerNamespaceBytes = Data("THRURNDIS_".utf8)

    private let maximumOutputBytes: Int
    private let maximumMarkerTokenBytes: Int
    // Retain only an unfinished whitespace-delimited token. Completed marker
    // values form the latest snapshot and their source text is never rescanned.
    private var markerTokenBuffer = Data()
    private var isDiscardingOversizedMarkerToken = false
    private var guestIPv4Address: String?
    private var vznatGatewayIPv4Address: String?
    private var rndisIPv4AddressUpdate: GuestRNDISIPv4AddressUpdate?
    private var isRNDISRouteReady: Bool?
    private var portForwardingState: GuestPortForwardingState?

    init(
        maximumOutputBytes: Int = 4_000_000,
        maximumMarkerTokenBytes: Int = 200_000
    ) {
        precondition(maximumOutputBytes > 0)
        precondition(maximumMarkerTokenBytes > 0)
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumMarkerTokenBytes = maximumMarkerTokenBytes
    }

    @discardableResult
    func append(_ data: Data) -> GuestNetworkConsoleUpdate? {
        appendOutput(data)
        guard consumeGuestNetworkMarkers(in: data) else { return nil }
        return GuestNetworkConsoleUpdate(
            guestIPv4Address: guestIPv4Address,
            vznatGatewayIPv4Address: vznatGatewayIPv4Address,
            rndisIPv4AddressUpdate: rndisIPv4AddressUpdate,
            isRNDISRouteReady: isRNDISRouteReady,
            portForwardingState: portForwardingState
        )
    }

    func clear() {
        markerTokenBuffer = Data()
        isDiscardingOversizedMarkerToken = false
        guestIPv4Address = nil
        vznatGatewayIPv4Address = nil
        rndisIPv4AddressUpdate = nil
        isRNDISRouteReady = nil
        portForwardingState = nil
        output = ConsoleOutputState(
            data: Data(),
            outputSequence: 0,
            resetSequence: output.resetSequence &+ 1
        )
    }

    private func appendOutput(_ data: Data) {
        var next = output
        next.data.append(data)

        if next.data.count > maximumOutputBytes {
            next.data.removeFirst(next.data.count - maximumOutputBytes)
            next.resetSequence &+= 1
        }

        next.outputSequence &+= 1
        output = next
    }

    private func consumeGuestNetworkMarkers(
        in data: Data
    ) -> Bool {
        var didConsumeMarker = false

        for byte in data {
            if Self.isASCIIWhitespace(byte) {
                if !isDiscardingOversizedMarkerToken,
                   consumeCompletedMarkerToken() {
                    didConsumeMarker = true
                }
                markerTokenBuffer.removeAll(keepingCapacity: true)
                isDiscardingOversizedMarkerToken = false
                continue
            }

            guard !isDiscardingOversizedMarkerToken else {
                continue
            }
            guard markerTokenBuffer.count < maximumMarkerTokenBytes else {
                markerTokenBuffer.removeAll(keepingCapacity: true)
                isDiscardingOversizedMarkerToken = true
                continue
            }
            markerTokenBuffer.append(byte)
        }

        return didConsumeMarker
    }

    private func consumeCompletedMarkerToken() -> Bool {
        guard markerTokenBuffer.range(of: Self.markerNamespaceBytes) != nil,
              let token = String(data: markerTokenBuffer, encoding: .utf8) else {
            return false
        }

        if let value = Self.markerValue(
            in: token,
            after: "THRURNDIS_VZNAT_IPV4="
        ) {
            guestIPv4Address = value
            return true
        }

        if let value = Self.markerValue(
            in: token,
            after: "THRURNDIS_VZNAT_GATEWAY="
        ) {
            vznatGatewayIPv4Address = value
            return true
        }

        if let value = Self.markerValue(
            in: token,
            after: "THRURNDIS_RNDIS_IPV4=",
            allowingEmptyValue: true
        ) {
            let addressUpdate: GuestRNDISIPv4AddressUpdate
            if value.isEmpty {
                addressUpdate = .unavailable
            } else {
                guard Self.isCanonicalIPv4Address(value) else { return false }
                addressUpdate = .available(value)
            }
            rndisIPv4AddressUpdate = addressUpdate
            return true
        }

        if let value = Self.markerValue(
            in: token,
            after: "THRURNDIS_RNDIS_ROUTE_READY="
        ) {
            let isReady: Bool
            switch value {
            case "1":
                isReady = true
            case "0":
                isReady = false
            default:
                return false
            }
            isRNDISRouteReady = isReady
            return true
        }

        if let value = Self.markerValue(
            in: token,
            after: "THRURNDIS_PORT_FORWARD_STATE="
        ), let state = GuestPortForwardingState(markerValue: value) {
            portForwardingState = state
            return true
        }

        return false
    }

    private static func isCanonicalIPv4Address(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 4 else { return false }

        let octets = components.compactMap { component -> UInt8? in
            guard !component.isEmpty,
                  component.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
                return nil
            }
            return UInt8(component)
        }
        return octets.count == 4
            && octets.map { String($0) }.joined(separator: ".") == value
    }

    private static func markerValue(
        in token: String,
        after marker: String,
        allowingEmptyValue: Bool = false
    ) -> String? {
        guard let markerRange = token.range(
            of: marker,
            options: [.backwards]
        ) else {
            return nil
        }

        let value = token[markerRange.upperBound...]
        return value.isEmpty && !allowingEmptyValue ? nil : String(value)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09 ... 0x0D).contains(byte)
    }
}
