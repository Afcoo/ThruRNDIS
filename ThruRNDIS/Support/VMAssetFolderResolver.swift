/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct VMAssetFolderContents: Equatable {
    let kernelURL: URL
    let initialRamdiskURL: URL
}

enum VMAssetFolderError: LocalizedError {
    case notDirectory(URL)
    case missingKernel(URL)
    case missingInitramfs(URL)
    case notRegularFile(label: String, url: URL)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let url):
            return "Selected VM asset path is not a folder: \(url.path)"
        case .missingKernel(let url):
            return "No Image-* kernel was found in the VM asset folder: \(url.path)"
        case .missingInitramfs(let url):
            return "No initramfs-thrurndis-* ramdisk was found in the VM asset folder: \(url.path)"
        case .notRegularFile(let label, let url):
            return "The selected \(label) is not a readable regular file: \(url.path)"
        }
    }
}

struct VMAssetFolderResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(_ directoryURL: URL) throws -> VMAssetFolderContents {
        let directory = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VMAssetFolderError.notDirectory(directory)
        }

        let searchDirectories = [
            directory,
            directory.appendingPathComponent("boot", isDirectory: true),
        ]

        guard let kernelURL = firstAsset(
            in: searchDirectories,
            preferredNames: ["Image-lts", "Image-virt"],
            prefix: "Image-"
        ) else {
            throw VMAssetFolderError.missingKernel(directory)
        }

        guard let initialRamdiskURL = firstAsset(
            in: searchDirectories,
            preferredNames: ["initramfs-thrurndis-lts", "initramfs-thrurndis-virt"],
            prefix: "initramfs-thrurndis-"
        ) else {
            throw VMAssetFolderError.missingInitramfs(directory)
        }

        return VMAssetFolderContents(
            kernelURL: kernelURL,
            initialRamdiskURL: initialRamdiskURL
        )
    }

    func validateRegularFile(_ url: URL, label: String) throws {
        guard isRegularFile(url.standardizedFileURL) else {
            throw VMAssetFolderError.notRegularFile(label: label, url: url.standardizedFileURL)
        }
    }

    func isRegularFile(_ url: URL) -> Bool {
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  fileManager.isReadableFile(atPath: url.path) else {
                return false
            }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    func folderURL(containing url: URL) -> URL {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return directory.lastPathComponent == "boot"
            ? directory.deletingLastPathComponent()
            : directory
    }

    private func firstAsset(
        in directories: [URL],
        preferredNames: [String],
        prefix: String
    ) -> URL? {
        for directory in directories {
            for name in preferredNames {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                if isRegularFile(url) {
                    return url
                }
            }
        }

        for directory in directories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            if let match = urls
                .filter({ $0.lastPathComponent.hasPrefix(prefix) && isRegularFile($0) })
                .sorted(by: {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                })
                .first {
                return match
            }
        }

        return nil
    }
}
