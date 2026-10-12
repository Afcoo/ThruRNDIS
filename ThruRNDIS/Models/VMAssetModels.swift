/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct VMAssetReleaseDescriptor: Decodable, Equatable {
    static let archiveName = "vm_assets.zip"

    let schemaVersion: Int
    let assetVersion: Int
    let tagName: String
    let size: Int64
    let sha256: String

    var archiveURL: URL {
        URL(string: "https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases/download")!
            .appendingPathComponent(tagName)
            .appendingPathComponent(Self.archiveName)
    }
}

struct DownloadedVMAssetPackage {
    let release: VMAssetReleaseDescriptor
    let stagingDirectoryURL: URL

    var archiveURL: URL {
        stagingDirectoryURL.appendingPathComponent(VMAssetReleaseDescriptor.archiveName)
    }
}

struct VMAssetDownloadProgress: Equatable, Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64
}

struct VMAssetInstallMetadata: Codable, Equatable {
    let tagName: String
    let archiveSHA256: String
    let installedAt: Date
    // Read existing numeric-ID installations without moving or redownloading them.
    let releaseID: Int64?
    let archiveAssetID: Int64?

    func isValid(forManagedReleaseDirectory releaseDirectoryURL: URL) -> Bool {
        let directoryName: String
        switch (releaseID, archiveAssetID) {
        case let (.some(release), .some(archive)):
            directoryName = "\(release)-\(archive)"
        case (.none, .none):
            directoryName = archiveSHA256
        default:
            return false
        }
        return releaseDirectoryURL.standardizedFileURL.lastPathComponent == directoryName
            && archiveSHA256.utf8.count == 64
            && archiveSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct InstalledVMAssetRelease: Equatable {
    let metadata: VMAssetInstallMetadata
    let releaseDirectoryURL: URL

    var assetFolderURL: URL {
        releaseDirectoryURL.appendingPathComponent("vm_assets", isDirectory: true)
    }

    var displayName: String {
        if metadata.tagName.isEmpty, let releaseID = metadata.releaseID {
            return String(localized: "Release \(releaseID)")
        }
        return metadata.tagName
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
            return String(localized: "Checking latest version…")
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
