/*
Copyright (C) 2026 Afcoo.
*/

import CryptoKit
import Foundation

enum VMAssetInstallError: LocalizedError {
    case invalidChecksums
    case missingChecksum(String)
    case duplicateChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchiveEntry(String)
    case duplicateArchiveEntry(String)
    case invalidArchiveRoot(String)
    case symbolicLink(String)
    case commandFailed(command: String, output: String)
    case invalidInstalledRelease(URL)
    case unsafeManagedReleasePath(URL)

    var errorDescription: String? {
        switch self {
        case .invalidChecksums:
            return "SHA256SUMS is malformed."
        case .missingChecksum(let name):
            return "SHA256SUMS does not contain an entry for \(name)."
        case .duplicateChecksum(let name):
            return "SHA256SUMS contains more than one entry for \(name)."
        case .checksumMismatch(let expected, let actual):
            return "The VM asset checksum does not match (expected \(expected), calculated \(actual))."
        case .unsafeArchiveEntry(let name):
            return "The VM asset archive contains an unsafe path: \(name)"
        case .duplicateArchiveEntry(let name):
            return "The VM asset archive contains a duplicate path: \(name)"
        case .invalidArchiveRoot(let name):
            return "The VM asset archive contains an unexpected top-level path: \(name)"
        case .symbolicLink(let name):
            return "The VM asset archive contains a symbolic link: \(name)"
        case .commandFailed(let command, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(command) failed while installing VM assets."
                : "\(command) failed while installing VM assets: \(detail)"
        case .invalidInstalledRelease(let url):
            return "The installed VM asset release is incomplete or damaged: \(url.path)"
        case .unsafeManagedReleasePath(let url):
            return "Refusing to modify a VM asset path outside managed storage: \(url.path)"
        }
    }
}

final class VMAssetInstallService: VMAssetInstalling {
    private let fileManager: FileManager
    private let layout: VMAssetStorageLayout
    private let resolver: VMAssetFolderResolver
    private let processRunner: VMAssetProcessRunning
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        layout: VMAssetStorageLayout = VMAssetStorageLayout(),
        resolver: VMAssetFolderResolver = VMAssetFolderResolver(),
        processRunner: VMAssetProcessRunning = VMAssetProcessRunner(),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.layout = layout
        self.resolver = resolver
        self.processRunner = processRunner
        self.now = now
    }

    func installedRelease(matching release: VMAssetReleaseDescriptor) throws -> InstalledVMAssetRelease? {
        let releaseURL = layout.releaseURL(
            releaseID: release.id,
            archiveAssetID: release.archive.id
        )
        guard fileManager.fileExists(atPath: releaseURL.path) else {
            return nil
        }
        guard let installed = try? loadInstalledRelease(at: releaseURL) else {
            return nil
        }
        guard let expectedArchiveSHA256 = release.archive.sha256Digest,
              installed.metadata.releaseID == release.id,
              installed.metadata.archiveAssetID == release.archive.id,
              installed.metadata.tagName == release.tagName,
              installed.metadata.archiveSHA256 == expectedArchiveSHA256 else {
            return nil
        }
        return installed
    }

