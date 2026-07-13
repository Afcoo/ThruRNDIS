import CryptoKit
import Foundation
@testable import ThruRNDIS

enum VMAssetTestSupport {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThruRNDISTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    static func createAssetFolder(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try Data("kernel".utf8).write(to: url.appendingPathComponent("Image-lts"))
        try Data("initramfs".utf8).write(
            to: url.appendingPathComponent("initramfs-thrurndis-lts")
        )
    }

    static func release(
        archiveURL: URL = URL(string: "https://example.com/vm_assets.zip")!,
        checksumsURL: URL = URL(string: "https://example.com/SHA256SUMS")!,
        archiveSize: Int64 = 7,
        checksumsSize: Int64 = 8,
        archiveSHA256: String? = String(repeating: "a", count: 64),
        checksumsSHA256: String? = String(repeating: "b", count: 64)
    ) -> VMAssetReleaseDescriptor {
        VMAssetReleaseDescriptor(
            id: 42,
            tagName: "v1.2.3",
            archive: VMAssetRemoteAsset(
                id: 100,
                name: "vm_assets.zip",
                downloadURL: archiveURL,
                size: archiveSize,
                sha256Digest: archiveSHA256
            ),
            checksums: VMAssetRemoteAsset(
                id: 101,
                name: "SHA256SUMS",
                downloadURL: checksumsURL,
                size: checksumsSize,
                sha256Digest: checksumsSHA256
            )
        )
    }

    static func installedRelease(at releaseDirectoryURL: URL) -> InstalledVMAssetRelease {
        InstalledVMAssetRelease(
            metadata: VMAssetInstallMetadata(
                releaseID: 42,
                tagName: "v1.2.3",
                archiveAssetID: 100,
                archiveSHA256: String(repeating: "a", count: 64),
                installedAt: Date(timeIntervalSince1970: 1_000)
            ),
            releaseDirectoryURL: releaseDirectoryURL
        )
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw NSError(
                domain: "VMAssetTestSupport",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }
}

final class VMAssetStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
