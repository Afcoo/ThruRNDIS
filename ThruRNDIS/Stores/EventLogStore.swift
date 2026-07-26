/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation
import OSLog

@MainActor
final class EventLogStore: ObservableObject {
    @Published private(set) var records: [EventLogRecord] = []

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
        level: EventLogLevel = .info,
        category: EventLogCategory,
        at date: Date = Date()
    ) {
        let record = EventLogRecord(
            date: date,
            level: level,
            category: category,
            message: message
        )
        var nextRecords = records
        nextRecords.append(record)
        trimToCharacterLimit(&nextRecords)
        records = nextRecords

        writeToUnifiedLog(record)
    }

    var text: String {
        text(isDebugModeEnabled: true)
    }

    var isEmpty: Bool {
        records.isEmpty
    }

    func text(
        isDebugModeEnabled: Bool,
        category: EventLogCategory? = nil
    ) -> String {
        let minimumLevel: EventLogLevel = isDebugModeEnabled ? .debug : .info
        return records.lazy
            .filter { $0.level >= minimumLevel }
            .filter { category == nil || $0.category == category }
            .map(Self.formattedLine)
            .joined()
    }

    func clear() {
        guard !records.isEmpty else {
            return
        }
        records = []
    }

    private func trimToCharacterLimit(_ value: inout [EventLogRecord]) {
        var characterCount = value.reduce(0) {
            $0 + Self.formattedLine($1).count
        }

        while characterCount > maximumCharacters, value.count > 1 {
            characterCount -= Self.formattedLine(value.removeFirst()).count
        }

        guard characterCount > maximumCharacters, let record = value.first else {
            return
        }

        let emptyMessageRecord = EventLogRecord(
            date: record.date,
            level: record.level,
            category: record.category,
            message: ""
        )
        let metadataCharacterCount = Self.formattedLine(emptyMessageRecord).count
        guard metadataCharacterCount < maximumCharacters else {
            value = []
            return
        }

        let availableMessageCharacters = maximumCharacters - metadataCharacterCount
        value = [
            EventLogRecord(
                date: record.date,
                level: record.level,
                category: record.category,
                message: String(record.message.suffix(availableMessageCharacters))
            )
        ]
    }

    private func writeToUnifiedLog(_ record: EventLogRecord) {
        switch record.level {
        case .debug:
            Self.logger.debug(
                "[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .private)"
            )
        case .info:
            Self.logger.info(
                "[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .private)"
            )
        case .warning:
            Self.logger.warning(
                "[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .private)"
            )
        case .error:
            Self.logger.error(
                "[\(record.category.rawValue, privacy: .public)] \(record.message, privacy: .private)"
            )
        }
    }

    private static func formattedLine(_ record: EventLogRecord) -> String {
        let timestamp = timestampFormatter.string(from: record.date)
        return "[\(timestamp)] [\(record.level.logLabel)] " +
            "[\(record.category.rawValue)] \(record.message)\n"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
