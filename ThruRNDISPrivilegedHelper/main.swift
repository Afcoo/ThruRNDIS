/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Dispatch
import Foundation
import OSLog

private enum PrivilegedHelperStartupError: Error, LocalizedError {
    case invalidHelperIdentifier(String)
    case notRunningAsRoot

    var errorDescription: String? {
        switch self {
        case .invalidHelperIdentifier(let identifier):
            "The helper signing identifier does not use the required privileged-helper suffix: \(identifier)."
        case .notRunningAsRoot:
            "The Network Helper launch daemon is not running as root."
        }
    }
}

private final class PrivilegedHelperRuntime {
    private let listener: NSXPCListener
    private let listenerDelegate: NetworkRoutePrivilegedHelperListenerDelegate

    init() throws {
        guard geteuid() == 0 else {
            throw PrivilegedHelperStartupError.notRunningAsRoot
        }
        let helperIdentifier = try PeerCodeSigningRequirementBuilder
            .currentSigningIdentifier()
        guard let authorizedClientIdentifier = ThruRNDISNetworkRoute
            .applicationBundleIdentifier(
                derivedFromHelperBundleIdentifier: helperIdentifier
            ) else {
            throw PrivilegedHelperStartupError.invalidHelperIdentifier(
                helperIdentifier
            )
        }
        let clientRequirement = try PeerCodeSigningRequirementBuilder
            .requirement(forPeerIdentifier: authorizedClientIdentifier)
        let controller = NetworkRouteController()
        listenerDelegate = NetworkRoutePrivilegedHelperListenerDelegate(
            controller: controller
        )
        listener = NSXPCListener(machServiceName: helperIdentifier)
        // Foundation rejects nonmatching clients before invoking our delegate.
        // This combines the exact app identifier with the helper's own Team ID.
        listener.setConnectionCodeSigningRequirement(clientRequirement)
        listener.delegate = listenerDelegate
    }

    func run() -> Never {
        listener.activate()
        withExtendedLifetime(self) {
            dispatchMain()
        }
    }
}

private let logger = Logger(
    subsystem: "ThruRNDIS",
    category: "PrivilegedHelper"
)

do {
    try PrivilegedHelperRuntime().run()
} catch {
    logger.fault("Network Helper startup failed: \(error.localizedDescription, privacy: .public)")
    exit(EXIT_FAILURE)
}
