/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum VMAssetDownloadError: LocalizedError {
    case invalidResponse(String)
    case httpStatus(Int, String)
    case sizeMismatch(name: String, expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let name):
            return String(localized: "The download response for \(name) was invalid.")
        case .httpStatus(let status, let name):
            return String(localized: "Downloading \(name) failed with HTTP \(status).")
        case .sizeMismatch(let name, let expected, let actual):
            return String(localized: "Downloaded \(name) has an unexpected size (expected \(expected) bytes, received \(actual)).")
        }
    }
}

final class VMAssetDownloadService {
    private let session: URLSession
    private let fileManager: FileManager
    private let layout: VMAssetStorageLayout

    init(
        configuration: URLSessionConfiguration = VMAssetDownloadService.downloadConfiguration(),
        fileManager: FileManager = .default,
        layout: VMAssetStorageLayout = VMAssetStorageLayout()
    ) {
        self.session = URLSession(configuration: configuration)
        self.fileManager = fileManager
        self.layout = layout
        try? fileManager.removeItem(at: layout.stagingDirectoryURL)
    }

    func download(
        release: VMAssetReleaseDescriptor,
        operationID: UUID,
        progress: @escaping (VMAssetDownloadProgress) -> Void,
        eventLog: @escaping EventLogHandler
    ) async throws -> DownloadedVMAssetPackage {
        let stagingURL = layout.stagingURL(for: operationID)
        do {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let assets = [release.archive, release.checksums]
            let totalBytes = release.totalDownloadBytes
            var completedBytes: Int64 = 0

            for asset in assets {
                let destinationURL = stagingURL.appendingPathComponent(asset.name, isDirectory: false)
                let previouslyCompletedBytes = completedBytes
                try await download(
                    asset: asset,
                    destinationURL: destinationURL,
                    progress: { downloadedBytes in
                        progress(VMAssetDownloadProgress(
                            downloadedBytes: previouslyCompletedBytes + downloadedBytes,
                            totalBytes: totalBytes
                        ))
                    },
                    eventLog: eventLog
                )
                completedBytes += max(asset.size, 0)
            }

            try Task.checkCancellation()
            return DownloadedVMAssetPackage(
                release: release,
                stagingDirectoryURL: stagingURL,
                archiveURL: stagingURL.appendingPathComponent(release.archive.name),
                checksumsURL: stagingURL.appendingPathComponent(release.checksums.name)
            )
        } catch {
            discardStagingData(for: operationID)
            throw error
        }
    }

    func discardStagingData(for operationID: UUID) {
        try? fileManager.removeItem(at: layout.stagingURL(for: operationID))
    }

