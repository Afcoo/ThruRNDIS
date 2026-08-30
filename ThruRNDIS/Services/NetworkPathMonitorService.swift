/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import Network

@MainActor
final class NetworkPathMonitorService {
    var onPathChange: (() -> Void)?

    private let queue = DispatchQueue(
        label: "ThruRNDIS.NetworkPathMonitor"
    )
    private var monitor: NWPathMonitor?
    private var monitoringGeneration: UInt64 = 0
    private var hasReceivedInitialPath = false

    func start() {
        guard monitor == nil else { return }

        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        hasReceivedInitialPath = false

        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.pathDidUpdate(generation: generation)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitoringGeneration &+= 1
        hasReceivedInitialPath = false
        let monitor = self.monitor
        self.monitor = nil
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
    }

    private func pathDidUpdate(generation: UInt64) {
        guard monitoringGeneration == generation else {
            return
        }
        guard hasReceivedInitialPath else {
            hasReceivedInitialPath = true
            return
        }
        onPathChange?()
    }
}
