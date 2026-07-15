/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct VMAssetSelectionStore: VMAssetSelectionStoring {
    private let defaults: UserDefaults
    private let resolver: VMAssetFolderResolver

    init(
        defaults: UserDefaults = .standard,
        resolver: VMAssetFolderResolver = VMAssetFolderResolver()
    ) {
        self.defaults = defaults
        self.resolver = resolver
    }

    func restoreSelection() throws -> VMAssetSelection? {
        let restoredFolderURL = restoredURL(forKey: DefaultsKey.folderURLPath)
        let restoredKernelURL = migratedLegacyInitramfsIfNeeded(
            restoredURL(forKey: DefaultsKey.kernelURLPath)
        )
        let restoredInitialRamdiskURL = migratedLegacyInitramfsIfNeeded(
            restoredURL(forKey: DefaultsKey.initialRamdiskURLPath)
        )

        guard let folderURL = restoredFolderURL
            ?? restoredInitialRamdiskURL.map(resolver.folderURL(containing:))
            ?? restoredKernelURL.map(resolver.folderURL(containing:)) else {
            return nil
        }

        let contents: VMAssetFolderContents
        do {
            contents = try resolver.resolve(folderURL)
        } catch {
            guard let restoredKernelURL,
                  let restoredInitialRamdiskURL else {
                throw error
            }
            try resolver.validateRegularFile(
                restoredKernelURL,
                label: String(localized: "Linux kernel")
            )
            try resolver.validateRegularFile(
                restoredInitialRamdiskURL,
                label: String(localized: "initial ramdisk")
            )
            contents = VMAssetFolderContents(
                kernelURL: restoredKernelURL,
                initialRamdiskURL: restoredInitialRamdiskURL
            )
        }

        let explicitKernelOverride = restoredURL(forKey: DefaultsKey.kernelOverrideURLPath)
        let explicitInitialRamdiskOverride = restoredURL(forKey: DefaultsKey.initialRamdiskOverrideURLPath)
        let kernelOverrideURL = explicitKernelOverride
            ?? inferredOverride(restoredKernelURL, baseURL: contents.kernelURL)
        let initialRamdiskOverrideURL = explicitInitialRamdiskOverride
            ?? inferredOverride(restoredInitialRamdiskURL, baseURL: contents.initialRamdiskURL)

        if let kernelOverrideURL {
            try resolver.validateRegularFile(
                kernelOverrideURL,
                label: String(localized: "Linux kernel override")
            )
        }
        if let initialRamdiskOverrideURL {
            try resolver.validateRegularFile(
                initialRamdiskOverrideURL,
                label: String(localized: "initial ramdisk override")
            )
        }

        let managedRelease = restoredManagedRelease(folderURL: folderURL)
        let selection = VMAssetSelection(
            source: managedRelease == nil ? .manual : .managed,
            folderURL: folderURL.standardizedFileURL,
            kernelURL: contents.kernelURL,
            initialRamdiskURL: contents.initialRamdiskURL,
            kernelOverrideURL: kernelOverrideURL,
            initialRamdiskOverrideURL: initialRamdiskOverrideURL,
            managedRelease: managedRelease
        )
        persist(selection)
        return selection
    }

    func selectManualFolder(_ directoryURL: URL) throws -> VMAssetSelection {
        let folderURL = directoryURL.standardizedFileURL
        let contents = try resolver.resolve(folderURL)
        let selection = VMAssetSelection(
            source: .manual,
            folderURL: folderURL,
            kernelURL: contents.kernelURL,
            initialRamdiskURL: contents.initialRamdiskURL,
            kernelOverrideURL: nil,
            initialRamdiskOverrideURL: nil,
            managedRelease: nil
        )
        persist(selection)
        return selection
    }

    func selectManagedRelease(_ release: InstalledVMAssetRelease) throws -> VMAssetSelection {
        let contents = try resolver.resolve(release.assetFolderURL)
        let selection = VMAssetSelection(
            source: .managed,
            folderURL: release.assetFolderURL.standardizedFileURL,
            kernelURL: contents.kernelURL,
            initialRamdiskURL: contents.initialRamdiskURL,
            kernelOverrideURL: nil,
            initialRamdiskOverrideURL: nil,
            managedRelease: release
        )
        persist(selection)
        return selection
    }

    func setKernelOverride(_ url: URL?, for selection: VMAssetSelection) throws -> VMAssetSelection {
        if let url {
            try resolver.validateRegularFile(
                url,
                label: String(localized: "Linux kernel override")
            )
        }
        let updated = VMAssetSelection(
            source: selection.source,
            folderURL: selection.folderURL,
            kernelURL: selection.kernelURL,
            initialRamdiskURL: selection.initialRamdiskURL,
            kernelOverrideURL: url?.standardizedFileURL,
            initialRamdiskOverrideURL: selection.initialRamdiskOverrideURL,
            managedRelease: selection.managedRelease
        )
        persist(updated)
        return updated
    }

    func setInitialRamdiskOverride(_ url: URL?, for selection: VMAssetSelection) throws -> VMAssetSelection {
        if let url {
            try resolver.validateRegularFile(
                url,
                label: String(localized: "initial ramdisk override")
            )
        }
        let updated = VMAssetSelection(
            source: selection.source,
            folderURL: selection.folderURL,
            kernelURL: selection.kernelURL,
            initialRamdiskURL: selection.initialRamdiskURL,
            kernelOverrideURL: selection.kernelOverrideURL,
            initialRamdiskOverrideURL: url?.standardizedFileURL,
            managedRelease: selection.managedRelease
        )
        persist(updated)
        return updated
    }

    func validate(_ selection: VMAssetSelection) throws -> VMAssetBootAssets {
        let kernelURL = selection.effectiveKernelURL.standardizedFileURL
        let initialRamdiskURL = selection.effectiveInitialRamdiskURL.standardizedFileURL
        try resolver.validateRegularFile(
            kernelURL,
            label: String(localized: "Linux kernel")
        )
        try resolver.validateRegularFile(
            initialRamdiskURL,
            label: String(localized: "initial ramdisk")
        )
        return VMAssetBootAssets(
            kernelURL: kernelURL,
            initialRamdiskURL: initialRamdiskURL
        )
    }

    func clearSelection() {
        for key in DefaultsKey.allSelectionKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private func persist(_ selection: VMAssetSelection) {
        defaults.set(selection.source.rawValue, forKey: DefaultsKey.selectionSource)
        defaults.set(selection.folderURL.standardizedFileURL.path, forKey: DefaultsKey.folderURLPath)
        defaults.set(selection.effectiveKernelURL.standardizedFileURL.path, forKey: DefaultsKey.kernelURLPath)
        defaults.set(
            selection.effectiveInitialRamdiskURL.standardizedFileURL.path,
            forKey: DefaultsKey.initialRamdiskURLPath
        )
        persist(selection.kernelOverrideURL, forKey: DefaultsKey.kernelOverrideURLPath)
        persist(selection.initialRamdiskOverrideURL, forKey: DefaultsKey.initialRamdiskOverrideURLPath)
        persist(
            selection.managedRelease?.releaseDirectoryURL,
            forKey: DefaultsKey.managedReleaseDirectoryURLPath
        )
    }

    private func restoredManagedRelease(folderURL: URL) -> InstalledVMAssetRelease? {
        guard defaults.string(forKey: DefaultsKey.selectionSource) == VMAssetSelectionSource.managed.rawValue,
              let releaseDirectoryURL = restoredURL(forKey: DefaultsKey.managedReleaseDirectoryURLPath) else {
            return nil
        }

        let metadataURL = releaseDirectoryURL.appendingPathComponent("install.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder.vmAssetMetadata.decode(VMAssetInstallMetadata.self, from: data),
              metadata.isValid(forManagedReleaseDirectory: releaseDirectoryURL) else {
            return nil
        }

        let release = InstalledVMAssetRelease(
            metadata: metadata,
            releaseDirectoryURL: releaseDirectoryURL.standardizedFileURL
        )
        guard release.assetFolderURL.standardizedFileURL == folderURL.standardizedFileURL else {
            return nil
        }
        return release
    }

    private func inferredOverride(_ restoredURL: URL?, baseURL: URL) -> URL? {
        guard let restoredURL,
              restoredURL.standardizedFileURL != baseURL.standardizedFileURL else {
            return nil
        }
        return restoredURL.standardizedFileURL
    }

    private func restoredURL(forKey key: String) -> URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else {
            return nil
        }
        return migratedLegacyAssetURL(from: URL(fileURLWithPath: path))
    }

    private func persist(_ url: URL?, forKey key: String) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func migratedLegacyInitramfsIfNeeded(_ url: URL?) -> URL? {
        guard let url,
              url.lastPathComponent.hasPrefix("initramfs-tui-") else {
            return url
        }

        let replacementName = url.lastPathComponent.replacingOccurrences(
            of: "initramfs-tui-",
            with: "initramfs-thrurndis-",
            options: [.anchored]
        )
        let replacementURL = url.deletingLastPathComponent().appendingPathComponent(replacementName)
        return resolver.isRegularFile(replacementURL) ? replacementURL : url
    }

    private func migratedLegacyAssetURL(from url: URL) -> URL {
        let legacySegment = "/script/VMAssets/"
        let migratedSegment = "/script/assets/"
        let path = url.standardizedFileURL.path

        if let range = path.range(of: legacySegment) {
            let migratedPath = path.replacingCharacters(in: range, with: migratedSegment)
            if FileManager.default.fileExists(atPath: migratedPath) {
                return URL(fileURLWithPath: migratedPath)
            }
        }

        guard let assetRange = path.range(of: migratedSegment) else {
            return url.standardizedFileURL
        }
        let suffix = path[assetRange.upperBound...]
        let components = suffix.split(separator: "/")
        guard components.count >= 3,
              components[1] == "boot",
              let fileName = components.last else {
            return url.standardizedFileURL
        }
        let flattenedPath = String(path[..<assetRange.upperBound]) + String(fileName)
        return FileManager.default.fileExists(atPath: flattenedPath)
            ? URL(fileURLWithPath: flattenedPath)
            : url.standardizedFileURL
    }

    private enum DefaultsKey {
        static let folderURLPath = "VMAssets.folderURLPath"
        static let kernelURLPath = "VMAssets.kernelURLPath"
        static let initialRamdiskURLPath = "VMAssets.initialRamdiskURLPath"
        static let selectionSource = "VMAssets.selectionSource"
        static let kernelOverrideURLPath = "VMAssets.kernelOverrideURLPath"
        static let initialRamdiskOverrideURLPath = "VMAssets.initialRamdiskOverrideURLPath"
        static let managedReleaseDirectoryURLPath = "VMAssets.managedReleaseDirectoryURLPath"

        static let allSelectionKeys = [
            folderURLPath,
            kernelURLPath,
            initialRamdiskURLPath,
            selectionSource,
            kernelOverrideURLPath,
            initialRamdiskOverrideURLPath,
            managedReleaseDirectoryURLPath,
        ]
    }
}

extension JSONDecoder {
    static var vmAssetMetadata: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var vmAssetMetadata: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
