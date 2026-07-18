/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
@preconcurrency import SystemExtensions

@MainActor
protocol WireGuardSystemExtensionActivating: AnyObject {
    var onEventLog: ((String) -> Void)? { get set }
    var onActivationNeedsUserApproval: (() -> Void)? { get set }

    func status(bundleIdentifier: String) async throws -> WireGuardSystemExtensionStatus
    func activate(bundleIdentifier: String) async throws
    func cancelPendingRequests()
}

struct WireGuardSystemExtensionPropertySnapshot: Equatable {
    let isEnabled: Bool
    let isAwaitingUserApproval: Bool
    let isUninstalling: Bool
}

@MainActor
final class WireGuardSystemExtensionActivator: NSObject, WireGuardSystemExtensionActivating {
    var onEventLog: ((String) -> Void)?
    var onActivationNeedsUserApproval: (() -> Void)?

    private let requestSubmitter: (OSSystemExtensionRequest) -> Void
    private var activationContinuation: CheckedContinuation<Void, Error>?
    private var pendingActivationRequest: OSSystemExtensionRequest?
    private var statusContinuations: [
        CheckedContinuation<WireGuardSystemExtensionStatus, Error>
    ] = []
    private var pendingPropertiesRequest: OSSystemExtensionRequest?

    init(
        requestSubmitter: @escaping (OSSystemExtensionRequest) -> Void = {
            OSSystemExtensionManager.shared.submitRequest($0)
        }
    ) {
        self.requestSubmitter = requestSubmitter
    }

    func status(bundleIdentifier: String) async throws -> WireGuardSystemExtensionStatus {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            if pendingPropertiesRequest != nil {
                statusContinuations.append(continuation)
                return
            }

            statusContinuations = [continuation]
            let request = OSSystemExtensionRequest.propertiesRequest(
                forExtensionWithIdentifier: bundleIdentifier,
                queue: .main
            )
            request.delegate = self
            pendingPropertiesRequest = request
            onEventLog?(
                "Reading status for network extension \(bundleIdentifier)."
            )
            requestSubmitter(request)
        }
    }

    func activate(bundleIdentifier: String) async throws {
        try Task.checkCancellation()
        guard activationContinuation == nil else {
            throw WireGuardSystemExtensionActivationError.activationAlreadyInProgress
        }

        cancelPendingStatusRequest()
        try await withCheckedThrowingContinuation { continuation in
            activationContinuation = continuation

            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: bundleIdentifier,
                queue: .main
            )
            request.delegate = self
            pendingActivationRequest = request
            onEventLog?(
                "Requesting activation for network extension \(bundleIdentifier)."
            )
            requestSubmitter(request)
        }
    }

    func cancelPendingRequests() {
        onActivationNeedsUserApproval = nil
        onEventLog = nil
        finish(with: .failure(CancellationError()))
        cancelPendingStatusRequest()
    }

    private func finish(with result: Result<Void, Error>) {
        let continuation = activationContinuation
        activationContinuation = nil
        pendingActivationRequest = nil
        continuation?.resume(with: result)
    }

    private func finishStatus(
        with result: Result<WireGuardSystemExtensionStatus, Error>
    ) {
        let continuations = statusContinuations
        statusContinuations = []
        pendingPropertiesRequest = nil
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func cancelPendingStatusRequest() {
        guard pendingPropertiesRequest != nil || !statusContinuations.isEmpty else {
            return
        }
        finishStatus(with: .failure(CancellationError()))
    }

    static func status(
        from properties: [WireGuardSystemExtensionPropertySnapshot]
    ) -> WireGuardSystemExtensionStatus {
        if properties.contains(where: { $0.isEnabled && !$0.isUninstalling }) {
            return .active
        }
        if properties.contains(where: \.isAwaitingUserApproval) {
            return .awaitingUserApproval
        }
        if properties.contains(where: \.isUninstalling) {
            return .uninstalling
        }
        return .inactive
    }
}

extension WireGuardSystemExtensionActivator: @MainActor OSSystemExtensionRequestDelegate {
    func replacementAction(
        for request: OSSystemExtensionRequest
    ) -> OSSystemExtensionRequest.ReplacementAction {
        request === pendingActivationRequest ? .replace : .cancel
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        let action = replacementAction(for: request)
        guard action == .replace else {
            return action
        }
        onEventLog?(
            "Replacing network extension version \(existing.bundleShortVersion) " +
                "with \(replacement.bundleShortVersion)."
        )
        return action
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === pendingActivationRequest else {
            return
        }
        onEventLog?(
            "Network extension activation is waiting for user approval in System Settings."
        )
        onActivationNeedsUserApproval?()
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        guard request === pendingActivationRequest else {
            return
        }
        switch result {
        case .completed:
            onEventLog?("Network extension activation request completed.")
            finish(with: .success(()))
        case .willCompleteAfterReboot:
            finish(with: .failure(WireGuardSystemExtensionActivationError.restartRequired))
        @unknown default:
            finish(with: .failure(WireGuardSystemExtensionActivationError.unknownResult))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if request === pendingActivationRequest {
            finish(with: .failure(error))
        } else if request === pendingPropertiesRequest {
            finishStatus(with: .failure(error))
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        guard request === pendingPropertiesRequest else {
            return
        }
        let snapshots = properties.map {
            WireGuardSystemExtensionPropertySnapshot(
                isEnabled: $0.isEnabled,
                isAwaitingUserApproval: $0.isAwaitingUserApproval,
                isUninstalling: $0.isUninstalling
            )
        }
        finishStatus(with: .success(Self.status(from: snapshots)))
    }
}

enum WireGuardSystemExtensionActivationError: LocalizedError {
    case activationAlreadyInProgress
    case extensionRemainsDisabled
    case restartRequired
    case unknownResult

    var errorDescription: String? {
        switch self {
        case .activationAlreadyInProgress:
            return String(localized: "Network extension activation is already in progress.")
        case .extensionRemainsDisabled:
            return String(
                localized: "The network extension is still disabled after the activation request completed."
            )
        case .restartRequired:
            return String(localized: "Restart macOS to finish activating the network extension.")
        case .unknownResult:
            return String(localized: "macOS returned an unknown network extension activation result.")
        }
    }
}
