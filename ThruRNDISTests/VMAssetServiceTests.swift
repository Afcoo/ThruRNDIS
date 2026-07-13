import Foundation
import XCTest
@testable import ThruRNDIS

final class VMAssetServiceTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = try VMAssetTestSupport.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        VMAssetStubURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func testReleaseServiceRequiresExactAttachments() async throws {
        let endpointURL = URL(string: "https://example.com/latest")!
        let payload = """
        {
          "id": 42,
          "tag_name": "v1.2.3",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"id": 100, "name": "vm_assets.zip", "browser_download_url": "https://example.com/vm_assets.zip", "size": 7, "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
            {"id": 101, "name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS", "size": 8, "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
          ]
        }
        """
        VMAssetStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, endpointURL)
            return (
                HTTPURLResponse(url: endpointURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        let session = stubSession()
        let release = try await GitHubVMAssetReleaseService(
            session: session,
            endpointURL: endpointURL
        ).fetchLatestRelease()

        XCTAssertEqual(release, VMAssetTestSupport.release())
        session.invalidateAndCancel()
    }

    func testReleaseServiceRejectsMalformedAssetDigest() async throws {
        let endpointURL = URL(string: "https://example.com/latest")!
        let payload = """
        {
          "id": 42,
          "tag_name": "v1.2.3",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"id": 100, "name": "vm_assets.zip", "browser_download_url": "https://example.com/vm_assets.zip", "size": 7, "digest": "sha256:not-a-digest"},
            {"id": 101, "name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS", "size": 8}
          ]
        }
        """
        VMAssetStubURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        let session = stubSession()

        do {
            _ = try await GitHubVMAssetReleaseService(
                session: session,
                endpointURL: endpointURL
            ).fetchLatestRelease()
            XCTFail("Expected a malformed GitHub asset digest to be rejected.")
        } catch VMAssetReleaseServiceError.invalidAssetDigest(let name) {
            XCTAssertEqual(name, "vm_assets.zip")
        }
        session.invalidateAndCancel()
    }

    func testDownloadServiceWritesBothAssetsAndReportsProgress() async throws {
        let archiveData = Data("archive".utf8)
        let checksumsData = Data("checksum".utf8)
        VMAssetStubURLProtocol.handler = { request in
            let data = request.url?.lastPathComponent == "vm_assets.zip"
                ? archiveData
                : checksumsData
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VMAssetStubURLProtocol.self]
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "download-tests"
        )
        let release = VMAssetTestSupport.release(
            archiveSize: Int64(archiveData.count),
            checksumsSize: Int64(checksumsData.count)
        )
        var progressValues: [Double] = []
        let package = try await VMAssetDownloadService(
            configuration: configuration,
            layout: layout
        ).download(release: release, operationID: UUID()) {
            progressValues.append($0)
        }

        XCTAssertEqual(try Data(contentsOf: package.archiveURL), archiveData)
        XCTAssertEqual(try Data(contentsOf: package.checksumsURL), checksumsData)
        XCTAssertEqual(progressValues.last, 1)
    }

    func testInstallerVerifiesExtractsAndPromotesRelease() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "install-tests"
        )
        let stagingURL = layout.stagingURL(for: UUID())
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let sourceRootURL = temporaryURL.appendingPathComponent("source", isDirectory: true)
        let assetFolderURL = sourceRootURL.appendingPathComponent("vm_assets", isDirectory: true)
        try VMAssetTestSupport.createAssetFolder(at: assetFolderURL)
        let archiveURL = stagingURL.appendingPathComponent("vm_assets.zip")
        try VMAssetTestSupport.run(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", assetFolderURL.path, archiveURL.path]
        )
        let hash = try VMAssetTestSupport.sha256(of: archiveURL)
        let checksumsURL = stagingURL.appendingPathComponent("SHA256SUMS")
        try Data("\(hash)  vm_assets.zip\n".utf8).write(to: checksumsURL)
        let release = VMAssetTestSupport.release(
            archiveSize: fileSize(archiveURL),
            checksumsSize: fileSize(checksumsURL),
            archiveSHA256: hash
        )
        let package = DownloadedVMAssetPackage(
            release: release,
            stagingDirectoryURL: stagingURL,
            archiveURL: archiveURL,
            checksumsURL: checksumsURL
        )

        var stages: [VMAssetInstallStage] = []
        let installed = try await VMAssetInstallService(layout: layout).install(package: package) {
            stages.append($0)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.assetFolderURL.appendingPathComponent("Image-lts").path))
        XCTAssertEqual(installed.metadata.archiveSHA256, hash)
        XCTAssertEqual(stages.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    func testInstallerRequiresArchiveToMatchGitHubDigestAndSHA256SUMS() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "release-digest-tests"
        )
        let package = try makeDummyPackage(
            layout: layout,
            archiveDigest: String(repeating: "0", count: 64)
        )
        let actualHash = try VMAssetTestSupport.sha256(of: package.archiveURL)

        do {
            _ = try await VMAssetInstallService(
                layout: layout,
                processRunner: StubProcessRunner(results: [])
            ).install(package: package) { _ in }
            XCTFail("Expected the GitHub archive digest mismatch to be rejected.")
        } catch VMAssetInstallError.checksumMismatch(let expected, let actual) {
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual, actualHash)
        }
    }

    func testInstallerRejectsUnsafeArchivePathBeforeExtraction() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "unsafe-tests"
        )
        let stagingURL = layout.stagingURL(for: UUID())
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let archiveURL = stagingURL.appendingPathComponent("vm_assets.zip")
        try Data("not-a-real-zip".utf8).write(to: archiveURL)
        let hash = try VMAssetTestSupport.sha256(of: archiveURL)
        let checksumsURL = stagingURL.appendingPathComponent("SHA256SUMS")
        try Data("\(hash)  vm_assets.zip\n".utf8).write(to: checksumsURL)
        let package = DownloadedVMAssetPackage(
            release: VMAssetTestSupport.release(
                archiveSize: fileSize(archiveURL),
                checksumsSize: fileSize(checksumsURL),
                archiveSHA256: hash
            ),
            stagingDirectoryURL: stagingURL,
            archiveURL: archiveURL,
            checksumsURL: checksumsURL
        )
        let runner = StubProcessRunner(results: [
            VMAssetProcessResult(
                terminationStatus: 0,
                standardOutput: "../escape\n",
                standardError: ""
            ),
        ])

        do {
            _ = try await VMAssetInstallService(
                layout: layout,
                processRunner: runner
            ).install(package: package) { _ in }
            XCTFail("Expected unsafe archive rejection")
        } catch let error as VMAssetInstallError {
            guard case .unsafeArchiveEntry = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    func testInstallerCancellationReachesDetachedProcessAndPreventsPromotion() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "cancel-install-tests"
        )
        let package = try makeDummyPackage(layout: layout)
        let runner = CancellationProcessRunner()
        let service = VMAssetInstallService(layout: layout, processRunner: runner)
        let installTask = Task {
            try await service.install(package: package) { _ in }
        }

        let deadline = Date().addingTimeInterval(2)
        while !(await runner.didStartExtraction) {
            guard Date() < deadline else {
                installTask.cancel()
                throw VMAssetServiceTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        installTask.cancel()
        do {
            _ = try await installTask.value
            XCTFail("Expected installer cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let processWasCancelled = await runner.wasCancelled
        XCTAssertTrue(processWasCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.stagingDirectoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.releaseURL(releaseID: 42, archiveAssetID: 100).path
        ))
    }

    func testProcessRunnerCompletesWhenExecutableCannotLaunch() async {
        let completed = expectation(description: "Process launch failure returned")
        let task = Task {
            defer { completed.fulfill() }
            do {
                _ = try await VMAssetProcessRunner().run(
                    executableURL: URL(fileURLWithPath: "/definitely-missing/thrurndis-test-command"),
                    arguments: []
                )
                XCTFail("Expected the missing executable to fail to launch.")
            } catch {
                // Expected. The assertion is that the failure completes instead of blocking on pipe EOF.
            }
        }

        await fulfillment(of: [completed], timeout: 2)
        task.cancel()
    }

    func testInstallReplacesExistingReleaseWithMismatchedMetadata() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "metadata-repair-tests"
        )
        let package = try makeInstallPackage(layout: layout)
        let destinationURL = layout.releaseURL(releaseID: 42, archiveAssetID: 100)
        try VMAssetTestSupport.createAssetFolder(
            at: destinationURL.appendingPathComponent("vm_assets", isDirectory: true)
        )
        try Data("old-kernel".utf8).write(
            to: destinationURL.appendingPathComponent("vm_assets/Image-lts")
        )
        let archiveHash = try VMAssetTestSupport.sha256(of: package.archiveURL)
        try writeMetadata(
            VMAssetInstallMetadata(
                releaseID: 999,
                tagName: package.release.tagName,
                archiveAssetID: 888,
                archiveSHA256: archiveHash,
                installedAt: Date(timeIntervalSince1970: 100)
            ),
            to: destinationURL
        )

        let installed = try await VMAssetInstallService(layout: layout).install(
            package: package
        ) { _ in }

        XCTAssertEqual(installed.metadata.releaseID, package.release.id)
        XCTAssertEqual(installed.metadata.archiveAssetID, package.release.archive.id)
        XCTAssertEqual(installed.metadata.tagName, package.release.tagName)
        XCTAssertEqual(installed.metadata.archiveSHA256, archiveHash)
        XCTAssertEqual(
            try String(
                contentsOf: installed.assetFolderURL.appendingPathComponent("Image-lts"),
                encoding: .utf8
            ),
            "kernel"
        )
    }

    func testInstalledReleaseMatchingRejectsWrongTagAndMalformedHash() throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "metadata-match-tests"
        )
        let releaseURL = layout.releaseURL(releaseID: 42, archiveAssetID: 100)
        try VMAssetTestSupport.createAssetFolder(
            at: releaseURL.appendingPathComponent("vm_assets", isDirectory: true)
        )
        let service = VMAssetInstallService(layout: layout)

        try writeMetadata(
            VMAssetInstallMetadata(
                releaseID: 42,
                tagName: "wrong-tag",
                archiveAssetID: 100,
                archiveSHA256: String(repeating: "a", count: 64),
                installedAt: Date()
            ),
            to: releaseURL
        )
        XCTAssertNil(try service.installedRelease(matching: VMAssetTestSupport.release()))

        try writeMetadata(
            VMAssetInstallMetadata(
                releaseID: 42,
                tagName: "v1.2.3",
                archiveAssetID: 100,
                archiveSHA256: "not-a-sha256",
                installedAt: Date()
            ),
            to: releaseURL
        )
        XCTAssertNil(try service.installedRelease(matching: VMAssetTestSupport.release()))

        try writeMetadata(VMAssetTestSupport.installedRelease(at: releaseURL).metadata, to: releaseURL)
        XCTAssertNotNil(try service.installedRelease(matching: VMAssetTestSupport.release()))
    }

    func testInstalledReleaseInventoryRejectsMismatchedDirectoryMetadata() throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "metadata-directory-identity-tests"
        )
        let releaseURL = layout.releaseURL(releaseID: 42, archiveAssetID: 100)
        try VMAssetTestSupport.createAssetFolder(
            at: releaseURL.appendingPathComponent("vm_assets", isDirectory: true)
        )
        try writeMetadata(
            VMAssetInstallMetadata(
                releaseID: 999,
                tagName: "v1.2.3",
                archiveAssetID: 888,
                archiveSHA256: String(repeating: "a", count: 64),
                installedAt: Date()
            ),
            to: releaseURL
        )

        XCTAssertTrue(try VMAssetInstallService(layout: layout).installedReleases().isEmpty)
    }

    func testInstallerRejectsDotRepeatedSeparatorAndBackslashPaths() async throws {
        let unsafeNames = [
            "vm_assets/./Image-lts\n",
            "vm_assets//Image-lts\n",
            "vm_assets\\Image-lts\n",
        ]

        for names in unsafeNames {
            let error = try await archiveRejectionError(names: names)
            guard case .unsafeArchiveEntry = error else {
                return XCTFail("Expected unsafe archive entry, received \(error)")
            }
        }
    }

    func testInstallerRejectsExactCaseUnicodeAndDirectoryAliases() async throws {
        let collidingNames = [
            "vm_assets/Image-lts\nvm_assets/Image-lts\n",
            "vm_assets/Image-lts\nvm_assets/image-LTS\n",
            "vm_assets/Café\nvm_assets/Cafe\u{301}\n",
            "vm_assets\nvm_assets/\n",
        ]

        for names in collidingNames {
            let error = try await archiveRejectionError(names: names)
            guard case .duplicateArchiveEntry = error else {
                return XCTFail("Expected duplicate archive entry, received \(error)")
            }
        }
    }

    func testInstallerRejectsSymbolicLinkEntries() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "symlink-archive-\(UUID().uuidString)"
        )
        let package = try makeDummyPackage(layout: layout)
        let runner = StubProcessRunner(results: [
            VMAssetProcessResult(
                terminationStatus: 0,
                standardOutput: "vm_assets/Image-lts\nvm_assets/initramfs-thrurndis-lts\n",
                standardError: ""
            ),
            VMAssetProcessResult(
                terminationStatus: 0,
                standardOutput: "lrwxr-xr-x  3.0 unx  0 bx  0% 01-Jan-26 vm_assets/link\n",
                standardError: ""
            ),
        ])

        do {
            _ = try await VMAssetInstallService(
                layout: layout,
                processRunner: runner
            ).install(package: package) { _ in }
            XCTFail("Expected symbolic-link rejection")
        } catch let error as VMAssetInstallError {
            guard case .symbolicLink = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPruningPreservesManualSelectionAncestorInsideManagedStorage() throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "prune-protection-tests"
        )
        let keepURL = layout.releaseURL(releaseID: 42, archiveAssetID: 100)
        let protectedReleaseURL = layout.releaseURL(releaseID: 41, archiveAssetID: 90)
        let removableURL = layout.releaseURL(releaseID: 40, archiveAssetID: 80)
        let protectedSelectionURL = protectedReleaseURL
            .appendingPathComponent("vm_assets/boot", isDirectory: true)
        for url in [keepURL, protectedSelectionURL, removableURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        try VMAssetInstallService(layout: layout).pruneInstalledReleases(
            keeping: VMAssetTestSupport.installedRelease(at: keepURL),
            preserving: protectedSelectionURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: keepURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedReleaseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removableURL.path))
    }

    func testPromotionRestoresPreviousReleaseAfterPostMoveValidationFailure() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "promotion-rollback-tests"
        )
        let package = try makeInstallPackage(layout: layout)
        let destinationURL = layout.releaseURL(releaseID: 42, archiveAssetID: 100)
        let oldAssetFolderURL = destinationURL.appendingPathComponent("vm_assets", isDirectory: true)
        try VMAssetTestSupport.createAssetFolder(at: oldAssetFolderURL)
        try Data("old-kernel".utf8).write(to: oldAssetFolderURL.appendingPathComponent("Image-lts"))
        let oldMetadata = VMAssetInstallMetadata(
            releaseID: 42,
            tagName: "v1.2.3",
            archiveAssetID: 100,
            archiveSHA256: String(repeating: "b", count: 64),
            installedAt: Date(timeIntervalSince1970: 100)
        )
        try writeMetadata(oldMetadata, to: destinationURL)
        let extractedKernelURL = package.stagingDirectoryURL
            .appendingPathComponent("extracted/vm_assets/Image-lts")
        let injectionLock = NSLock()
        var didReachPostExtractionInjection = false
        let service = VMAssetInstallService(
            layout: layout,
            now: {
                injectionLock.withLock {
                    didReachPostExtractionInjection = true
                }
                try? FileManager.default.removeItem(at: extractedKernelURL)
                return Date(timeIntervalSince1970: 200)
            }
        )

        do {
            _ = try await service.install(package: package) { _ in }
            XCTFail("Expected post-promotion validation failure")
        } catch VMAssetInstallError.invalidInstalledRelease(let releaseURL) {
            XCTAssertEqual(releaseURL.standardizedFileURL, destinationURL.standardizedFileURL)
        } catch {
            XCTFail("Unexpected error before post-promotion validation: \(error)")
        }

        XCTAssertTrue(injectionLock.withLock { didReachPostExtractionInjection })
        XCTAssertEqual(
            try String(
                contentsOf: oldAssetFolderURL.appendingPathComponent("Image-lts"),
                encoding: .utf8
            ),
            "old-kernel"
        )
        let restoredData = try Data(
            contentsOf: destinationURL.appendingPathComponent("install.json")
        )
        XCTAssertEqual(
            try JSONDecoder.vmAssetMetadata.decode(VMAssetInstallMetadata.self, from: restoredData),
            oldMetadata
        )
    }

    func testPromotionCancellationAfterBackupMoveRestoresPreviousRelease() async throws {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "promotion-cancel-rollback-tests"
        )
        let package = try makeInstallPackage(layout: layout)
        let destinationURL = layout.releaseURL(releaseID: 42, archiveAssetID: 100)
        let oldAssetFolderURL = destinationURL.appendingPathComponent("vm_assets", isDirectory: true)
        try VMAssetTestSupport.createAssetFolder(at: oldAssetFolderURL)
        try Data("old-kernel".utf8).write(to: oldAssetFolderURL.appendingPathComponent("Image-lts"))
        let oldMetadata = VMAssetInstallMetadata(
            releaseID: 42,
            tagName: "previous-tag",
            archiveAssetID: 100,
            archiveSHA256: String(repeating: "c", count: 64),
            installedAt: Date(timeIntervalSince1970: 100)
        )
        try writeMetadata(oldMetadata, to: destinationURL)

        let fileManager = BackupBlockingFileManager()
        let service = VMAssetInstallService(fileManager: fileManager, layout: layout)
        let installTask = Task {
            try await service.install(package: package) { _ in }
        }
        defer {
            installTask.cancel()
            fileManager.resumeAfterBackupMove()
        }

        let deadline = Date().addingTimeInterval(2)
        while !fileManager.didMoveBackup {
            guard Date() < deadline else {
                throw VMAssetServiceTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        installTask.cancel()
        fileManager.resumeAfterBackupMove()
        do {
            _ = try await installTask.value
            XCTFail("Expected cancellation during promotion.")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            try String(
                contentsOf: oldAssetFolderURL.appendingPathComponent("Image-lts"),
                encoding: .utf8
            ),
            "old-kernel"
        )
        let restoredData = try Data(contentsOf: destinationURL.appendingPathComponent("install.json"))
        XCTAssertEqual(
            try JSONDecoder.vmAssetMetadata.decode(VMAssetInstallMetadata.self, from: restoredData),
            oldMetadata
        )
        let releaseChildren = try FileManager.default.contentsOfDirectory(
            at: layout.releasesDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(releaseChildren.contains { $0.lastPathComponent.hasPrefix(".backup-") })
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VMAssetStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func makeInstallPackage(
        layout: VMAssetStorageLayout
    ) throws -> DownloadedVMAssetPackage {
        let stagingURL = layout.stagingURL(for: UUID())
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let sourceRootURL = temporaryURL.appendingPathComponent(
            "source-\(UUID().uuidString)",
            isDirectory: true
        )
        let assetFolderURL = sourceRootURL.appendingPathComponent("vm_assets", isDirectory: true)
        try VMAssetTestSupport.createAssetFolder(at: assetFolderURL)
        let archiveURL = stagingURL.appendingPathComponent("vm_assets.zip")
        try VMAssetTestSupport.run(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", assetFolderURL.path, archiveURL.path]
        )
        let hash = try VMAssetTestSupport.sha256(of: archiveURL)
        let checksumsURL = stagingURL.appendingPathComponent("SHA256SUMS")
        try Data("\(hash)  vm_assets.zip\n".utf8).write(to: checksumsURL)
        let release = VMAssetTestSupport.release(
            archiveSize: fileSize(archiveURL),
            checksumsSize: fileSize(checksumsURL),
            archiveSHA256: hash
        )
        return DownloadedVMAssetPackage(
            release: release,
            stagingDirectoryURL: stagingURL,
            archiveURL: archiveURL,
            checksumsURL: checksumsURL
        )
    }

    private func makeDummyPackage(
        layout: VMAssetStorageLayout,
        archiveDigest: String? = nil
    ) throws -> DownloadedVMAssetPackage {
        let stagingURL = layout.stagingURL(for: UUID())
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let archiveURL = stagingURL.appendingPathComponent("vm_assets.zip")
        try Data("dummy-archive".utf8).write(to: archiveURL)
        let hash = try VMAssetTestSupport.sha256(of: archiveURL)
        let checksumsURL = stagingURL.appendingPathComponent("SHA256SUMS")
        try Data("\(hash)  vm_assets.zip\n".utf8).write(to: checksumsURL)
        return DownloadedVMAssetPackage(
            release: VMAssetTestSupport.release(
                archiveSize: fileSize(archiveURL),
                checksumsSize: fileSize(checksumsURL),
                archiveSHA256: archiveDigest ?? hash
            ),
            stagingDirectoryURL: stagingURL,
            archiveURL: archiveURL,
            checksumsURL: checksumsURL
        )
    }

    private func archiveRejectionError(names: String) async throws -> VMAssetInstallError {
        let layout = VMAssetStorageLayout(
            applicationSupportDirectoryURL: temporaryURL,
            bundleIdentifier: "archive-alias-\(UUID().uuidString)"
        )
        let package = try makeDummyPackage(layout: layout)
        let runner = StubProcessRunner(results: [
            VMAssetProcessResult(
                terminationStatus: 0,
                standardOutput: names,
                standardError: ""
            ),
        ])
        do {
            _ = try await VMAssetInstallService(
                layout: layout,
                processRunner: runner
            ).install(package: package) { _ in }
            XCTFail("Expected archive rejection")
            throw VMAssetServiceTestError.expectedFailure
        } catch let error as VMAssetInstallError {
            return error
        }
    }

    private func writeMetadata(
        _ metadata: VMAssetInstallMetadata,
        to releaseURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: releaseURL,
            withIntermediateDirectories: true
        )
        try JSONEncoder.vmAssetMetadata.encode(metadata).write(
            to: releaseURL.appendingPathComponent("install.json"),
            options: .atomic
        )
    }
}

private enum VMAssetServiceTestError: Error {
    case expectedFailure
    case timeout
}

private final class BackupBlockingFileManager: FileManager {
    private let stateLock = NSLock()
    private let resumeSemaphore = DispatchSemaphore(value: 0)
    private var movedBackup = false

    var didMoveBackup: Bool {
        stateLock.withLock { movedBackup }
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        guard dstURL.lastPathComponent.hasPrefix(".backup-") else {
            return
        }
        stateLock.withLock {
            movedBackup = true
        }
        _ = resumeSemaphore.wait(timeout: .now() + 5)
    }

    func resumeAfterBackupMove() {
        resumeSemaphore.signal()
    }
}

private actor CancellationProcessRunner: VMAssetProcessRunning {
    private(set) var didStartExtraction = false
    private(set) var wasCancelled = false

    func run(executableURL: URL, arguments: [String]) async throws -> VMAssetProcessResult {
        if executableURL.lastPathComponent == "zipinfo" {
            if arguments.first == "-1" {
                return VMAssetProcessResult(
                    terminationStatus: 0,
                    standardOutput: "vm_assets/Image-lts\nvm_assets/initramfs-thrurndis-lts\n",
                    standardError: ""
                )
            }
            return VMAssetProcessResult(
                terminationStatus: 0,
                standardOutput: "",
                standardError: ""
            )
        }

        didStartExtraction = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        return VMAssetProcessResult(
            terminationStatus: 0,
            standardOutput: "",
            standardError: ""
        )
    }
}

private final class StubProcessRunner: VMAssetProcessRunning {
    private var results: [VMAssetProcessResult]

    init(results: [VMAssetProcessResult]) {
        self.results = results
    }

    func run(executableURL: URL, arguments: [String]) async throws -> VMAssetProcessResult {
        guard !results.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return results.removeFirst()
    }
}
