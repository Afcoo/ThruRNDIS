/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct VMAssetStorageLayout {
    let rootDirectoryURL: URL
    let stagingDirectoryURL: URL
    let releasesDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectoryURL: URL? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        let applicationSupportURL = applicationSupportDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let applicationDirectoryURL = applicationSupportURL.appendingPathComponent(
            bundleIdentifier ?? ProcessInfo.processInfo.processName,
            isDirectory: true
        )
        rootDirectoryURL = applicationDirectoryURL.appendingPathComponent("VMAssets", isDirectory: true)
        stagingDirectoryURL = rootDirectoryURL.appendingPathComponent(".staging", isDirectory: true)
        releasesDirectoryURL = rootDirectoryURL.appendingPathComponent("Releases", isDirectory: true)
    }

    func stagingURL(for operationID: UUID) -> URL {
        stagingDirectoryURL.appendingPathComponent(operationID.uuidString, isDirectory: true)
    }

    func releaseURL(releaseID: Int64, archiveAssetID: Int64) -> URL {
        releasesDirectoryURL.appendingPathComponent(
            "\(releaseID)-\(archiveAssetID)",
            isDirectory: true
        )
    }
}
