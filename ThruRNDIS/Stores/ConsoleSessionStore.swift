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

@MainActor
final class ConsoleSessionStore: ObservableObject {
    @Published private(set) var output = ConsoleOutputState()

    private let maximumOutputBytes: Int
    private let maximumScanCharacters: Int
    private var endpointScanBuffer = ""

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
    func append(_ data: Data) -> String? {
        appendOutput(data)
        appendToEndpointScanBuffer(data)
        return detectedWireGuardEndpoint()
    }

    func clear() {
        endpointScanBuffer = ""
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

    private func appendToEndpointScanBuffer(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            endpointScanBuffer.append(text)
        } else {
            endpointScanBuffer.append(
                data.map { String(format: "%02X", $0) }.joined(separator: " ")
            )
            endpointScanBuffer.append("\n")
        }

        if endpointScanBuffer.count > maximumScanCharacters {
            endpointScanBuffer.removeFirst(
                endpointScanBuffer.count - maximumScanCharacters
            )
        }
    }

    private func detectedWireGuardEndpoint() -> String? {
        let marker = "THRURNDIS_WG_ENDPOINT="
        guard let markerRange = endpointScanBuffer.range(
            of: marker,
            options: [.backwards]
        ) else {
            return nil
        }

        let suffix = endpointScanBuffer[markerRange.upperBound...]
        guard let token = suffix.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }

        let endpoint = String(token).trimmingCharacters(
            in: CharacterSet(charactersIn: "\r\n")
        )
        return endpoint.contains(":") ? endpoint : nil
    }
}
