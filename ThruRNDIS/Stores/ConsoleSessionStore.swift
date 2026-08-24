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

    var isEmpty: Bool {
        guestIPv4Address == nil
            && vznatGatewayIPv4Address == nil
            && rndisIPv4AddressUpdate == nil
            && isRNDISRouteReady == nil
            && portForwardingState == nil
    }
}

@MainActor
final class ConsoleSessionStore: ObservableObject {
    @Published private(set) var output = ConsoleOutputState()

    private let maximumOutputBytes: Int
    private let maximumScanCharacters: Int
    private var networkMarkerScanBuffer = ""

    init(
        maximumOutputBytes: Int = 4_000_000,
        maximumScanCharacters: Int = 200_000
    ) {
        precondition(maximumOutputBytes > 0)
        precondition(maximumScanCharacters > 0)
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumScanCharacters = maximumScanCharacters
    }

    @discardableResult
    func append(_ data: Data) -> GuestNetworkConsoleUpdate? {
        appendOutput(data)
        appendToNetworkMarkerScanBuffer(data)
        let update = detectedGuestNetworkUpdate()
        return update.isEmpty ? nil : update
    }

    func clear() {
        networkMarkerScanBuffer = ""
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

    private func appendToNetworkMarkerScanBuffer(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            networkMarkerScanBuffer.append(text)
        } else {
            networkMarkerScanBuffer.append(
                data.map { String(format: "%02X", $0) }.joined(separator: " ")
            )
            networkMarkerScanBuffer.append("\n")
        }

        if networkMarkerScanBuffer.count > maximumScanCharacters {
            networkMarkerScanBuffer.removeFirst(
                networkMarkerScanBuffer.count - maximumScanCharacters
            )
        }
    }

    private func detectedGuestNetworkUpdate() -> GuestNetworkConsoleUpdate {
        GuestNetworkConsoleUpdate(
            guestIPv4Address: completedMarkerValue(
                after: "THRURNDIS_VZNAT_IPV4="
            ),
            vznatGatewayIPv4Address: completedMarkerValue(
                after: "THRURNDIS_VZNAT_GATEWAY="
            ),
            rndisIPv4AddressUpdate: detectedRNDISIPv4AddressUpdate(),
            isRNDISRouteReady: completedMarkerValue(
                after: "THRURNDIS_RNDIS_ROUTE_READY="
            ).flatMap {
                switch $0 {
                case "1": true
                case "0": false
                default: nil
                }
            },
            portForwardingState: detectedPortForwardingState()
        )
    }

    private func detectedPortForwardingState() -> GuestPortForwardingState? {
        guard let markerValue = completedMarkerValue(
            after: "THRURNDIS_PORT_FORWARD_STATE="
        ) else {
            return nil
        }
        return GuestPortForwardingState(markerValue: markerValue)
    }

    private func detectedRNDISIPv4AddressUpdate()
        -> GuestRNDISIPv4AddressUpdate? {
        guard let value = completedMarkerValue(
            after: "THRURNDIS_RNDIS_IPV4=",
            allowingEmptyValue: true
        ) else {
            return nil
        }
        if value.isEmpty { return .unavailable }
        guard Self.isCanonicalIPv4Address(value) else { return nil }
        return .available(value)
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

    private func completedMarkerValue(
        after marker: String,
        allowingEmptyValue: Bool = false
    ) -> String? {
        guard let markerRange = networkMarkerScanBuffer.range(
            of: marker,
            options: [.backwards]
        ) else {
            return nil
        }

        let suffix = networkMarkerScanBuffer[markerRange.upperBound...]
        guard let delimiter = suffix.firstIndex(where: \.isWhitespace) else {
            return nil
        }
        let value = suffix[..<delimiter]
        return value.isEmpty && !allowingEmptyValue ? nil : String(value)
    }
}
