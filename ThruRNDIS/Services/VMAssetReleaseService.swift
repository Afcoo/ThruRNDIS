/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum VMAssetReleaseServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidManifest
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "The VM asset download manifest response was invalid.")
        case .httpStatus(let status):
            return String(localized: "Checking VM assets failed with HTTP \(status).")
        case .invalidManifest:
            return String(localized: "The VM asset download manifest is invalid.")
        case .unsupportedVersion:
            return String(localized: "Incompatible VM asset version")
        }
    }
}

final class VMAssetReleaseService {
    static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/Afcoo/ThruRNDIS_VM_Assets/main/releases/v1.json"
    )!

    private let session: URLSession
    private let endpointURL: URL

    init(session: URLSession = .shared, endpointURL: URL = VMAssetReleaseService.manifestURL) {
        self.session = session
        self.endpointURL = endpointURL
    }

    func fetchLatestCompatibleRelease() async throws -> VMAssetReleaseDescriptor {
        var request = URLRequest(url: endpointURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ThruRNDIS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw VMAssetReleaseServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw VMAssetReleaseServiceError.httpStatus(response.statusCode)
        }
        guard let release = try? JSONDecoder().decode(VMAssetReleaseDescriptor.self, from: data) else {
            throw VMAssetReleaseServiceError.invalidManifest
        }
        guard release.schemaVersion == 1, release.assetVersion == 1 else {
            throw VMAssetReleaseServiceError.unsupportedVersion
        }
        // The tag is one URL component, never an arbitrary URL or filesystem path.
        guard release.tagName.hasPrefix("V1-"), release.tagName.count > 3,
              release.tagName.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || [45, 46, 95].contains($0)
              }),
              release.size > 0,
              release.sha256.utf8.count == 64,
              release.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw VMAssetReleaseServiceError.invalidManifest
        }
        return release
    }
}
