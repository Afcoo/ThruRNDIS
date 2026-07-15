/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum VMAssetReleaseServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case unavailableRelease
    case missingAsset(String)
    case duplicateAsset(String)
    case invalidAssetURL(String)
    case invalidAssetDigest(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "GitHub returned an invalid response while checking VM assets.")
        case .httpStatus(403):
            return String(localized: "GitHub rejected the release request. The unauthenticated API rate limit may have been reached.")
        case .httpStatus(let status):
            return String(localized: "GitHub returned HTTP \(status) while checking VM assets.")
        case .unavailableRelease:
            return String(localized: "GitHub did not return a published VM asset release.")
        case .missingAsset(let name):
            return String(localized: "The latest VM asset release does not contain \(name).")
        case .duplicateAsset(let name):
            return String(localized: "The latest VM asset release contains more than one \(name) attachment.")
        case .invalidAssetURL(let name):
            return String(localized: "The latest VM asset release contains an invalid download URL for \(name).")
        case .invalidAssetDigest(let name):
            return String(localized: "The latest VM asset release contains an invalid SHA-256 digest for \(name).")
        }
    }
}

final class GitHubVMAssetReleaseService: VMAssetReleaseServing {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/Afcoo/ThruRNDIS_VM_Assets/releases/latest"
    )!

    private let session: URLSession
    private let endpointURL: URL

    init(
        session: URLSession = .shared,
        endpointURL: URL = GitHubVMAssetReleaseService.latestReleaseURL
    ) {
        self.session = session
        self.endpointURL = endpointURL
    }

    func fetchLatestRelease() async throws -> VMAssetReleaseDescriptor {
        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ThruRNDIS", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw VMAssetReleaseServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw VMAssetReleaseServiceError.httpStatus(response.statusCode)
        }

        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !payload.draft, !payload.prerelease else {
            throw VMAssetReleaseServiceError.unavailableRelease
        }

        return VMAssetReleaseDescriptor(
            id: payload.id,
            tagName: payload.tagName,
            archive: try remoteAsset(named: "vm_assets.zip", in: payload.assets),
            checksums: try remoteAsset(named: "SHA256SUMS", in: payload.assets)
        )
    }

    private func remoteAsset(
        named name: String,
        in assets: [GitHubRelease.Asset]
    ) throws -> VMAssetRemoteAsset {
        let matches = assets.filter { $0.name == name }
        guard !matches.isEmpty else {
            throw VMAssetReleaseServiceError.missingAsset(name)
        }
        guard matches.count == 1, let asset = matches.first else {
            throw VMAssetReleaseServiceError.duplicateAsset(name)
        }
        guard asset.browserDownloadURL.scheme?.lowercased() == "https" else {
            throw VMAssetReleaseServiceError.invalidAssetURL(name)
        }
        let sha256Digest = try parseSHA256Digest(asset.digest, assetName: name)
        return VMAssetRemoteAsset(
            id: asset.id,
            name: asset.name,
            downloadURL: asset.browserDownloadURL,
            size: asset.size,
            sha256Digest: sha256Digest
        )
    }

    private func parseSHA256Digest(_ digest: String?, assetName: String) throws -> String? {
        guard let digest else {
            return nil
        }
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else {
            throw VMAssetReleaseServiceError.invalidAssetDigest(assetName)
        }
        let value = String(digest.dropFirst(prefix.count))
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw VMAssetReleaseServiceError.invalidAssetDigest(assetName)
        }
        return value
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let id: Int64
        let name: String
        let browserDownloadURL: URL
        let size: Int64
        let digest: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    let id: Int64
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}
