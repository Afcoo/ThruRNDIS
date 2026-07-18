/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation
@preconcurrency import Virtualization

struct VMCoordinatorStartInput {
    let kernelURL: URL
    let initialRamdiskURL: URL
    let diskImageURL: URL?
    let wireGuardConfigurationDirectoryURL: URL
    let cpuCount: Int
    let memorySizeMiB: Int
    let bootCommandLine: String
    let guestMACAddress: String
}

@MainActor
final class VMCoordinator {
    var onStateChange: ((VMRuntimeState, String) -> Void)?
    var onEventLog: ((String) -> Void)?
    var onConsoleOutput: ((Data) -> Void)?
    var onUSBPassthroughDisconnect: ((VZUSBPassthroughDevice) -> Void)?
    var onStopped: (() -> Void)?

    private(set) var runtimeState: VMRuntimeState = .idle
    private(set) var virtualMachine: VZVirtualMachine?

    private var vmDelegate: VirtualMachineDelegateBox?
    private var usbDelegate: USBControllerDelegateBox?
    private var runtimeResources: VMRuntimeResources?
    private var hasReceivedConsoleOutput = false
    private var isRestarting = false
    private var restartContinuation: (() -> Void)?
    private var stopContinuations: [CheckedContinuation<Bool, Never>] = []
    private var generation: UInt64 = 0
    private var consoleOutputWatchdogTask: Task<Void, Never>?

    var canStop: Bool {
        virtualMachine != nil
            && (runtimeState == .running || runtimeState == .starting || runtimeState == .failed)
    }

    var canRestart: Bool {
        (runtimeState == .running || runtimeState == .starting) && !isRestarting
    }

    var canSendConsoleInput: Bool {
        runtimeState == .running && (runtimeResources?.consoleInputPipe.fileHandleForWriting.fileDescriptor ?? -1) >= 0
    }

    var canStart: Bool {
        virtualMachine == nil
            && (runtimeState == .idle || runtimeState == .stopped || runtimeState == .failed)
    }

    var hasVirtualMachine: Bool {
        virtualMachine != nil
    }

