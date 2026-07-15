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
}

struct DownloadedVMAssetPackage {
    let release: VMAssetReleaseDescriptor
    let stagingDirectoryURL: URL
    let archiveURL: URL
    let checksumsURL: URL
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
    case downloading(progress: Double)
    case verifying
    case extracting
    case activating
    case ready(message: String)
    case failed(message: String)

    var progress: Double? {
        guard case .downloading(let progress) = self else {
            return nil
        }
        return min(max(progress, 0), 1)
    }

    var statusText: String {
        switch self {
        case .idle:
            return String(localized: "VM assets are not selected.")
        case .checking:
            return String(localized: "Checking the latest VM asset release…")
        case .downloading(let progress):
            return String(localized: "Downloading VM assets… \(Int(progress * 100))%")
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
}

enum VMAssetInstallStage {
    case verifying
    case extracting
}

protocol VMAssetReleaseServing {
    func fetchLatestRelease() async throws -> VMAssetReleaseDescriptor
}

protocol VMAssetDownloading {
    func download(
        release: VMAssetReleaseDescriptor,
        operationID: UUID,
        progress: @escaping (Double) -> Void
    ) async throws -> DownloadedVMAssetPackage
    func discardStagingData(for operationID: UUID)
}

protocol VMAssetInstalling {
    func installedRelease(matching release: VMAssetReleaseDescriptor) throws -> InstalledVMAssetRelease?
    func installedReleases() throws -> [InstalledVMAssetRelease]
    func install(
        package: DownloadedVMAssetPackage,
        progress: @escaping (VMAssetInstallStage) -> Void
    ) async throws -> InstalledVMAssetRelease
    func removeInstalledRelease(_ release: InstalledVMAssetRelease) throws
    func pruneInstalledReleases(
        keeping release: InstalledVMAssetRelease,
        preserving protectedDirectoryURL: URL?
    ) throws
}

protocol VMAssetSelectionStoring {
    func restoreSelection() throws -> VMAssetSelection?
    func selectManualFolder(_ directoryURL: URL) throws -> VMAssetSelection
    func selectManagedRelease(_ release: InstalledVMAssetRelease) throws -> VMAssetSelection
    func setKernelOverride(_ url: URL?, for selection: VMAssetSelection) throws -> VMAssetSelection
    func setInitialRamdiskOverride(_ url: URL?, for selection: VMAssetSelection) throws -> VMAssetSelection
    func validate(_ selection: VMAssetSelection) throws -> VMAssetBootAssets
    func clearSelection()
}

@MainActor
protocol VMAssetProviding: AnyObject {
    var hasConfiguredAssets: Bool { get }
    var isBusy: Bool { get }
    func validatedBootAssets() throws -> VMAssetBootAssets
}
