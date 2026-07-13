/*
Copyright (C) 2026 Afcoo.
*/

import CryptoKit
import Darwin
import Foundation

struct WireGuardConfigurationFiles {
    let wireGuardDirectoryURL: URL
    let sharedDirectoryURL: URL
    let serverConfigurationURL: URL
    let serverKeyURL: URL
    let clientKeyURL: URL
}

struct PreparedWireGuardConfiguration {
    let files: WireGuardConfigurationFiles
    let keyMaterial: WireGuardKeyMaterial
}

protocol WireGuardConfigurationStoring {
    var files: WireGuardConfigurationFiles { get }
    var sharedDirectoryURL: URL { get }

    func prepareConfigurationIfNeeded(
        builder: WireGuardConfBuilder
    ) throws -> PreparedWireGuardConfiguration
    func requireExistingConfiguration(
        builder: WireGuardConfBuilder
    ) throws -> PreparedWireGuardConfiguration
    func removeConfigurationDirectory() throws
}

struct WireGuardConfStore {
    private let fileManager: FileManager
    let files: WireGuardConfigurationFiles

    var sharedDirectoryURL: URL {
        files.sharedDirectoryURL
    }

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectoryURL: URL? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.fileManager = fileManager

        let applicationSupportURL = applicationSupportDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let applicationDirectoryURL = applicationSupportURL.appendingPathComponent(
            bundleIdentifier ?? ProcessInfo.processInfo.processName,
            isDirectory: true
        )
        let wireGuardDirectoryURL = applicationDirectoryURL.appendingPathComponent(
            "WireGuard",
            isDirectory: true
        )
        let sharedDirectoryURL = wireGuardDirectoryURL.appendingPathComponent(
            "Shared",
            isDirectory: true
        )

