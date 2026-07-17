/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
@preconcurrency import SystemExtensions

@MainActor
protocol WireGuardSystemExtensionActivating: AnyObject {
    var onEventLog: ((String) -> Void)? { get set }
    func activate(bundleIdentifier: String) async throws
}

@MainActor
final class WireGuardSystemExtensionActivator: NSObject, WireGuardSystemExtensionActivating {
    var onEventLog: ((String) -> Void)?

    private var activationContinuation: CheckedContinuation<Void, Error>?
    private var pendingRequest: OSSystemExtensionRequest?

    func activate(bundleIdentifier: String) async throws {
        guard activationContinuation == nil else {
            throw WireGuardSystemExtensionActivationError.activationAlreadyInProgress
        }

        try await withCheckedThrowingContinuation { continuation in
            activationContinuation = continuation

            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: bundleIdentifier,
                queue: .main
            )
            request.delegate = self
            pendingRequest = request
            onEventLog?(
                "Requesting activation for WireGuard system extension \(bundleIdentifier)."
            )
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(with result: Result<Void, Error>) {
        let continuation = activationContinuation
        activationContinuation = nil
        pendingRequest = nil
        continuation?.resume(with: result)
    }
}

extension WireGuardSystemExtensionActivator: @MainActor OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        onEventLog?(
            "Replacing WireGuard system extension version \(existing.bundleShortVersion) " +
                "with \(replacement.bundleShortVersion)."
        )
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onEventLog?(
            "WireGuard system extension activation is waiting for user approval in System Settings."
        )
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            onEventLog?("WireGuard system extension is active.")
            finish(with: .success(()))
        case .willCompleteAfterReboot:
            finish(with: .failure(WireGuardSystemExtensionActivationError.restartRequired))
        @unknown default:
            finish(with: .failure(WireGuardSystemExtensionActivationError.unknownResult))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(with: .failure(error))
    }
}

enum WireGuardSystemExtensionActivationError: LocalizedError {
    case activationAlreadyInProgress
    case restartRequired
    case unknownResult

    var errorDescription: String? {
        switch self {
        case .activationAlreadyInProgress:
            return String(localized: "WireGuard system extension activation is already in progress.")
        case .restartRequired:
            return String(localized: "Restart macOS to finish activating the WireGuard system extension.")
        case .unknownResult:
            return String(localized: "macOS returned an unknown WireGuard system extension activation result.")
        }
    }
}
