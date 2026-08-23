/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import Network

/// Performs one bounded wired-path observation and requires the allocated
/// managed Bond, so another Ethernet interface cannot satisfy readiness.
struct NetworkRouteNetworkPathMonitor: Sendable {
    func waitUntilSatisfied(
        interfaceName: String,
        timeout: TimeInterval
    ) -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        let queue = DispatchQueue(
            label: "ThruRNDIS.NetworkRouteNetworkPathMonitor"
        )
        let semaphore = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied,
                  path.availableInterfaces.contains(where: {
                      $0.name == interfaceName
                  }) else {
                return
            }
            semaphore.signal()
        }
        monitor.start(queue: queue)
        defer { monitor.cancel() }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