        files = WireGuardConfigurationFiles(
            wireGuardDirectoryURL: wireGuardDirectoryURL,
            sharedDirectoryURL: sharedDirectoryURL,
            serverConfigurationURL: sharedDirectoryURL.appendingPathComponent("wg0.conf"),
            serverKeyURL: wireGuardDirectoryURL.appendingPathComponent("wg-server.key"),
            clientKeyURL: wireGuardDirectoryURL.appendingPathComponent("wg-client.key")
        )
    }

    @discardableResult
    func prepareConfigurationIfNeeded(
        builder: WireGuardConfBuilder
    ) throws -> PreparedWireGuardConfiguration {
        let serverKeyExists = fileManager.fileExists(atPath: files.serverKeyURL.path)
        let clientKeyExists = fileManager.fileExists(atPath: files.clientKeyURL.path)

        switch (serverKeyExists, clientKeyExists) {
        case (true, true):
            try secureConfigurationDirectories()
            try secureKeyFiles()
        case (false, false):
            try secureConfigurationDirectories()
            try createKeyPair()
            try secureKeyFiles()
        case (true, false):
            throw WireGuardConfStoreError.partialKeyPair(missingURL: files.clientKeyURL)
        case (false, true):
            throw WireGuardConfStoreError.partialKeyPair(missingURL: files.serverKeyURL)
        }

        return try prepareExistingConfiguration(builder: builder)
    }

    func requireExistingConfiguration(
        builder: WireGuardConfBuilder
    ) throws -> PreparedWireGuardConfiguration {
        let serverKeyExists = fileManager.fileExists(atPath: files.serverKeyURL.path)
        let clientKeyExists = fileManager.fileExists(atPath: files.clientKeyURL.path)

        guard serverKeyExists, clientKeyExists else {
            let missingURL = serverKeyExists ? files.clientKeyURL : files.serverKeyURL
            throw WireGuardConfStoreError.missingKey(missingURL)
        }

        try secureConfigurationDirectories()
        try secureKeyFiles()
        return try prepareExistingConfiguration(builder: builder)
    }

    func removeConfigurationDirectory() throws {
        guard fileManager.fileExists(atPath: files.wireGuardDirectoryURL.path) else {
            return
        }

        try fileManager.removeItem(at: files.wireGuardDirectoryURL)
    }

    private func prepareExistingConfiguration(
        builder: WireGuardConfBuilder
    ) throws -> PreparedWireGuardConfiguration {
        try builder.validate()
        let keyMaterial = try loadKeyMaterial()
        let serverConfiguration = builder.serverConfiguration(keyMaterial: keyMaterial)
        try writeServerConfiguration(serverConfiguration)

        return PreparedWireGuardConfiguration(
            files: files,
            keyMaterial: keyMaterial
        )
    }

    private func secureConfigurationDirectories() throws {
        try fileManager.createDirectory(
            at: files.wireGuardDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: files.wireGuardDirectoryURL.path
        )
        try fileManager.createDirectory(
            at: files.sharedDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: files.sharedDirectoryURL.path
        )
    }

    private func createKeyPair() throws {
        let serverPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKeyData = Data(
            "\(serverPrivateKey.rawRepresentation.base64EncodedString())\n".utf8
        )
        let clientKeyData = Data(
            "\(clientPrivateKey.rawRepresentation.base64EncodedString())\n".utf8
        )

        var createdURLs: [URL] = []
        do {
            try createSecureFile(at: files.serverKeyURL, data: serverKeyData)
            createdURLs.append(files.serverKeyURL)
            try createSecureFile(at: files.clientKeyURL, data: clientKeyData)
            createdURLs.append(files.clientKeyURL)
        } catch {
            for url in createdURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    private func secureKeyFiles() throws {
        for url in [files.serverKeyURL, files.clientKeyURL] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private func loadKeyMaterial() throws -> WireGuardKeyMaterial {
        let serverPrivateKey = try loadPrivateKey(
            at: files.serverKeyURL,
            label: "wg-server.key"
        )
        let clientPrivateKey = try loadPrivateKey(
            at: files.clientKeyURL,
            label: "wg-client.key"
        )

        return WireGuardKeyMaterial(
            serverPrivateKey: serverPrivateKey.rawRepresentation.base64EncodedString(),
            serverPublicKey: serverPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            clientPrivateKey: clientPrivateKey.rawRepresentation.base64EncodedString(),
            clientPublicKey: clientPrivateKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    private func loadPrivateKey(
        at url: URL,
        label: String
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: text), data.count == 32 else {
            throw WireGuardConfStoreError.invalidPrivateKey(label)
        }

        do {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        } catch {
            throw WireGuardConfStoreError.invalidPrivateKey(label)
        }
    }

    private func writeServerConfiguration(_ configuration: String) throws {
        let temporaryURL = files.sharedDirectoryURL.appendingPathComponent(
            ".wg0.conf.\(UUID().uuidString)"
        )

        do {
            try createSecureFile(at: temporaryURL, data: Data(configuration.utf8))
            let renameResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                files.serverConfigurationURL.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return Int32(-1) }
                    return Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw WireGuardConfStoreError.couldNotReplaceFile(
                    files.serverConfigurationURL,
                    errno
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: files.serverConfigurationURL.path
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func createSecureFile(at url: URL, data: Data) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }

        guard descriptor >= 0 else {
            throw WireGuardConfStoreError.couldNotCreateFile(url, errno)
        }

        var writeError: Error?
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0

            while bytesRemaining > 0 {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytesRemaining
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    writeError = WireGuardConfStoreError.couldNotWriteFile(url, errno)
                    break
                }
                if written == 0 {
                    writeError = WireGuardConfStoreError.couldNotWriteFile(url, EIO)
                    break
                }
                bytesRemaining -= written
                offset += written
            }
        }

        let closeResult = Darwin.close(descriptor)
        if let writeError {
            try? fileManager.removeItem(at: url)
            throw writeError
        }
        guard closeResult == 0 else {
            let closeErrno = errno
            try? fileManager.removeItem(at: url)
            throw WireGuardConfStoreError.couldNotWriteFile(url, closeErrno)
        }
    }
}

extension WireGuardConfStore: WireGuardConfigurationStoring {}

enum WireGuardConfStoreError: LocalizedError {
    case missingKey(URL)
    case partialKeyPair(missingURL: URL)
    case invalidPrivateKey(String)
    case couldNotCreateFile(URL, Int32)
    case couldNotWriteFile(URL, Int32)
    case couldNotReplaceFile(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .missingKey(let url):
            return "WireGuard private key is missing: \(url.path)"
        case .partialKeyPair(let missingURL):
            return "WireGuard key pair is incomplete. Restore the missing key without replacing the existing key: \(missingURL.path)"
        case .invalidPrivateKey(let label):
            return "Invalid WireGuard X25519 private key: \(label)."
        case .couldNotCreateFile(let url, let errorNumber):
            return "Could not securely create WireGuard file at \(url.path): \(String(cString: strerror(errorNumber)))"
        case .couldNotWriteFile(let url, let errorNumber):
            return "Could not write WireGuard file at \(url.path): \(String(cString: strerror(errorNumber)))"
        case .couldNotReplaceFile(let url, let errorNumber):
            return "Could not atomically replace WireGuard configuration at \(url.path): \(String(cString: strerror(errorNumber)))"
        }
    }
}