    private static func downloadConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 30 * 60
        return configuration
    }

    private func download(
        asset: VMAssetRemoteAsset,
        destinationURL: URL,
        progress: @escaping (Int64) -> Void,
        eventLog: @escaping EventLogHandler
    ) async throws {
        let maximumRetries = 3
        var resumeData: Data?
        // Resume data belongs only to this file in this installation operation.
        // If cancellation interrupts backoff, discard the system's resumable task too.
        defer {
            if let resumeData {
                session.downloadTask(withResumeData: resumeData).cancel()
            }
        }

        for attempt in 0...maximumRetries {
            try Task.checkCancellation()
            let log: EventLogHandler = { message, level in
                eventLog("Download \(asset.name) [\(attempt + 1)/\(maximumRetries + 1)]: \(message)", level)
            }
            let delegate = VMAssetDownloadDelegate(
                asset: asset, destinationURL: destinationURL, fileManager: fileManager,
                progress: progress, eventLog: log
            )
            log("Starting \(resumeData == nil ? "new download" : "resume"); " +
                "host=\(asset.downloadURL.host ?? "unknown"), expected=\(asset.size) bytes, " +
                "idleTimeout=\(Int(session.configuration.timeoutIntervalForRequest))s, " +
                "resourceTimeout=\(Int(session.configuration.timeoutIntervalForResource))s.", .debug)
            do {
                let task: URLSessionDownloadTask
                if let data = resumeData {
                    resumeData = nil
                    task = session.downloadTask(withResumeData: data)
                } else {
                    progress(0)
                    var request = URLRequest(url: asset.downloadURL)
                    request.timeoutInterval = session.configuration.timeoutIntervalForRequest
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    request.setValue("ThruRNDIS", forHTTPHeaderField: "User-Agent")
                    task = session.downloadTask(with: request)
                }
                try await delegate.download(task: task)
                try Task.checkCancellation()
                log("Completed; \(delegate.diagnostic).", .debug)
                return
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                if Task.isCancelled || error is CancellationError {
                    log("Cancelled; \(delegate.diagnostic).", .debug)
                    throw CancellationError()
                }
                let reason = "\(EventLogErrorFormatter.description(for: error)); \(delegate.diagnostic)"
                guard attempt < maximumRetries, Self.isTransientConnectionError(error) else {
                    log("Failed; no further retry: \(reason).", .error)
                    throw error
                }
                let delay = 1 << attempt
                log("Interrupted: \(reason). Retry \(attempt + 1)/\(maximumRetries) in \(delay)s " +
                    "using \(resumeData == nil ? "a new download" : "resume data").", .warning)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    log("Cancelled while waiting to retry.", .debug)
                    throw error
                }
            }
        }
    }

    private static func isTransientConnectionError(_ error: Error) -> Bool {
        guard let error = error as? URLError else {
            return false
        }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

// Delegate callbacks and the heartbeat share observations with cancellation handlers.
// Protect state with the lock and invoke external callbacks after releasing it.
private final class VMAssetDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let asset: VMAssetRemoteAsset
    private let destinationURL: URL
    private let fileManager: FileManager
    private let progress: (Int64) -> Void
    private let eventLog: EventLogHandler
    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastReceivedAt = ProcessInfo.processInfo.systemUptime
    private var lastProgressAt: TimeInterval = 0
    private var receivedBytes: Int64 = 0
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    init(asset: VMAssetRemoteAsset, destinationURL: URL, fileManager: FileManager,
         progress: @escaping (Int64) -> Void, eventLog: @escaping EventLogHandler) {
        self.asset = asset
        self.destinationURL = destinationURL
        self.fileManager = fileManager
        self.progress = progress
        self.eventLog = eventLog
    }

    func download(task: URLSessionDownloadTask) async throws {
        let heartbeat = Task {
            do {
                while true {
                    try await Task.sleep(for: .seconds(15))
                    reportProgress()
                }
            } catch { /* Download completed or cancelled. */ }
        }
        defer { heartbeat.cancel() }

        task.delegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = lock.withLock {
                    guard !cancelled else { return false }
                    self.continuation = continuation
                    return true
                }
                if shouldStart {
                    task.resume()
                } else {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            task.cancel()
        }
    }

    var diagnostic: String {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            return "received=\(receivedBytes)/\(asset.size) bytes, " +
                "elapsed=\(Int(now - startedAt))s, idle=\(Int(now - lastReceivedAt))s, " +
                "HTTP=\(response.map { String($0.statusCode) } ?? "pending"), " +
                "host=\(response?.url?.host ?? asset.downloadURL.host ?? "unknown")"
        }
    }

    func reportProgress() {
        let stalled = lock.withLock { ProcessInfo.processInfo.systemUptime - lastReceivedAt >= 30 }
        eventLog("\(stalled ? "Waiting for data" : "Progress"): \(diagnostic).", stalled ? .warning : .debug)
    }

    private func validate(response: URLResponse?, receivedBytes: Int64, complete: Bool) throws {
        guard let response = response as? HTTPURLResponse else {
            throw VMAssetDownloadError.invalidResponse(asset.name)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw VMAssetDownloadError.httpStatus(response.statusCode, asset.name)
        }
        let invalidSize = complete ? receivedBytes != asset.size : receivedBytes > asset.size
        if asset.size >= 0, invalidSize {
            throw VMAssetDownloadError.sizeMismatch(name: asset.name, expected: asset.size, actual: receivedBytes)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let action = lock.withLock { () -> (cancel: Bool, report: Bool) in
            let now = ProcessInfo.processInfo.systemUptime
            receivedBytes = totalBytesWritten
            if bytesWritten > 0 { lastReceivedAt = now }
            response = downloadTask.response as? HTTPURLResponse
            do {
                try validate(response: response, receivedBytes: totalBytesWritten, complete: false)
            } catch {
                failure = error
                return (true, false)
            }
            let report = now - lastProgressAt >= 0.2
            if report { lastProgressAt = now }
            return (false, report)
        }
        if action.cancel { downloadTask.cancel() }
        if action.report { progress(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.withLock {
            receivedBytes = fileOffset
            lastReceivedAt = ProcessInfo.processInfo.systemUptime
        }
        eventLog("Resumed at \(fileOffset) bytes.", .debug)
        progress(fileOffset)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Validate and move the file before URLSession removes its temporary URL.
        do {
            let attributes = try fileManager.attributesOfItem(atPath: location.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            try validate(response: downloadTask.response, receivedBytes: size, complete: true)
            try fileManager.moveItem(at: location, to: destinationURL)
            progress(size)
        } catch {
            lock.withLock { failure = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (completion, failure) = lock.withLock {
            let completion = continuation
            continuation = nil
            response = task.response as? HTTPURLResponse
            // Preserve validation errors that caused URLSession to report cancellation.
            return (completion, self.failure ?? error)
        }
        if let failure {
            completion?.resume(throwing: failure)
        } else {
            completion?.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        // Never log complete redirected URLs, which can contain signed query parameters.
        let transactions = metrics.transactionMetrics.map { transaction in
            "host=\(transaction.request.url?.host ?? "unknown"), " +
                "HTTP=\((transaction.response as? HTTPURLResponse).map { String($0.statusCode) } ?? "none"), " +
                "protocol=\(transaction.networkProtocolName ?? "unknown"), " +
                "reused=\(transaction.isReusedConnection), proxy=\(transaction.isProxyConnection)"
        }.joined(separator: "; ")
        eventLog("Transport: redirects=\(metrics.redirectCount); \(transactions).", .debug)
    }
}
