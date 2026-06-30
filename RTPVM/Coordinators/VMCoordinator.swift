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
    let cpuCount: Int
    let memorySizeMiB: Int
    let bootCommandLine: String
    let guestMACAddress: String
}

@MainActor
final class VMCoordinator {
    var onStateChange: ((VMRuntimeState, String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onConsoleOutput: ((Data) -> Void)?
    var onUSBPassthroughDisconnect: (() -> Void)?
    var onStopped: (() -> Void)?

    private(set) var runtimeState: VMRuntimeState = .idle
    private(set) var virtualMachine: VZVirtualMachine?

    private var vmDelegate: VirtualMachineDelegateBox?
    private var usbDelegate: USBControllerDelegateBox?
    private var runtimeResources: VMRuntimeResources?
    private var hasReceivedConsoleOutput = false
    private var isRestartingAfterUSBDetach = false
    private var consoleOutputWatchdogTask: Task<Void, Never>?

    var canStop: Bool {
        runtimeState == .running || runtimeState == .starting
    }

    var canSendConsoleInput: Bool {
        runtimeState == .running && (runtimeResources?.consoleInputPipe.fileHandleForWriting.fileDescriptor ?? -1) >= 0
    }

    func start(input: VMCoordinatorStartInput) {
        releaseRuntimeResources()
        cancelConsoleOutputWatchdog()
        hasReceivedConsoleOutput = false

        do {
            let configurationInput = VMConfigurationInput(
                kernelURL: input.kernelURL,
                initialRamdiskURL: input.initialRamdiskURL,
                diskImageURL: input.diskImageURL,
                cpuCount: input.cpuCount,
                memorySizeBytes: UInt64(input.memorySizeMiB) * 1024 * 1024,
                bootCommandLine: input.bootCommandLine,
                guestMACAddress: input.guestMACAddress
            )

            let result = try VMConfigurationFactory.build(input: configurationInput)
            installConsoleReader(result.resources.consoleOutputPipe)

            let virtualMachine = VZVirtualMachine(configuration: result.configuration)
            let delegate = makeDelegate()
            let usbDelegate = makeUSBDelegate()
            virtualMachine.delegate = delegate
            virtualMachine.usbControllers.forEach { $0.delegate = usbDelegate }

            self.virtualMachine = virtualMachine
            self.vmDelegate = delegate
            self.usbDelegate = usbDelegate
            self.runtimeResources = result.resources
            transition(to: .starting, message: "Starting VM.")
            onEvent?("Starting ephemeral Alpine RTPVM guest with NAT setup NIC, USB RNDIS upstream, and WireGuard peer support.")

            virtualMachine.start { [weak self] startResult in
                Task { @MainActor in
                    guard let self else { return }

                    switch startResult {
                    case .success:
                        self.transition(to: .running, message: "VM running.")
                        self.onEvent?("VM started.")
                        self.scheduleConsoleOutputWatchdog()
                    case .failure(let error):
                        self.transition(to: .failed, message: error.localizedDescription)
                        self.onEvent?("VM start failed: \(error.localizedDescription)")
                        self.virtualMachine = nil
                        self.vmDelegate = nil
                        self.usbDelegate = nil
                        self.releaseRuntimeResources()
                    }
                }
            }
        } catch {
            transition(to: .failed, message: error.localizedDescription)
            onEvent?("VM configuration failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let virtualMachine else {
            return
        }

        transition(to: .stopping, message: "Stopping VM.")
        onEvent?("Stopping VM.")

        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.transition(to: .failed, message: error.localizedDescription)
                    self.onEvent?("VM stop failed: \(error.localizedDescription)")
                } else {
                    self.markStopped(message: "VM stopped.")
                }
            }
        }
    }

    func restartAfterUSBDetach(reason: String, startAgain: @escaping () -> Void) {
        guard let virtualMachine else {
            onEvent?("USB detach restart skipped: VM is not available (\(reason)).")
            return
        }

        guard runtimeState == .running || runtimeState == .starting else {
            onEvent?("USB detach restart skipped while VM state is \(runtimeState.rawValue): \(reason).")
            return
        }

        guard !isRestartingAfterUSBDetach else {
            onEvent?("USB detach restart already pending: \(reason).")
            return
        }

        isRestartingAfterUSBDetach = true
        transition(to: .stopping, message: "USB detached; restarting VM.")
        onEvent?("USB detach policy: restarting VM to recreate the fixed usb0 RNDIS session (\(reason)).")

        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isRestartingAfterUSBDetach = false
                    self.transition(to: .failed, message: error.localizedDescription)
                    self.releaseRuntimeResources()
                    self.onEvent?("VM restart after USB detach failed while stopping VM: \(error.localizedDescription)")
                    return
                }

