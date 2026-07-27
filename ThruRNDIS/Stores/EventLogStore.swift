/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation
import OSLog

@MainActor
final class EventLogStore: ObservableObject {
    @Published private(set) var records: [EventLogRecord] = []
    @Published private(set) var hasPersistedLogFiles = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ThruRNDIS",
        category: "EventLog"
    )
    private static let fileMaintenanceIntervalNanoseconds: UInt64 =
        60 * 60 * 1_000_000_000

    private let maximumCharacters: Int
    private let filePersistence: (any EventLogFilePersisting)?
    private var didReportFilePersistenceFailure = false
    private var filePersistenceTask: Task<Void, Never>?
    private var fileMaintenanceTask: Task<Void, Never>?

    init(
        maximumCharacters: Int = 60_000,
        filePersistence: (any EventLogFilePersisting)? = nil
    ) {
        precondition(maximumCharacters > 0)
        self.maximumCharacters = maximumCharacters
        self.filePersistence = filePersistence
        if filePersistence != nil {
            refreshPersistedLogFileState()
            startFileMaintenance()
        }
    }

    deinit {
        fileMaintenanceTask?.cancel()
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

        writeToUnifiedLog(record)
        persistToFile(record)
        appendToDisplay(record)
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

    private func appendToDisplay(_ record: EventLogRecord) {
        var nextRecords = records
        nextRecords.append(record)
        trimToCharacterLimit(&nextRecords)
        records = nextRecords
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

        let availableMessageCharacters =
            maximumCharacters - metadataCharacterCount
        value = [
            EventLogRecord(
                date: record.date,
                level: record.level,
                category: record.category,
                message: String(
                    record.message.suffix(availableMessageCharacters)
                )
            ),
        ]
    }

    @discardableResult
    func exportPersistedLogFiles(
        to destinationDirectoryURL: URL
    ) async throws -> URL {
        guard let filePersistence else {
            throw EventLogStoreError.filePersistenceUnavailable
        }

        let previousTask = filePersistenceTask
        let exportTask = Task<Result<URL, Error>, Never> { @MainActor in
            await previousTask?.value
            do {
                return .success(
                    try await filePersistence.exportLogFiles(
                        to: destinationDirectoryURL
                    )
                )
            } catch {
                return .failure(error)
            }
        }
        let barrierTask = Task { @MainActor [weak self] in
            let result = await exportTask.value
            if case .success = result {
                self?.updatePersistedLogFileState(true)
            }
        }
        filePersistenceTask = barrierTask

        return try await exportTask.value.get()
    }

    func preparePersistedLogsDirectory() async throws -> URL {
        guard let filePersistence else {
            throw EventLogStoreError.filePersistenceUnavailable
        }

        await filePersistenceTask?.value
        return try await filePersistence.prepareLogsDirectory()
    }

    func flushFilePersistence() async {
        guard let filePersistence else {
            return
        }

        let previousTask = filePersistenceTask
        let flushTask = Task<Result<Bool, Error>, Never> { @MainActor in
            await previousTask?.value
            do {
                try await filePersistence.flush()
                return .success(try await filePersistence.hasLogFiles())
            } catch {
                return .failure(error)
            }
        }
        let barrierTask = Task { @MainActor [weak self] in
            guard let self else {
                _ = await flushTask.value
                return
            }

            switch await flushTask.value {
            case .success(let hasLogFiles):
                self.updatePersistedLogFileState(hasLogFiles)
            case .failure(let error):
                self.reportFilePersistenceFailure(error)
            }
        }
        filePersistenceTask = barrierTask
        await barrierTask.value
    }

    func prepareForApplicationTermination() async {
        fileMaintenanceTask?.cancel()
        fileMaintenanceTask = nil
        await flushFilePersistence()
    }

    private func persistToFile(_ record: EventLogRecord) {
        let line = Self.formattedFileLine(record)
        enqueueFilePersistenceOperation { filePersistence in
            try await filePersistence.append(line)
            return true
        }
    }

    private func refreshPersistedLogFileState() {
        enqueueFilePersistenceOperation { filePersistence in
            try await filePersistence.hasLogFiles()
        }
    }

    private func performFileMaintenance() {
        enqueueFilePersistenceOperation { filePersistence in
            try await filePersistence.performMaintenance()
            return try await filePersistence.hasLogFiles()
        }
    }

    private func enqueueFilePersistenceOperation(
        _ operation: @escaping (
            any EventLogFilePersisting
        ) async throws -> Bool
    ) {
        guard let filePersistence else {
            return
        }

        let previousTask = filePersistenceTask
        filePersistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let hasLogFiles = try await operation(
                    filePersistence
                )
                self?.updatePersistedLogFileState(hasLogFiles)
            } catch {
                self?.reportFilePersistenceFailure(error)
            }
        }
    }

    private func updatePersistedLogFileState(_ hasLogFiles: Bool) {
        guard hasPersistedLogFiles != hasLogFiles else {
            return
        }
        hasPersistedLogFiles = hasLogFiles
    }

    private func startFileMaintenance() {
        fileMaintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: Self.fileMaintenanceIntervalNanoseconds
                    )
                } catch {
                    return
                }

                guard let self else {
                    return
                }
                self.performFileMaintenance()
            }
        }
    }

    private func reportFilePersistenceFailure(_ error: Error) {
        guard !didReportFilePersistenceFailure else {
            return
        }
        didReportFilePersistenceFailure = true

        let failureRecord = EventLogRecord(
            date: Date(),
            level: .error,
            category: .application,
            message: "Event log file storage failed: " +
                EventLogErrorFormatter.description(for: error)
        )
        appendToDisplay(failureRecord)
        writeToUnifiedLog(failureRecord)
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
        return formattedLine(record, timestamp: timestamp)
    }

    private static func formattedFileLine(
        _ record: EventLogRecord
    ) -> String {
        let timestamp = fileTimestampFormatter.string(from: record.date)
        return formattedLine(record, timestamp: timestamp)
    }

    private static func formattedLine(
        _ record: EventLogRecord,
        timestamp: String
    ) -> String {
        return "[\(timestamp)] [\(record.level.logLabel)] " +
            "[\(record.category.rawValue)] \(record.message)\n"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()
}

private enum EventLogStoreError: LocalizedError {
    case filePersistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .filePersistenceUnavailable:
            String(localized: "Event log file storage is unavailable.")
        }
    }
}
