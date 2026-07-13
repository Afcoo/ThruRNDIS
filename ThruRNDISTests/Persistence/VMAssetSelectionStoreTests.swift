import XCTest
@testable import ThruRNDIS

final class VMAssetSelectionStoreTests: XCTestCase {
    private var temporaryURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        temporaryURL = try VMAssetTestSupport.temporaryDirectory()
        suiteName = "VMAssetSelectionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func testManualSelectionOverridesRestoreAndClear() throws {
        let folderURL = temporaryURL.appendingPathComponent("vm_assets", isDirectory: true)
        try VMAssetTestSupport.createAssetFolder(at: folderURL)
        let overrideURL = temporaryURL.appendingPathComponent("override-kernel")
        try Data("override".utf8).write(to: overrideURL)

        let store = VMAssetSelectionStore(defaults: defaults)
        var selection = try store.selectManualFolder(folderURL)
        selection = try store.setKernelOverride(overrideURL, for: selection)

        let restored = try XCTUnwrap(VMAssetSelectionStore(defaults: defaults).restoreSelection())
        XCTAssertEqual(restored.source, .manual)
        XCTAssertEqual(restored.folderURL, folderURL.standardizedFileURL)
        XCTAssertEqual(restored.kernelOverrideURL, overrideURL.standardizedFileURL)
        XCTAssertEqual(try store.validate(restored).kernelURL, overrideURL.standardizedFileURL)

        store.clearSelection()
        XCTAssertNil(try store.restoreSelection())
    }

    func testManagedSelectionPersistsReleaseMetadata() throws {
        let releaseDirectoryURL = temporaryURL.appendingPathComponent("42-100", isDirectory: true)
        let release = VMAssetTestSupport.installedRelease(at: releaseDirectoryURL)
        try VMAssetTestSupport.createAssetFolder(at: release.assetFolderURL)
        let metadata = try JSONEncoder.vmAssetMetadata.encode(release.metadata)
        try metadata.write(
            to: releaseDirectoryURL.appendingPathComponent("install.json"),
            options: .atomic
        )

        let store = VMAssetSelectionStore(defaults: defaults)
        _ = try store.selectManagedRelease(release)
        let restored = try XCTUnwrap(store.restoreSelection())

        XCTAssertEqual(restored.source, .managed)
        XCTAssertEqual(restored.managedRelease, release)
        XCTAssertEqual(try store.validate(restored).initialRamdiskURL.lastPathComponent, "initramfs-thrurndis-lts")
    }

    func testManagedSelectionWithMismatchedDirectoryMetadataRestoresAsManual() throws {
        let releaseDirectoryURL = temporaryURL.appendingPathComponent("42-100", isDirectory: true)
        let release = VMAssetTestSupport.installedRelease(at: releaseDirectoryURL)
        try VMAssetTestSupport.createAssetFolder(at: release.assetFolderURL)
        try JSONEncoder.vmAssetMetadata.encode(release.metadata).write(
            to: releaseDirectoryURL.appendingPathComponent("install.json"),
            options: .atomic
        )

        let store = VMAssetSelectionStore(defaults: defaults)
        _ = try store.selectManagedRelease(release)

        let mismatchedMetadata = VMAssetInstallMetadata(
            releaseID: 999,
            tagName: release.metadata.tagName,
            archiveAssetID: 888,
            archiveSHA256: release.metadata.archiveSHA256,
            installedAt: release.metadata.installedAt
        )
        try JSONEncoder.vmAssetMetadata.encode(mismatchedMetadata).write(
            to: releaseDirectoryURL.appendingPathComponent("install.json"),
            options: .atomic
        )

        let restored = try XCTUnwrap(store.restoreSelection())
        XCTAssertEqual(restored.source, .manual)
        XCTAssertNil(restored.managedRelease)
    }

    func testValidationRejectsBootFilesThatBecomeUnreadable() throws {
        let folderURL = temporaryURL.appendingPathComponent("vm_assets", isDirectory: true)
        try VMAssetTestSupport.createAssetFolder(at: folderURL)
        let store = VMAssetSelectionStore(defaults: defaults)
        let selection = try store.selectManualFolder(folderURL)
        let bootFiles = [selection.kernelURL, selection.initialRamdiskURL]

        for bootFileURL in bootFiles {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: bootFileURL.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: bootFileURL.path
                )
            }

            do {
                _ = try store.validate(selection)
                XCTFail("Expected unreadable boot file rejection: \(bootFileURL.lastPathComponent)")
            } catch let error as VMAssetFolderError {
                guard case .notRegularFile = error else {
                    return XCTFail("Unexpected validation error: \(error)")
                }
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: bootFileURL.path
            )
        }
    }
}