                self.markStopped(message: "VM stopped after USB detach.")
                self.isRestartingAfterUSBDetach = false
                startAgain()
            }
        }
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        guard !data.isEmpty else {
            return true
        }

        guard canSendConsoleInput else {
            onEvent?("Console input not sent: VM console input is unavailable.")
            return false
        }

        return writeConsolePayload(data, failureContext: "Console input")
    }

    func invalidate() {
        releaseRuntimeResources()
    }

    private func makeDelegate() -> VirtualMachineDelegateBox {
        let delegate = VirtualMachineDelegateBox()

        delegate.onGuestDidStop = { [weak self] in
            Task { @MainActor in
                self?.markStopped(message: "Guest shut down.")
            }
        }

        delegate.onStopError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                self.isRestartingAfterUSBDetach = false
                self.transition(to: .failed, message: error.localizedDescription)
                self.releaseRuntimeResources()
                self.virtualMachine = nil
                self.vmDelegate = nil
                self.usbDelegate = nil
                self.onEvent?("VM stopped with error: \(error.localizedDescription)")
            }
        }

        delegate.onNetworkDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.onEvent?("VM network attachment disconnected: \(error.localizedDescription)")
            }
        }

        return delegate
    }

    private func makeUSBDelegate() -> USBControllerDelegateBox {
        let delegate = USBControllerDelegateBox()

        delegate.onUSBPassthroughDisconnect = { [weak self] in
            Task { @MainActor in
                self?.onUSBPassthroughDisconnect?()
            }
        }

        return delegate
    }

    private func markStopped(message: String) {
        transition(to: .stopped, message: message)
        virtualMachine = nil
        vmDelegate = nil
        usbDelegate = nil
        releaseRuntimeResources()
        onStopped?()
        onEvent?(message)
    }

    private func installConsoleReader(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                Task { @MainActor in
                    guard let self else { return }
                    let message = self.hasReceivedConsoleOutput
                        ? "Console output pipe closed."
                        : "Console output pipe closed before any data was received."
                    self.onEvent?(message)
                }
                return
            }

            Task { @MainActor in
                self?.appendConsole(data)
            }
        }
    }

    private func appendConsole(_ data: Data) {
        if !hasReceivedConsoleOutput {
            hasReceivedConsoleOutput = true
            cancelConsoleOutputWatchdog()
            onEvent?("Console output started: first read \(data.count) byte(s).")
        }

        onConsoleOutput?(data)
    }

    private func writeConsolePayload(_ payload: Data, failureContext: String) -> Bool {
        guard let inputPipe = runtimeResources?.consoleInputPipe else {
            onEvent?("\(failureContext) not sent: VM console input is unavailable.")
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
            onEvent?("\(failureContext) write failed: errno \(errno).")
            return false
        }

        return true
    }

    private func releaseRuntimeResources() {
        cancelConsoleOutputWatchdog()
        runtimeResources?.consoleOutputPipe.fileHandleForReading.readabilityHandler = nil
        runtimeResources = nil
    }

    private func scheduleConsoleOutputWatchdog() {
        cancelConsoleOutputWatchdog()
        consoleOutputWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            guard self.runtimeState == .running, !self.hasReceivedConsoleOutput else { return }

            self.onEvent?("No VM console output received after 15s. Selected kernel/initramfs assets are logged above; confirm the kernel is Image-lts and the initramfs is initramfs-rtpvm-lts regenerated after the latest script changes.")
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
}

private final class VirtualMachineDelegateBox: NSObject, VZVirtualMachineDelegate {
    var onGuestDidStop: (() -> Void)?
    var onStopError: ((Error) -> Void)?
    var onNetworkDisconnect: ((Error) -> Void)?

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { [weak self] in
            self?.onGuestDidStop?()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStopError?(error)
        }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onNetworkDisconnect?(error)
        }
    }
}

private final class USBControllerDelegateBox: NSObject, VZUSBController.Delegate {
    var onUSBPassthroughDisconnect: (() -> Void)?

    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.onUSBPassthroughDisconnect?()
        }
    }
}
