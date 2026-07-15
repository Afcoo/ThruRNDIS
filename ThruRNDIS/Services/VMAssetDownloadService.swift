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

final class VMAssetDownloadService: VMAssetDownloading {
    private let session: URLSession
    private let fileManager: FileManager
    private let layout: VMAssetStorageLayout

    init(
        configuration: URLSessionConfiguration = .default,
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
        progress: @escaping (Double) -> Void
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
            let totalBytes = max(assets.reduce(Int64(0)) { $0 + max($1.size, 0) }, 1)
            var completedBytes: Int64 = 0

            for asset in assets {
                try Task.checkCancellation()
                let destinationURL = stagingURL.appendingPathComponent(asset.name, isDirectory: false)
                try await download(
                    asset: asset,
                    destinationURL: destinationURL,
                    progress: { fraction in
                        let currentBytes = Int64(Double(max(asset.size, 0)) * fraction)
                        progress(Double(completedBytes + currentBytes) / Double(totalBytes))
                    }
                )
                try Task.checkCancellation()
                completedBytes += max(asset.size, 0)
                progress(Double(completedBytes) / Double(totalBytes))
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
        let stagingURL = layout.stagingURL(for: operationID)
        guard fileManager.fileExists(atPath: stagingURL.path) else {
            return
        }
        try? fileManager.removeItem(at: stagingURL)
    }

    private func download(
        asset: VMAssetRemoteAsset,
        destinationURL: URL,
        progress: (Double) -> Void
    ) async throws {
        do {
            var request = URLRequest(url: asset.downloadURL)
            request.timeoutInterval = 120
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("ThruRNDIS", forHTTPHeaderField: "User-Agent")

            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw VMAssetDownloadError.invalidResponse(asset.name)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw VMAssetDownloadError.httpStatus(response.statusCode, asset.name)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var writtenBytes: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    writtenBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if asset.size >= 0, writtenBytes > asset.size {
                        throw VMAssetDownloadError.sizeMismatch(
                            name: asset.name,
                            expected: asset.size,
                            actual: writtenBytes
                        )
                    }
                    if asset.size > 0 {
                        progress(min(Double(writtenBytes) / Double(asset.size), 1))
                    }
                }
            }
            if !buffer.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                writtenBytes += Int64(buffer.count)
            }

            try Task.checkCancellation()
            if asset.size >= 0, writtenBytes != asset.size {
                throw VMAssetDownloadError.sizeMismatch(
                    name: asset.name,
                    expected: asset.size,
                    actual: writtenBytes
                )
            }
            progress(1)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }
}
