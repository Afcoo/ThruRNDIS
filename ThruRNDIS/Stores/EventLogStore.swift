/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation
import OSLog

enum EventLogSource: String {
    case app = "App"
    case vmAssets = "VM Assets"
    case virtualMachine = "VM"
    case accessoryAccess = "AccessoryAccess"
    case wireGuard = "WireGuard"
}

@MainActor
final class EventLogStore: ObservableObject {
    @Published private(set) var text = ""

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ThruRNDIS",
        category: "EventLog"
    )

    private let maximumCharacters: Int

    init(maximumCharacters: Int = 60_000) {
        precondition(maximumCharacters > 0)
        self.maximumCharacters = maximumCharacters
    }

    func append(
        _ message: String,
        source: EventLogSource,
        at date: Date = Date()
    ) {
        let timestamp = Self.timestampFormatter.string(from: date)
        var next = text
        next.append("[\(timestamp)] [\(source.rawValue)] \(message)\n")
        trimToCharacterLimit(&next)
        text = next

        Self.logger.info(
            "[\(source.rawValue, privacy: .public)] \(message, privacy: .private)"
        )
    }

    func clear() {
        guard !text.isEmpty else {
            return
        }
        text = ""
    }

    private func trimToCharacterLimit(_ value: inout String) {
        while value.count > maximumCharacters {
            guard let newlineIndex = value.firstIndex(of: "\n") else {
                value = String(value.suffix(maximumCharacters))
                return
            }

            let nextLineIndex = value.index(after: newlineIndex)
            guard nextLineIndex < value.endIndex else {
                value = String(value.suffix(maximumCharacters))
                return
            }
            value.removeSubrange(..<nextLineIndex)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