    func start(input: VMCoordinatorStartInput) {
        guard runtimeState != .starting,
              runtimeState != .running,
              runtimeState != .stopping else {
            onEventLog?("VM start ignored while VM state is \(runtimeState.rawValue).")
            return
        }

        releaseRuntimeResources()
        cancelConsoleOutputWatchdog()
        hasReceivedConsoleOutput = false
        generation &+= 1
        let generation = self.generation

        do {
            let configurationInput = VMConfigurationInput(
                kernelURL: input.kernelURL,
                initialRamdiskURL: input.initialRamdiskURL,
                diskImageURL: input.diskImageURL,
                wireGuardConfigurationDirectoryURL: input.wireGuardConfigurationDirectoryURL,
                cpuCount: input.cpuCount,
                memorySizeBytes: UInt64(input.memorySizeMiB) * 1024 * 1024,
                bootCommandLine: input.bootCommandLine,
                guestMACAddress: input.guestMACAddress
            )

            let result = try VMConfigurationFactory.build(input: configurationInput)
            installConsoleReader(result.resources.consoleOutputPipe, generation: generation)

            let virtualMachine = VZVirtualMachine(configuration: result.configuration)
            let delegate = makeDelegate(generation: generation)
            let usbDelegate = makeUSBDelegate(for: virtualMachine, generation: generation)
            virtualMachine.delegate = delegate
            virtualMachine.usbControllers.forEach { $0.delegate = usbDelegate }

            self.virtualMachine = virtualMachine
            self.vmDelegate = delegate
            self.usbDelegate = usbDelegate
            self.runtimeResources = result.resources
            transition(to: .starting, message: String(localized: "Starting VM."))
            onEventLog?("Starting ephemeral Alpine ThruRNDIS guest with NAT setup NIC, USB RNDIS upstream, and WireGuard peer support.")

            virtualMachine.start { [weak self] startResult in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isCurrent(virtualMachine, generation: generation) else {
                        self.onEventLog?("Ignoring stale VM start completion from an earlier VM generation.")
                        return
                    }

                    guard self.runtimeState == .starting else {
                        self.onEventLog?("Ignoring VM start completion while VM state is \(self.runtimeState.rawValue).")
                        return
                    }

                    switch startResult {
                    case .success:
                        self.transition(to: .running, message: String(localized: "VM running."))
                        self.onEventLog?("VM started.")
                        self.scheduleConsoleOutputWatchdog(generation: generation)
                    case .failure(let error):
                        self.transition(to: .failed, message: error.localizedDescription)
                        self.onEventLog?(
                            "VM start failed: " + EventLogErrorFormatter.description(for: error)
                        )
                        self.generation &+= 1
                        self.virtualMachine = nil
                        self.vmDelegate = nil
                        self.usbDelegate = nil
                        self.releaseRuntimeResources()
                    }
                }
            }
        } catch {
            transition(to: .failed, message: error.localizedDescription)
            onEventLog?(
                "VM configuration failed: " + EventLogErrorFormatter.description(for: error)
            )
        }
    }

    func stop() {
        guard let virtualMachine else {
            return
        }
        let generation = self.generation

        transition(to: .stopping, message: String(localized: "Stopping VM."))
        onEventLog?("Stopping VM.")

        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrent(virtualMachine, generation: generation) else {
                    self.onEventLog?("Ignoring stale VM stop completion from an earlier VM generation.")
                    return
                }

                if let error {
                    self.transition(to: .failed, message: error.localizedDescription)
                    self.onEventLog?(
                        "VM stop failed: " + EventLogErrorFormatter.description(for: error)
                    )
                    self.resolveStopContinuations(didStop: false)
                } else {
                    self.markStopped(
                        message: String(localized: "VM stopped."),
                        eventMessage: "VM stopped."
                    )
                }
            }
        }
    }

    func stopAndWaitUntilStopped() async -> Bool {
        guard virtualMachine != nil else {
            return true
        }

        isRestarting = false
        restartContinuation = nil

        return await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
            guard runtimeState != .stopping else {
                return
            }
            stop()
        }
    }

    func restart(reason: String, startAgain: @escaping () -> Void) {
        guard let virtualMachine else {
            onEventLog?("VM restart skipped: VM is not available (\(reason)).")
            return
        }

        guard runtimeState == .running || runtimeState == .starting else {
            onEventLog?("VM restart skipped while VM state is \(runtimeState.rawValue): \(reason).")
            return
        }

        guard !isRestarting else {
            onEventLog?("VM restart already pending: \(reason).")
            return
        }
        let generation = self.generation

        isRestarting = true
        restartContinuation = startAgain
        transition(to: .stopping, message: String(localized: "Restarting VM."))
        onEventLog?("Restarting VM to recreate the fixed usb0 RNDIS session (\(reason)).")

        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrent(virtualMachine, generation: generation) else {
                    self.onEventLog?("Ignoring stale VM restart completion from an earlier VM generation.")
                    return
                }

                if let error {
                    self.isRestarting = false
                    self.restartContinuation = nil
                    self.transition(to: .failed, message: error.localizedDescription)
                    self.onEventLog?(
                        "VM restart failed while stopping VM: " +
                            EventLogErrorFormatter.description(for: error)
                    )
                    self.resolveStopContinuations(didStop: false)
                    return
                }

                self.markStopped(
                    message: String(localized: "VM stopped for restart."),
                    eventMessage: "VM stopped for restart."
                )
            }
        }
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        guard !data.isEmpty else {
            return true
        }

        guard canSendConsoleInput else {
            onEventLog?("Console input not sent: VM console input is unavailable.")
            return false
        }

        return writeConsolePayload(data, failureContext: "Console input")
    }

    func invalidate() {
        generation &+= 1
        isRestarting = false
        restartContinuation = nil
        virtualMachine = nil
        vmDelegate = nil
        usbDelegate = nil
        releaseRuntimeResources()
        resolveStopContinuations(didStop: false)
    }

    private func makeDelegate(generation: UInt64) -> VirtualMachineDelegateBox {
        let delegate = VirtualMachineDelegateBox()

        delegate.onGuestDidStop = { [weak self] callbackVirtualMachine in
            Task { @MainActor in
                guard let self,
                      self.isCurrent(callbackVirtualMachine, generation: generation) else {
                    return
                }
                self.markStopped(
                    message: String(localized: "Guest shut down."),
                    eventMessage: "Guest shut down."
                )
            }
        }

        delegate.onStopError = { [weak self] callbackVirtualMachine, error in
            Task { @MainActor in
                guard let self,
                      self.isCurrent(callbackVirtualMachine, generation: generation) else {
                    return
                }

                self.isRestarting = false
                self.restartContinuation = nil
                self.transition(to: .failed, message: error.localizedDescription)
                self.generation &+= 1
                self.releaseRuntimeResources()
                self.virtualMachine = nil
                self.vmDelegate = nil
                self.usbDelegate = nil
                self.onStopped?()
                self.resolveStopContinuations(didStop: true)
                self.onEventLog?(
                    "VM stopped with error: " + EventLogErrorFormatter.description(for: error)
                )
            }
        }

        delegate.onNetworkDisconnect = { [weak self] callbackVirtualMachine, error in
            Task { @MainActor in
                guard let self,
                      self.isCurrent(callbackVirtualMachine, generation: generation) else {
                    return
                }
                self.onEventLog?(
                    "VM network attachment disconnected: " +
                        EventLogErrorFormatter.description(for: error)
                )
            }
        }

        return delegate
    }

    private func makeUSBDelegate(
        for virtualMachine: VZVirtualMachine,
        generation: UInt64
    ) -> USBControllerDelegateBox {
        let delegate = USBControllerDelegateBox()

        delegate.onUSBPassthroughDisconnect = { [weak self, weak virtualMachine] device in
            Task { @MainActor in
                guard let self, let virtualMachine,
                      self.isCurrent(virtualMachine, generation: generation) else {
                    return
                }
                self.onUSBPassthroughDisconnect?(device)
            }
        }

        return delegate
    }

    private func markStopped(message: String, eventMessage: String) {
        let continuation = restartContinuation
        restartContinuation = nil
        isRestarting = false
        generation &+= 1
        virtualMachine = nil
        vmDelegate = nil
        usbDelegate = nil
        releaseRuntimeResources()
        transition(to: .stopped, message: message)
        onStopped?()
        onEventLog?(eventMessage)
        resolveStopContinuations(didStop: true)
        continuation?()
    }

    private func resolveStopContinuations(didStop: Bool) {
        let continuations = stopContinuations
        stopContinuations.removeAll()
        continuations.forEach { $0.resume(returning: didStop) }
    }

    private func installConsoleReader(_ pipe: Pipe, generation: UInt64) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                Task { @MainActor in
                    guard let self else { return }
                    guard self.generation == generation else { return }
                    let message = self.hasReceivedConsoleOutput
                        ? "Console output pipe closed."
                        : "Console output pipe closed before any data was received."
                    self.onEventLog?(message)
                }
                return
            }

            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.appendConsole(data)
            }
        }
    }

    private func appendConsole(_ data: Data) {
        if !hasReceivedConsoleOutput {
            hasReceivedConsoleOutput = true
            cancelConsoleOutputWatchdog()
            onEventLog?("Console output started: first read \(data.count) byte(s).")
        }

        onConsoleOutput?(data)
    }

    private func writeConsolePayload(_ payload: Data, failureContext: String) -> Bool {
        guard let inputPipe = runtimeResources?.consoleInputPipe else {
            onEventLog?("\(failureContext) not sent: VM console input is unavailable.")
            return false
        }

        let fileDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
        var offset = 0

        let success = payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return true
            }

            while offset < rawBuffer.count {
                let written = Darwin.write(fileDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written <= 0 {
                    return false
                }

                offset += written
            }

            return true
        }

        if !success {
            onEventLog?("\(failureContext) write failed: errno \(errno).")
            return false
        }

        return true
    }

    private func releaseRuntimeResources() {
        cancelConsoleOutputWatchdog()
        runtimeResources?.consoleOutputPipe.fileHandleForReading.readabilityHandler = nil
        runtimeResources = nil
    }

    private func scheduleConsoleOutputWatchdog(generation: UInt64) {
        cancelConsoleOutputWatchdog()
        consoleOutputWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            guard self.generation == generation else { return }
            guard self.runtimeState == .running, !self.hasReceivedConsoleOutput else { return }

            self.onEventLog?("No VM console output received after 15s. Selected kernel/initramfs assets are logged above; confirm the installed release contains Image-lts and initramfs-thrurndis-lts.")
        }
    }

    private func cancelConsoleOutputWatchdog() {
        consoleOutputWatchdogTask?.cancel()
        consoleOutputWatchdogTask = nil
    }

    private func transition(to state: VMRuntimeState, message: String) {
        runtimeState = state
        onStateChange?(state, message)
    }

    private func isCurrent(_ virtualMachine: VZVirtualMachine, generation: UInt64) -> Bool {
        self.virtualMachine === virtualMachine && self.generation == generation
    }
}

private final class VirtualMachineDelegateBox: NSObject, VZVirtualMachineDelegate {
    var onGuestDidStop: ((VZVirtualMachine) -> Void)?
    var onStopError: ((VZVirtualMachine, Error) -> Void)?
    var onNetworkDisconnect: ((VZVirtualMachine, Error) -> Void)?

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { [weak self] in
            self?.onGuestDidStop?(virtualMachine)
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStopError?(virtualMachine, error)
        }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onNetworkDisconnect?(virtualMachine, error)
        }
    }
}

private final class USBControllerDelegateBox: NSObject, VZUSBController.Delegate {
    var onUSBPassthroughDisconnect: ((VZUSBPassthroughDevice) -> Void)?

    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.onUSBPassthroughDisconnect?(device)
        }
    }
}
