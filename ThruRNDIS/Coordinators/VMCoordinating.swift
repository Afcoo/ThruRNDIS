/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
@preconcurrency import Virtualization

@MainActor
protocol VMCoordinating: AnyObject {
    var onStateChange: ((VMRuntimeState, String) -> Void)? { get set }
    var onEventLog: ((String) -> Void)? { get set }
    var onConsoleOutput: ((Data) -> Void)? { get set }
    var onUSBPassthroughDisconnect: ((VZUSBPassthroughDevice) -> Void)? { get set }
    var onStopped: (() -> Void)? { get set }

    var runtimeState: VMRuntimeState { get }
    var virtualMachine: VZVirtualMachine? { get }
    var canStop: Bool { get }
    var canRestart: Bool { get }
    var canSendConsoleInput: Bool { get }
    var canStart: Bool { get }
    var hasVirtualMachine: Bool { get }

    func start(input: VMCoordinatorStartInput)
    func stop()
    func stopAndWaitUntilStopped() async -> Bool
    func restart(reason: String, startAgain: @escaping () -> Void)
    func sendConsoleBytes(_ data: Data) -> Bool
    func invalidate()
}

extension VMCoordinator: VMCoordinating {}
