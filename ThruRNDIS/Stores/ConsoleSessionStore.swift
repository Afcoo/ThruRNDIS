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

struct GuestNetworkConsoleUpdate: Equatable {
    let guestIPv4Address: String?
    let isRNDISRouteReady: Bool?

    var isEmpty: Bool {
        guestIPv4Address == nil && isRNDISRouteReady == nil
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
            isRNDISRouteReady: completedMarkerValue(
                after: "THRURNDIS_RNDIS_ROUTE_READY="
            ).flatMap {
                switch $0 {
                case "1": true
                case "0": false
                default: nil
                }
            }
        )
    }

    private func completedMarkerValue(after marker: String) -> String? {
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
        return value.isEmpty ? nil : String(value)
    }
}
