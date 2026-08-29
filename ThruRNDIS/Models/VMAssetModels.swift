/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct VMAssetRemoteAsset: Equatable {
    let id: Int64
    let name: String
    let downloadURL: URL
    let size: Int64
    let sha256Digest: String?
}

struct VMAssetReleaseDescriptor: Equatable {
    let id: Int64
    let tagName: String
    let archive: VMAssetRemoteAsset
    let checksums: VMAssetRemoteAsset

    var totalDownloadBytes: Int64 {
        let archiveBytes = max(archive.size, 0)
        let checksumsBytes = max(checksums.size, 0)
        let (totalBytes, overflow) = archiveBytes.addingReportingOverflow(checksumsBytes)
        return overflow ? Int64.max : max(totalBytes, 1)
    }
}

struct DownloadedVMAssetPackage {
    let release: VMAssetReleaseDescriptor
    let stagingDirectoryURL: URL
    let archiveURL: URL
    let checksumsURL: URL
}

struct VMAssetDownloadProgress: Equatable, Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64
}

struct VMAssetInstallMetadata: Codable, Equatable {
    let releaseID: Int64
    let tagName: String
    let archiveAssetID: Int64
    let archiveSHA256: String
    let installedAt: Date

    func isValid(forManagedReleaseDirectory releaseDirectoryURL: URL) -> Bool {
        let expectedDirectoryName = "\(releaseID)-\(archiveAssetID)"
        return releaseDirectoryURL.standardizedFileURL.lastPathComponent == expectedDirectoryName
            && archiveSHA256.utf8.count == 64
            && archiveSHA256.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

struct InstalledVMAssetRelease: Equatable {
    let metadata: VMAssetInstallMetadata
    let releaseDirectoryURL: URL

    var assetFolderURL: URL {
        releaseDirectoryURL.appendingPathComponent("vm_assets", isDirectory: true)
    }

    var displayName: String {
        metadata.tagName.isEmpty
            ? String(localized: "Release \(metadata.releaseID)")
            : metadata.tagName
    }
}

enum VMAssetSelectionSource: String, Equatable {
    case managed
    case manual
}

struct VMAssetSelection: Equatable {
    let source: VMAssetSelectionSource
    let folderURL: URL
    let kernelURL: URL
    let initialRamdiskURL: URL
    let kernelOverrideURL: URL?
    let initialRamdiskOverrideURL: URL?
    let managedRelease: InstalledVMAssetRelease?

    var effectiveKernelURL: URL {
        kernelOverrideURL ?? kernelURL
    }

    var effectiveInitialRamdiskURL: URL {
        initialRamdiskOverrideURL ?? initialRamdiskURL
    }
}

struct VMAssetBootAssets: Equatable {
    let kernelURL: URL
    let initialRamdiskURL: URL
}

enum VMAssetInstallState: Equatable {
    case idle
    case checking
    case downloading(progress: VMAssetDownloadProgress)
    case verifying
    case extracting
    case activating
    case ready(message: String)
    case failed(message: String)

    var statusText: String {
        switch self {
        case .idle:
            return String(localized: "VM assets are not selected.")
        case .checking:
            return String(localized: "Checking the latest VM asset release…")
        case .downloading(let progress):
            let status = String(localized: "Downloading…")
            let downloadedMegabytes = Self.megabytesText(for: progress.downloadedBytes)
            let totalMegabytes = Self.megabytesText(for: progress.totalBytes)
            return "\(status) (\(downloadedMegabytes)MB/\(totalMegabytes)MB)"
        case .verifying:
            return String(localized: "Verifying the downloaded VM assets…")
        case .extracting:
            return String(localized: "Installing the downloaded VM assets…")
        case .activating:
            return String(localized: "Activating the installed VM assets…")
        case .ready(let message), .failed(let message):
            return message
        }
    }

    private static func megabytesText(for byteCount: Int64) -> String {
        let megabytes = Double(max(byteCount, 0)) / 1_000_000
        return megabytes.formatted(.number.precision(.fractionLength(1)))
    }
}

enum VMAssetInstallStage {
    case verifying
    case extracting
}

@MainActor
protocol VMAssetProviding: AnyObject {
    var hasConfiguredAssets: Bool { get }
    var isBusy: Bool { get }
    func validatedBootAssets() throws -> VMAssetBootAssets
}
