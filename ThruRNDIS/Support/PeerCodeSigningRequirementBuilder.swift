/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import Security

enum PeerCodeSigningRequirementError: Error, LocalizedError {
    case currentCodeUnavailable(OSStatus)
    case staticCodeUnavailable(OSStatus)
    case signingInformationUnavailable(OSStatus)
    case teamIdentifierUnavailable
    case signingIdentifierUnavailable
    case invalidIdentifier(String)
    case invalidTeamIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .currentCodeUnavailable(let status):
            String(localized: "Could not inspect the current code signature (\(status)).")
        case .staticCodeUnavailable(let status):
            String(localized: "Could not resolve the current signed executable (\(status)).")
        case .signingInformationUnavailable(let status):
            String(localized: "Could not read code-signing information (\(status)).")
        case .teamIdentifierUnavailable:
            String(localized: "A signed Runtime build is required to use the network route helper.")
        case .signingIdentifierUnavailable:
            String(localized: "The current code signature has no signing identifier.")
        case .invalidIdentifier(let identifier):
            String(localized: "The code-signing identifier is invalid: \(identifier)")
        case .invalidTeamIdentifier(let identifier):
            String(localized: "The code-signing team identifier is invalid: \(identifier)")
        }
    }
}

enum PeerCodeSigningRequirementBuilder {
    static var currentProcessHasTeamIdentifier: Bool {
        (try? currentTeamIdentifier()) != nil
    }

    static func requirement(
        forPeerIdentifier peerIdentifier: String
    ) throws -> String {
        guard isSafeIdentifier(peerIdentifier) else {
            throw PeerCodeSigningRequirementError.invalidIdentifier(peerIdentifier)
        }
        let teamIdentifier = try currentTeamIdentifier()
        guard teamIdentifier.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }) else {
            throw PeerCodeSigningRequirementError.invalidTeamIdentifier(
                teamIdentifier
            )
        }
        return "anchor apple generic and identifier \"\(peerIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func currentSigningIdentifier() throws -> String {
        let information = try currentSigningInformation()
        guard let identifier = information[kSecCodeInfoIdentifier] as? String,
              !identifier.isEmpty else {
            throw PeerCodeSigningRequirementError.signingIdentifierUnavailable
        }
        return identifier
    }

    private static func currentTeamIdentifier() throws -> String {
        let information = try currentSigningInformation()
        guard let teamIdentifier = information[kSecCodeInfoTeamIdentifier]
            as? String,
              !teamIdentifier.isEmpty else {
            throw PeerCodeSigningRequirementError.teamIdentifierUnavailable
        }
        return teamIdentifier
    }

    private static func currentSigningInformation() throws -> [CFString: Any] {
        var currentCode: SecCode?
        let copyStatus = SecCodeCopySelf([], &currentCode)
        guard copyStatus == errSecSuccess, let currentCode else {
            throw PeerCodeSigningRequirementError.currentCodeUnavailable(
                copyStatus
            )
        }

        var staticCode: SecStaticCode?
        let staticCodeStatus = SecCodeCopyStaticCode(
            currentCode,
            [],
            &staticCode
        )
        guard staticCodeStatus == errSecSuccess, let staticCode else {
            throw PeerCodeSigningRequirementError.staticCodeUnavailable(
                staticCodeStatus
            )
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [CFString: Any] else {
            throw PeerCodeSigningRequirementError.signingInformationUnavailable(
                informationStatus
            )
        }
        return information
    }

    private static func isSafeIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }
    }
}
