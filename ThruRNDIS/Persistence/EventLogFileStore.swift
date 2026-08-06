/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation
import OSLog

enum EventLogFileStoreError: LocalizedError {
    case invalidDestinationDirectory(URL)
    case noLogFilesAvailable

    var errorDescription: String? {
        switch self {
        case .invalidDestinationDirectory(let url):
            "The event log export destination is not a directory: \(url.path)"
        case .noLogFilesAvailable:
            "There are no saved event log files to export."
        }
    }
}

actor EventLogFileStore {
    nonisolated static let defaultMaximumFileSizeBytes = 10 * 1024 * 1024
    nonisolated static let defaultRotationInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let defaultRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

    nonisolated let logsDirectoryURL: URL

    private static let cleanupInterval: TimeInterval = 24 * 60 * 60
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ThruRNDIS",
        category: "EventLogFiles"
    )

    private let fileManager = FileManager.default
    private let maximumFileSizeBytes: Int
    private let rotationInterval: TimeInterval
    private let retentionInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let headerData: Data
    private let sessionFileStem: String

    private var currentFileHandle: FileHandle?
    private var currentFileURL: URL?
    private var currentFileOpenedAt: Date?
    private var currentFileSizeBytes = 0
    private var nextFileSequence = 1
    private var currentSessionFileURLs: [URL] = []
    private var nextCleanupDate: Date?
    private var isPrepared = false

    init(
        applicationSupportDirectoryURL: URL? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        sessionStartDate: Date? = nil,
        timeZone: TimeZone = .current,
        maximumFileSizeBytes: Int = EventLogFileStore.defaultMaximumFileSizeBytes,
        rotationInterval: TimeInterval = EventLogFileStore.defaultRotationInterval,
        retentionInterval: TimeInterval = EventLogFileStore.defaultRetentionInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        header: String? = nil
    ) {
        precondition(maximumFileSizeBytes > 0)
        precondition(rotationInterval > 0)
        precondition(retentionInterval > 0)

        let resolvedSessionStartDate = sessionStartDate ?? now()
        let resolvedHeader = header ?? Self.defaultHeader(
            sessionStartDate: resolvedSessionStartDate,
            timeZone: timeZone
        )
        let resolvedHeaderData = Data(resolvedHeader.utf8)
        precondition(resolvedHeaderData.count < maximumFileSizeBytes)

        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.rotationInterval = rotationInterval
        self.retentionInterval = retentionInterval
        self.now = now
        self.headerData = resolvedHeaderData
        sessionFileStem = Self.timestampStem(
            for: resolvedSessionStartDate,
            timeZone: timeZone
        )

        let defaultFileManager = FileManager.default
        let applicationSupportURL = applicationSupportDirectoryURL
            ?? defaultFileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? defaultFileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        let applicationDirectoryURL = applicationSupportURL.appendingPathComponent(
            bundleIdentifier ?? ProcessInfo.processInfo.processName,
            isDirectory: true
        )
        logsDirectoryURL = applicationDirectoryURL.appendingPathComponent(
            "Logs",
            isDirectory: true
        )
    }

    func hasLogFiles() throws -> Bool {
        let inspectionDate = now()
        try prepareIfNeeded(at: inspectionDate)
        try rotateCurrentFileIfNeeded(at: inspectionDate)
        try removeExpiredLogFilesIfNeeded(at: inspectionDate)
        return availableCurrentSessionFileURLs().isEmpty == false
    }

    func prepareLogsDirectory() throws -> URL {
        try prepareIfNeeded(at: now())
        return logsDirectoryURL
    }

    func append(_ line: String) throws {
        let appendDate = now()
        try prepareIfNeeded(at: appendDate)
        try rotateCurrentFileIfNeeded(at: appendDate)
        try removeExpiredLogFilesIfNeeded(at: appendDate)

        let data = Data(line.utf8)
        guard !data.isEmpty else {
            return
        }

        try ensureCurrentFile(openedAt: appendDate)
        if currentFileSizeBytes > headerData.count,
           currentFileSizeBytes + data.count > maximumFileSizeBytes {
            try closeCurrentFile()
            try ensureCurrentFile(openedAt: appendDate)
        }
        try write(data)
    }

    func flush() throws {
        try currentFileHandle?.synchronize()
    }

    func performMaintenance() throws {
        let maintenanceDate = now()
        try prepareIfNeeded(at: maintenanceDate)
        try rotateCurrentFileIfNeeded(at: maintenanceDate)
        try removeExpiredLogFiles(at: maintenanceDate)
        nextCleanupDate = maintenanceDate.addingTimeInterval(
            Self.cleanupInterval
        )
    }

    func exportLogFiles(
        to destinationDirectoryURL: URL
    ) throws -> URL {
        let exportDate = now()
        try prepareIfNeeded(at: exportDate)
        try rotateCurrentFileIfNeeded(at: exportDate)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: destinationDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw EventLogFileStoreError.invalidDestinationDirectory(
                destinationDirectoryURL
            )
        }

        try flush()
        try removeExpiredLogFiles(at: exportDate)
        nextCleanupDate = exportDate.addingTimeInterval(
            Self.cleanupInterval
        )
        let sourceURLs = availableCurrentSessionFileURLs()
        guard !sourceURLs.isEmpty else {
            throw EventLogFileStoreError.noLogFilesAvailable
        }

        var exportedURLs: [URL] = []
        do {
            for sourceURL in sourceURLs {
                let exportedURL = destinationDirectoryURL
                    .appendingPathComponent(sourceURL.lastPathComponent)
                try fileManager.copyItem(at: sourceURL, to: exportedURL)
                exportedURLs.append(exportedURL)
            }
        } catch {
            for exportedURL in exportedURLs {
                try? fileManager.removeItem(at: exportedURL)
            }
            throw error
        }

        return exportedURLs.count == 1
            ? exportedURLs[0]
            : destinationDirectoryURL
    }

    private func prepareIfNeeded(at date: Date) throws {
        guard !isPrepared else {
            return
        }

        try secureLogsDirectory()
        try removeExpiredLogFiles(at: date)
        nextCleanupDate = date.addingTimeInterval(Self.cleanupInterval)
        isPrepared = true
    }

    private func secureLogsDirectory() throws {
        try fileManager.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: logsDirectoryURL.path
        )
    }

    private func ensureCurrentFile(openedAt date: Date) throws {
        guard currentFileHandle == nil else {
            return
        }

        while true {
            let candidateURL = logFileURL(sequence: nextFileSequence)
            let descriptorResult = Self.openExclusiveFile(at: candidateURL)

            switch descriptorResult {
            case .opened(let descriptor):
                let handle = FileHandle(
                    fileDescriptor: descriptor,
                    closeOnDealloc: true
                )
                do {
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: candidateURL.path
                    )
                    if !headerData.isEmpty {
                        try handle.write(contentsOf: headerData)
                    }
                } catch {
                    try? handle.close()
                    try? fileManager.removeItem(at: candidateURL)
                    throw error
                }

                currentFileHandle = handle
                currentFileURL = candidateURL.standardizedFileURL
                currentFileOpenedAt = date
                currentFileSizeBytes = headerData.count
                currentSessionFileURLs.append(candidateURL.standardizedFileURL)
                nextFileSequence += 1
                return

            case .alreadyExists:
                nextFileSequence += 1

            case .failed(let code):
                throw Self.posixError(code: code, url: candidateURL)
            }
        }
    }

    private func write(_ data: Data) throws {
        guard !data.isEmpty, let currentFileHandle else {
            return
        }
        try currentFileHandle.write(contentsOf: data)
        currentFileSizeBytes += data.count
    }

    private func closeCurrentFile() throws {
        guard let currentFileHandle else {
            return
        }
        try currentFileHandle.close()
        self.currentFileHandle = nil
        currentFileURL = nil
        currentFileOpenedAt = nil
        currentFileSizeBytes = 0
    }

    private func rotateCurrentFileIfNeeded(at date: Date) throws {
        guard let currentFileOpenedAt,
              date.timeIntervalSince(currentFileOpenedAt) >= rotationInterval
        else {
            return
        }
        try closeCurrentFile()
    }

    private func removeExpiredLogFilesIfNeeded(at date: Date) throws {
        guard let scheduledCleanupDate = nextCleanupDate,
              date >= scheduledCleanupDate else {
            return
        }
        try removeExpiredLogFiles(at: date)
        nextCleanupDate = date.addingTimeInterval(Self.cleanupInterval)
    }

    private func removeExpiredLogFiles(at date: Date) throws {
        let expirationDate = date.addingTimeInterval(-retentionInterval)
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: logsDirectoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )

        for url in urls where url.pathExtension.lowercased() == "log" {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL != currentFileURL else {
                continue
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: resourceKeys)
            } catch {
                Self.logger.error(
                    "Could not inspect event log retention metadata for \(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
                continue
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate < expirationDate else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Self.logger.error(
                    "Could not remove expired event log \(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func availableCurrentSessionFileURLs() -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        return currentSessionFileURLs.filter { url in
            guard let values = try? url.resourceValues(
                forKeys: resourceKeys
            ) else {
                return false
            }
            return values.isRegularFile == true
                && values.isSymbolicLink != true
        }
    }

    private func logFileURL(sequence: Int) -> URL {
        let suffix = sequence == 1 ? "" : "-\(sequence)"
        return logsDirectoryURL.appendingPathComponent(
            "\(sessionFileStem)\(suffix).log",
            isDirectory: false
        )
    }

    private static func timestampStem(
        for date: Date,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func defaultHeader(
        sessionStartDate: Date,
        timeZone: TimeZone
    ) -> String {
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"

        return "ThruRNDIS Version: \(appVersion) (\(appBuild))\n" +
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n" +
            "Session Started: \(dateFormatter.string(from: sessionStartDate))\n\n"
    }

    private static func openExclusiveFile(
        at url: URL
    ) -> ExclusiveFileOpenResult {
        let result = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else {
                return (-1, EINVAL)
            }
            let descriptor = Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
            return (descriptor, descriptor == -1 ? errno : 0)
        }

        if result.0 >= 0 {
            return .opened(result.0)
        }
        if result.1 == EEXIST {
            return .alreadyExists
        }
        return .failed(result.1)
    }

    private static func posixError(code: Int32, url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}

private enum ExclusiveFileOpenResult {
    case opened(Int32)
    case alreadyExists
    case failed(Int32)
}