    func installedReleases() throws -> [InstalledVMAssetRelease] {
        guard fileManager.fileExists(atPath: layout.releasesDirectoryURL.path) else {
            return []
        }
        let urls = try fileManager.contentsOfDirectory(
            at: layout.releasesDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { try? loadInstalledRelease(at: $0) }
            .sorted { $0.metadata.installedAt > $1.metadata.installedAt }
    }

    func install(
        package: DownloadedVMAssetPackage,
        progress: @escaping (VMAssetInstallStage) -> Void
    ) async throws -> InstalledVMAssetRelease {
        let task = Task.detached(priority: .utility) { [self] in
            try await performInstall(package: package, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func removeInstalledRelease(_ release: InstalledVMAssetRelease) throws {
        try validateManagedReleasePath(release.releaseDirectoryURL)
        guard fileManager.fileExists(atPath: release.releaseDirectoryURL.path) else {
            return
        }
        try fileManager.removeItem(at: release.releaseDirectoryURL)
    }

    func pruneInstalledReleases(
        keeping release: InstalledVMAssetRelease,
        preserving protectedDirectoryURL: URL?
    ) throws {
        try validateManagedReleasePath(release.releaseDirectoryURL)
        guard fileManager.fileExists(atPath: layout.releasesDirectoryURL.path) else {
            return
        }
        let urls = try fileManager.contentsOfDirectory(
            at: layout.releasesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in urls where url.standardizedFileURL != release.releaseDirectoryURL.standardizedFileURL {
            try validateManagedReleasePath(url)
            if let protectedDirectoryURL,
               containsOrEquals(url, protectedDirectoryURL) {
                continue
            }
            try fileManager.removeItem(at: url)
        }
    }

    private func performInstall(
        package: DownloadedVMAssetPackage,
        progress: @escaping (VMAssetInstallStage) -> Void
    ) async throws -> InstalledVMAssetRelease {
        defer {
            try? fileManager.removeItem(at: package.stagingDirectoryURL)
        }

        try Task.checkCancellation()
        progress(.verifying)

        let expectedHash = try expectedArchiveHash(
            checksumsURL: package.checksumsURL,
            archiveName: package.release.archive.name
        )
        let actualHash = try calculateSHA256(package.archiveURL)
        guard expectedHash == actualHash else {
            throw VMAssetInstallError.checksumMismatch(
                expected: expectedHash,
                actual: actualHash
            )
        }
        if let releaseDigest = package.release.archive.sha256Digest,
           releaseDigest != actualHash {
            throw VMAssetInstallError.checksumMismatch(
                expected: releaseDigest,
                actual: actualHash
            )
        }

        try await validateArchive(package.archiveURL)
        try Task.checkCancellation()
        progress(.extracting)

        let extractionURL = package.stagingDirectoryURL.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: extractionURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try await runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", package.archiveURL.path, extractionURL.path],
            displayName: "ditto"
        )

        try Task.checkCancellation()
        let extractedAssetFolderURL = extractionURL.appendingPathComponent(
            "vm_assets",
            isDirectory: true
        )
        try rejectSymbolicLinks(in: extractedAssetFolderURL)
        try validateRequiredReleaseFiles(in: extractedAssetFolderURL)

        let metadata = VMAssetInstallMetadata(
            releaseID: package.release.id,
            tagName: package.release.tagName,
            archiveAssetID: package.release.archive.id,
            archiveSHA256: actualHash,
            installedAt: now()
        )
        try Task.checkCancellation()
        return try promote(
            extractedAssetFolderURL: extractedAssetFolderURL,
            metadata: metadata
        )
    }

    private func expectedArchiveHash(
        checksumsURL: URL,
        archiveName: String
    ) throws -> String {
        let text = try String(contentsOf: checksumsURL, encoding: .utf8)
        var matches: [String] = []

        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }
            let fields = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard fields.count == 2 else {
                throw VMAssetInstallError.invalidChecksums
            }
            let hash = String(fields[0]).lowercased()
            var name = String(fields[1]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") {
                name.removeFirst()
            }
            guard hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit }) else {
                throw VMAssetInstallError.invalidChecksums
            }
            if name == archiveName || name == "./\(archiveName)" {
                matches.append(hash)
            }
        }

        guard !matches.isEmpty else {
            throw VMAssetInstallError.missingChecksum(archiveName)
        }
        guard matches.count == 1, let hash = matches.first else {
            throw VMAssetInstallError.duplicateChecksum(archiveName)
        }
        return hash
    }

    private func calculateSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateArchive(_ archiveURL: URL) async throws {
        let namesResult = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-1", archiveURL.path]
        )
        guard namesResult.terminationStatus == 0 else {
            throw VMAssetInstallError.commandFailed(
                command: "zipinfo",
                output: namesResult.combinedOutput
            )
        }

