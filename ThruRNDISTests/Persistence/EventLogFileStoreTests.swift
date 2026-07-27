import Foundation
import XCTest
@testable import ThruRNDIS

final class EventLogFileStoreTests: XCTestCase {
    private static let utc = TimeZone(secondsFromGMT: 0)!

    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ThruRNDIS-EventLogFileStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        temporaryDirectoryURL = url
    }

    override func tearDownWithError() throws {
        guard let temporaryDirectoryURL else {
            return
        }

        if FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        self.temporaryDirectoryURL = nil
    }

    func testDefaultMaximumFileSizeIsTenMiB() {
        XCTAssertEqual(
            EventLogFileStore.defaultMaximumFileSizeBytes,
            10 * 1024 * 1024
        )
        XCTAssertEqual(
            EventLogFileStore.defaultRotationInterval,
            24 * 60 * 60
        )
    }

    @MainActor
    func testFileSystemPreparationIsDeferredUntilActorWorkBegins() async throws {
        let store = makeStore(
            sessionStartDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.logsDirectoryURL.path
            )
        )

        try await store.performMaintenance()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.logsDirectoryURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testExactByteLimitStaysInFirstFileAndNextByteRotates() async throws {
        let sessionStartDate = Date(timeIntervalSince1970: 1)
        let store = makeStore(
            sessionStartDate: sessionStartDate,
            maximumFileSizeBytes: 16
        )

        try await store.append(String(repeating: "a", count: 16))

        let urls = try logFileURLs(in: store.logsDirectoryURL)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["19700101-000001.log"])
        XCTAssertEqual(try Data(contentsOf: urls[0]).count, 16)

        try await store.append("b")

        let filesByName = try logFilesByName(
            in: store.logsDirectoryURL
        )
        XCTAssertEqual(
            Set(filesByName.keys),
            Set(["19700101-000001.log", "19700101-000001-2.log"])
        )
        XCTAssertEqual(
            try Data(
                contentsOf: XCTUnwrap(
                    filesByName["19700101-000001.log"]
                )
            ),
            Data(repeating: 0x61, count: 16)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: XCTUnwrap(
                    filesByName["19700101-000001-2.log"]
                )
            ),
            Data("b".utf8)
        )
    }

    @MainActor
    func testOversizedRecordIsPreservedInOneFile() async throws {
        let maximumFileSizeBytes = 13
        let line = String(repeating: "0123456789", count: 8)
        let store = makeStore(
            sessionStartDate: Date(timeIntervalSince1970: 2),
            maximumFileSizeBytes: maximumFileSizeBytes
        )

        try await store.append(line)

        let urls = try logFileURLs(in: store.logsDirectoryURL)
        XCTAssertEqual(urls.count, 1)
        XCTAssertGreaterThan(
            try Data(contentsOf: urls[0]).count,
            maximumFileSizeBytes
        )
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data(line.utf8))
    }

    @MainActor
    func testOversizedUTF8RecordRemainsValidAndLossless() async throws {
        let maximumFileSizeBytes = 7
        let line = "가나다라마바사🙂끝"
        let store = makeStore(
            sessionStartDate: Date(timeIntervalSince1970: 3),
            maximumFileSizeBytes: maximumFileSizeBytes
        )

        try await store.append(line)

        let urls = try logFileURLs(in: store.logsDirectoryURL)
        XCTAssertEqual(urls.count, 1)
        let data = try Data(contentsOf: urls[0])
        XCTAssertGreaterThan(data.count, maximumFileSizeBytes)
        XCTAssertEqual(String(data: data, encoding: .utf8), line)
    }

    @MainActor
    func testSequentialAppendsAndFlushPreserveRecordOrder() async throws {
        let store = makeStore(
            sessionStartDate: Date(timeIntervalSince1970: 3),
            maximumFileSizeBytes: 1_024
        )

        try await store.append("first\n")
        try await store.append("second\n")
        try await store.append("third\n")
        try await store.flush()

        let urls = try logFileURLs(in: store.logsDirectoryURL)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(
            try String(contentsOf: urls[0], encoding: .utf8),
            "first\nsecond\nthird\n"
        )
    }

    @MainActor
    func testSessionNameCollisionSelectsThirdFileWithoutOverwriting() async throws {
        let sessionStartDate = Date(timeIntervalSince1970: 1)
        let layoutStore = makeStore(
            sessionStartDate: sessionStartDate,
            maximumFileSizeBytes: 64
        )
        try await layoutStore.performMaintenance()
        let baseURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "19700101-000001.log"
        )
        let secondURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "19700101-000001-2.log"
        )
        let thirdURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "19700101-000001-3.log"
        )
        let baseData = Data("previous base".utf8)
        let secondData = Data("previous rotation".utf8)
        try baseData.write(to: baseURL)
        try secondData.write(to: secondURL)

        let store = makeStore(
            sessionStartDate: sessionStartDate,
            maximumFileSizeBytes: 64
        )
        try await store.append("current session")

        let urls = try logFileURLs(in: store.logsDirectoryURL)
        XCTAssertEqual(
            Set(urls.map(\.lastPathComponent)),
            Set([
                "19700101-000001.log",
                "19700101-000001-2.log",
                "19700101-000001-3.log"
            ])
        )
        XCTAssertEqual(try Data(contentsOf: baseURL), baseData)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondData)
        XCTAssertEqual(
            try Data(contentsOf: thirdURL),
            Data("current session".utf8)
        )
    }

    @MainActor
    func testInitialMaintenanceRemovesOnlyRegularLogsOlderThanSevenDays() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let retentionInterval = EventLogFileStore.defaultRetentionInterval
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let layoutStore = makeStore(
            sessionStartDate: now,
            now: now
        )
        try await layoutStore.performMaintenance()
        let expiredLogURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "expired.log"
        )
        let cutoffLogURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "cutoff.log"
        )
        let recentLogURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "recent.log"
        )
        let expiredTextURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "expired.txt"
        )
        let logDirectoryURL = layoutStore.logsDirectoryURL.appendingPathComponent(
            "directory.log",
            isDirectory: true
        )

        for url in [expiredLogURL, cutoffLogURL, recentLogURL, expiredTextURL] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(
            at: logDirectoryURL,
            withIntermediateDirectories: false
        )
        try setModificationDate(
            cutoff.addingTimeInterval(-1),
            for: expiredLogURL
        )
        try setModificationDate(cutoff, for: cutoffLogURL)
        try setModificationDate(
            cutoff.addingTimeInterval(1),
            for: recentLogURL
        )
        try setModificationDate(
            cutoff.addingTimeInterval(-1),
            for: expiredTextURL
        )
        try setModificationDate(
            cutoff.addingTimeInterval(-1),
            for: logDirectoryURL
        )

        let cleanupStore = makeStore(
            sessionStartDate: now.addingTimeInterval(1),
            now: now
        )
        try await cleanupStore.performMaintenance()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expiredLogURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cutoffLogURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recentLogURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expiredTextURL.path)
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: logDirectoryURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testIdleMaintenanceRotatesAndRemovesExpiredActiveSegment() async throws {
        let sessionStartDate = Date(timeIntervalSince1970: 1)
        let clock = EventLogTestClock(date: sessionStartDate)
        let store = EventLogFileStore(
            applicationSupportDirectoryURL: temporaryDirectoryURL,
            bundleIdentifier: "EventLogFileStoreTests",
            sessionStartDate: sessionStartDate,
            timeZone: Self.utc,
            maximumFileSizeBytes: 1_024,
            now: { clock.now() },
            header: ""
        )

        try await store.append("old")

        let baseURL = store.logsDirectoryURL.appendingPathComponent(
            "19700101-000001.log"
        )
        try setModificationDate(sessionStartDate, for: baseURL)

        clock.setDate(
            sessionStartDate.addingTimeInterval(
                EventLogFileStore.defaultRetentionInterval + 1
            )
        )
        try await store.performMaintenance()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: baseURL.path)
        )
        let hasLogFilesAfterMaintenance = try await store.hasLogFiles()
        XCTAssertFalse(hasLogFilesAfterMaintenance)

        try await store.append("new")

        let currentURL = store.logsDirectoryURL.appendingPathComponent(
            "19700101-000001-2.log"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: currentURL.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: currentURL),
            Data("new".utf8)
        )
    }

    @MainActor
    func testAppendRotatesAfterTwentyFourHoursWithoutReachingSizeLimit() async throws {
        let sessionStartDate = Date(timeIntervalSince1970: 1)
        let clock = EventLogTestClock(date: sessionStartDate)
        let store = EventLogFileStore(
            applicationSupportDirectoryURL: temporaryDirectoryURL,
            bundleIdentifier: "EventLogFileStoreTests",
            sessionStartDate: sessionStartDate,
            timeZone: Self.utc,
            maximumFileSizeBytes: 1_024,
            now: { clock.now() },
            header: ""
        )

        try await store.append("first\n")
        clock.setDate(
            sessionStartDate.addingTimeInterval(
                EventLogFileStore.defaultRotationInterval - 1
            )
        )
        try await store.append("before boundary\n")

        clock.setDate(
            sessionStartDate.addingTimeInterval(
                EventLogFileStore.defaultRotationInterval
            )
        )
        try await store.append("at boundary\n")
        try await store.flush()

        let filesByName = try logFilesByName(
            in: store.logsDirectoryURL
        )
        XCTAssertEqual(
            Set(filesByName.keys),
            Set(["19700101-000001.log", "19700101-000001-2.log"])
        )
        XCTAssertEqual(
            try String(
                contentsOf: XCTUnwrap(
                    filesByName["19700101-000001.log"]
                ),
                encoding: .utf8
            ),
            "first\nbefore boundary\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: XCTUnwrap(
                    filesByName["19700101-000001-2.log"]
                ),
                encoding: .utf8
            ),
            "at boundary\n"
        )
    }

    @MainActor
    func testDailyRotationBoundsRetentionDuringLongRunningSession() async throws {
        let sessionStartDate = Date(timeIntervalSince1970: 1)
        let clock = EventLogTestClock(date: sessionStartDate)
        let store = EventLogFileStore(
            applicationSupportDirectoryURL: temporaryDirectoryURL,
            bundleIdentifier: "EventLogFileStoreTests",
            sessionStartDate: sessionStartDate,
            timeZone: Self.utc,
            maximumFileSizeBytes: 1_024,
            now: { clock.now() },
            header: ""
        )

        for day in 0...8 {
            let currentDate = sessionStartDate.addingTimeInterval(
                TimeInterval(day) * EventLogFileStore.defaultRotationInterval
            )
            clock.setDate(currentDate)
            try await store.append("day \(day)\n")

            let sequence = day + 1
            let suffix = sequence == 1 ? "" : "-\(sequence)"
            let currentURL = store.logsDirectoryURL.appendingPathComponent(
                "19700101-000001\(suffix).log"
            )
            try setModificationDate(currentDate, for: currentURL)
        }

        let urls = try logFileURLs(in: store.logsDirectoryURL)
        XCTAssertEqual(
            Set(urls.map(\.lastPathComponent)),
            Set((2...9).map {
                "19700101-000001-\($0).log"
            })
        )
        XCTAssertFalse(
            urls.contains {
                $0.lastPathComponent == "19700101-000001.log"
            }
        )
    }

    @MainActor
    func testExportCopiesOnlyCurrentSessionFilesWithOriginalNames() async throws {
        let now = Date(timeIntervalSince1970: 1_785_153_600)
        let store = makeStore(
            sessionStartDate: now,
            maximumFileSizeBytes: 5,
            now: now
        )
        try await store.performMaintenance()
        let priorURL = store.logsDirectoryURL.appendingPathComponent(
            "20260727-120000.log"
        )
        let priorRotationURL = store.logsDirectoryURL.appendingPathComponent(
            "20260727-120000-2.log"
        )
        try Data("prior".utf8).write(to: priorURL)
        try Data("older rotation".utf8).write(to: priorRotationURL)
        try Data("not exported".utf8).write(
            to: store.logsDirectoryURL.appendingPathComponent("notes.txt")
        )
        let hasLogFilesBeforeAppend = try await store.hasLogFiles()
        XCTAssertFalse(hasLogFilesBeforeAppend)

        try await store.append("abcde")
        try await store.append("fgh")
        let hasLogFilesAfterAppend = try await store.hasLogFiles()
        XCTAssertTrue(hasLogFilesAfterAppend)

        let destinationURL = temporaryDirectoryURL.appendingPathComponent(
            "Export Destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: false
        )

        let exportedURL = try await store.exportLogFiles(
            to: destinationURL
        )

        XCTAssertEqual(
            exportedURL,
            destinationURL.standardizedFileURL
        )
        let exportedFilesByName = try logFilesByName(in: destinationURL)
        XCTAssertEqual(
            Set(exportedFilesByName.keys),
            Set([
                "20260727-120000-3.log",
                "20260727-120000-4.log"
            ])
        )
        XCTAssertEqual(
            try Data(
                contentsOf: XCTUnwrap(
                    exportedFilesByName["20260727-120000-3.log"]
                )
            ),
            Data("abcde".utf8)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: XCTUnwrap(
                    exportedFilesByName["20260727-120000-4.log"]
                )
            ),
            Data("fgh".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: priorURL), Data("prior".utf8))
        XCTAssertEqual(
            try Data(contentsOf: priorRotationURL),
            Data("older rotation".utf8)
        )
    }

    @MainActor
    func testLogsDirectoryAndCreatedFilesUsePrivatePermissions() async throws {
        let store = makeStore(
            sessionStartDate: Date(timeIntervalSince1970: 4),
            maximumFileSizeBytes: 8
        )
        try await store.append("123456789")

        XCTAssertEqual(
            try posixPermissions(at: store.logsDirectoryURL),
            0o700
        )
        for url in try logFileURLs(in: store.logsDirectoryURL) {
            XCTAssertEqual(
                try posixPermissions(at: url),
                0o600,
                url.lastPathComponent
            )
        }
    }

    @MainActor
    private func makeStore(
        sessionStartDate: Date,
        maximumFileSizeBytes: Int = 1_024,
        now: Date? = nil
    ) -> EventLogFileStore {
        let resolvedNow = now ?? sessionStartDate
        return EventLogFileStore(
            applicationSupportDirectoryURL: temporaryDirectoryURL,
            bundleIdentifier: "EventLogFileStoreTests",
            sessionStartDate: sessionStartDate,
            timeZone: Self.utc,
            maximumFileSizeBytes: maximumFileSizeBytes,
            now: { resolvedNow },
            header: ""
        )
    }

    private func logFileURLs(in directoryURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        .filter {
            $0.pathExtension.lowercased() == "log" &&
                (try? $0.resourceValues(
                    forKeys: [.isRegularFileKey]
                ).isRegularFile) == true
        }
    }

    private func logFilesByName(
        in directoryURL: URL
    ) throws -> [String: URL] {
        Dictionary(
            uniqueKeysWithValues: try logFileURLs(
                in: directoryURL
            ).map {
                ($0.lastPathComponent, $0)
            }
        )
    }

    private func setModificationDate(
        _ date: Date,
        for url: URL
    ) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let value = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }
}

private final class EventLogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock {
            date
        }
    }

    func setDate(_ date: Date) {
        lock.withLock {
            self.date = date
        }
    }
}