        var seenNames: Set<String> = []
        let names = namesResult.standardOutput.split(whereSeparator: \Character.isNewline)
        guard !names.isEmpty else {
            throw VMAssetInstallError.invalidArchiveRoot("empty archive")
        }
        for rawName in names {
            try Task.checkCancellation()
            let name = String(rawName)
            guard !name.contains("\\"),
                  !name.hasPrefix("/"),
                  !name.hasPrefix("~"),
                  !name.contains("\0") else {
                throw VMAssetInstallError.unsafeArchiveEntry(name)
            }

            var components = name.split(separator: "/", omittingEmptySubsequences: false)
            if components.last?.isEmpty == true {
                components.removeLast()
            }
            guard !components.isEmpty,
                  components.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":")
                  }) else {
                throw VMAssetInstallError.unsafeArchiveEntry(name)
            }

            let normalizedName = components.joined(separator: "/")
            let collisionKey = normalizedName
                .precomposedStringWithCanonicalMapping
                .folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            guard seenNames.insert(collisionKey).inserted else {
                throw VMAssetInstallError.duplicateArchiveEntry(name)
            }
            guard normalizedName == "vm_assets"
                || normalizedName.hasPrefix("vm_assets/") else {
                throw VMAssetInstallError.invalidArchiveRoot(name)
            }
        }

        let detailsResult = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-l", archiveURL.path]
        )
        guard detailsResult.terminationStatus == 0 else {
            throw VMAssetInstallError.commandFailed(
                command: "zipinfo",
                output: detailsResult.combinedOutput
            )
        }
        for line in detailsResult.standardOutput.split(whereSeparator: \Character.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("l"), let name = trimmed.split(separator: " ").last {
                throw VMAssetInstallError.symbolicLink(String(name))
            }
        }
    }

    private func validateRequiredReleaseFiles(in folderURL: URL) throws {
        _ = try resolver.resolve(folderURL)
        try resolver.validateRegularFile(
            folderURL.appendingPathComponent("Image-lts"),
            label: "Image-lts"
        )
        try resolver.validateRegularFile(
            folderURL.appendingPathComponent("initramfs-thrurndis-lts"),
            label: "initramfs-thrurndis-lts"
        )
    }

    private func rejectSymbolicLinks(in folderURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw VMAssetInstallError.invalidInstalledRelease(folderURL)
        }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw VMAssetInstallError.symbolicLink(url.lastPathComponent)
            }
        }
    }

    private func promote(
        extractedAssetFolderURL: URL,
        metadata: VMAssetInstallMetadata
    ) throws -> InstalledVMAssetRelease {
        try Task.checkCancellation()
        try fileManager.createDirectory(
            at: layout.releasesDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let destinationURL = layout.releaseURL(
            releaseID: metadata.releaseID,
            archiveAssetID: metadata.archiveAssetID
        )
        if let existing = try? loadInstalledRelease(at: destinationURL),
           existing.metadata.releaseID == metadata.releaseID,
           existing.metadata.archiveAssetID == metadata.archiveAssetID,
           existing.metadata.tagName == metadata.tagName,
           existing.metadata.archiveSHA256 == metadata.archiveSHA256 {
            try Task.checkCancellation()
            return existing
        }

        let incomingURL = layout.releasesDirectoryURL.appendingPathComponent(
            ".incoming-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupURL = layout.releasesDirectoryURL.appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        var promotionCommitted = false
        defer {
            try? fileManager.removeItem(at: incomingURL)
            if promotionCommitted {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        try fileManager.createDirectory(at: incomingURL, withIntermediateDirectories: false)
        try fileManager.moveItem(
            at: extractedAssetFolderURL,
            to: incomingURL.appendingPathComponent("vm_assets", isDirectory: true)
        )
        let metadataData = try JSONEncoder.vmAssetMetadata.encode(metadata)
        try metadataData.write(
            to: incomingURL.appendingPathComponent("install.json"),
            options: .atomic
        )
        try Task.checkCancellation()

        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
        if destinationExists {
            try fileManager.moveItem(at: destinationURL, to: backupURL)
        }
        do {
            try Task.checkCancellation()
            try fileManager.moveItem(at: incomingURL, to: destinationURL)
            try Task.checkCancellation()
            let installed = try loadInstalledRelease(at: destinationURL)
            try Task.checkCancellation()
            promotionCommitted = true
            return installed
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            if destinationExists,
               !fileManager.fileExists(atPath: destinationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            throw error
        }
    }

    private func loadInstalledRelease(at releaseURL: URL) throws -> InstalledVMAssetRelease {
        try validateManagedReleasePath(releaseURL)
        let metadataURL = releaseURL.appendingPathComponent("install.json", isDirectory: false)
        let data = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder.vmAssetMetadata.decode(VMAssetInstallMetadata.self, from: data)
        guard metadata.isValid(forManagedReleaseDirectory: releaseURL) else {
            throw VMAssetInstallError.invalidInstalledRelease(releaseURL)
        }
        let release = InstalledVMAssetRelease(
            metadata: metadata,
            releaseDirectoryURL: releaseURL.standardizedFileURL
        )
        do {
            try validateRequiredReleaseFiles(in: release.assetFolderURL)
        } catch {
            throw VMAssetInstallError.invalidInstalledRelease(releaseURL)
        }
        return release
    }

    private func validateManagedReleasePath(_ url: URL) throws {
        let parentURL = url.standardizedFileURL.deletingLastPathComponent()
        guard parentURL == layout.releasesDirectoryURL.standardizedFileURL else {
            throw VMAssetInstallError.unsafeManagedReleasePath(url)
        }
    }

    private func containsOrEquals(_ directoryURL: URL, _ protectedURL: URL) -> Bool {
        let directoryPath = directoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let protectedPath = protectedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return protectedPath == directoryPath
            || protectedPath.hasPrefix(directoryPath + "/")
    }

    private func runCommand(
        executableURL: URL,
        arguments: [String],
        displayName: String
    ) async throws {
        let result = try await processRunner.run(
            executableURL: executableURL,
            arguments: arguments
        )
        guard result.terminationStatus == 0 else {
            throw VMAssetInstallError.commandFailed(
                command: displayName,
                output: result.combinedOutput
            )
        }
    }
}

struct VMAssetProcessResult {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

protocol VMAssetProcessRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> VMAssetProcessResult
}

final class VMAssetProcessRunner: VMAssetProcessRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> VMAssetProcessResult {
        let execution = VMAssetProcessExecution()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await execution.run(executableURL: executableURL, arguments: arguments)
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class VMAssetProcessExecution {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(executableURL: URL, arguments: [String]) async throws -> VMAssetProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutputPipe = Pipe()
            let standardErrorPipe = Pipe()
            let standardOutput = VMAssetPipeCollector(handle: standardOutputPipe.fileHandleForReading)
            let standardError = VMAssetPipeCollector(handle: standardErrorPipe.fileHandleForReading)

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = standardOutputPipe
            process.standardError = standardErrorPipe

            lock.lock()
            guard !cancelled else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.process = process
            lock.unlock()

            process.terminationHandler = { [weak self] process in
                standardOutput.finish()
                standardError.finish()
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.lock.lock()
                let wasCancelled = self.cancelled
                self.process = nil
                self.lock.unlock()

                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: VMAssetProcessResult(
                        terminationStatus: process.terminationStatus,
                        standardOutput: standardOutput.text,
                        standardError: standardError.text
                    ))
                }
            }

            do {
                standardOutput.start()
                standardError.start()
                try process.run()
                lock.lock()
                let shouldCancel = cancelled
                lock.unlock()
                if shouldCancel, process.isRunning {
                    process.terminate()
                }
            } catch {
                lock.lock()
                self.process = nil
                lock.unlock()
                standardOutput.closeWithoutDraining()
                standardError.closeWithoutDraining()
                try? standardOutputPipe.fileHandleForWriting.close()
                try? standardErrorPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class VMAssetPipeCollector {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    var text: String {
        lock.lock()
        let data = data
        lock.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                return
            }
            self?.append(chunk)
        }
    }

    func finish() {
        handle.readabilityHandler = nil
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty {
            append(remaining)
        }
        try? handle.close()
    }

    func closeWithoutDraining() {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}
