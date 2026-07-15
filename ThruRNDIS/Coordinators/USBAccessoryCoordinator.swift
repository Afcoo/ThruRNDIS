/*
Copyright (C) 2026 Afcoo.
*/

import AccessoryAccess
import Foundation
@preconcurrency import Virtualization

private enum USBPassthroughPolicy {
    static let attachFailureSuppressionInterval: TimeInterval = 10
    static let manualDetachAccessoryEventGraceInterval: TimeInterval = 10
}

@MainActor
final class USBAccessoryCoordinator {
    var onStateChange: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var onEventLog: ((String) -> Void)?
    var onAccessoryAvailable: ((USBAccessoryRecord) -> Void)?
    var onAccessoryUnavailable: ((UInt64) -> Void)?
    var onUnexpectedDetach: ((UInt64, String) -> Void)?
    var runtimeStateProvider: (() -> VMRuntimeState)?

    private let monitor: any USBAccessoryMonitoring
    private var accessoryObjects: [UInt64: AAUSBAccessory] = [:]
    private var attachedDevice: VZUSBPassthroughDevice?
    private var pendingDetachDevice: VZUSBPassthroughDevice?
    private var accessoryEventSequence = 0
    private var pendingAttachAccessoryID: UInt64?
    private var pendingAttachToken: UUID?
    private var lastAccessoryEventByDescriptor: [String: (kind: String, date: Date)] = [:]
    private var lastAttachAttemptByDescriptor: [String: Date] = [:]
    private var attachSuppressedUntilByDescriptor: [String: Date] = [:]
    private var manuallyDetachedDescriptorKeys: Set<String> = []
    private var manualDetachEventSuppressedUntilByDescriptor: [String: Date] = [:]
    private var manualDetachEventSuppressedUntilByRegistryID: [UInt64: Date] = [:]
    private var manualPassthroughDisconnectSuppressedUntil: Date?
    private var reconnectDescriptorKey: String?
    private var announcedAccessoryIDs: Set<UInt64> = []
    private var isIntentionalVMStopInProgress = false
    private var isRegistrationPending = false
    private var isUnregistrationPending = false
    private var isReloadInProgress = false

    private(set) var accessories: [USBAccessoryRecord] = []
    private(set) var isAccessoryMonitoring = false
    private(set) var selectedAccessoryID: UInt64?
    private(set) var attachedAccessoryID: UInt64?
    private(set) var vmSessionAccessoryID: UInt64?

    init(monitor: any USBAccessoryMonitoring) {
        self.monitor = monitor
        configureAccessoryMonitor()
    }

    var canStartMonitoring: Bool {
        !isAccessoryMonitoring
            && !isRegistrationPending
            && !isUnregistrationPending
            && !isReloadInProgress
    }

    var canStopMonitoring: Bool {
        isAccessoryMonitoring && !isReloadInProgress && pendingDetachDevice == nil
    }

    var canReloadMonitoring: Bool {
        isAccessoryMonitoring
            && !isRegistrationPending
            && !isUnregistrationPending
            && !isReloadInProgress
            && pendingDetachDevice == nil
    }

    var isDetachPending: Bool {
        pendingDetachDevice != nil
    }

    func canRequestAttachment(for accessoryID: UInt64) -> Bool {
        guard let record = accessories.first(where: { $0.id == accessoryID }),
              record.hasConfigurationDescriptor,
              accessoryObjects[accessoryID] != nil,
              pendingAttachAccessoryID == nil,
              pendingDetachDevice == nil,
              attachedAccessoryID != accessoryID else {
            return false
        }

        return attachSuppressionRemaining(for: record) == nil
    }

    func canDetachAccessory(runtimeState: VMRuntimeState) -> Bool {
        runtimeState == .running
            && attachedDevice != nil
            && pendingDetachDevice == nil
            && !isRegistrationPending
            && !isUnregistrationPending
            && !isReloadInProgress
    }

    func selectAccessory(id: UInt64?) {
        selectedAccessoryID = id
        notifyStateChanged()
    }

    func startMonitoring(reason: String, completion: (() -> Void)? = nil) {
        guard !isAccessoryMonitoring, !isRegistrationPending else {
            onEventLog?("USB listener already active: \(reason).")
            completion?()
            return
        }

        isRegistrationPending = true
        isAccessoryMonitoring = true
        notifyStateChanged()
        onEventLog?("Registering AccessoryAccess USB listener: \(reason).")

        monitor.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRegistrationPending = false

                switch result {
                case .success(let connectedAccessories):
                    guard self.isAccessoryMonitoring else {
                        self.isUnregistrationPending = true
                        self.onEventLog?("USB listener registration ignored because listener was stopped.")
                        self.notifyStateChanged()
                        self.monitor.stop { [weak self] in
                            Task { @MainActor in
                                self?.isUnregistrationPending = false
                                self?.notifyStateChanged()
                                completion?()
                            }
                        }
                        return
                    }

                    connectedAccessories.forEach { self.addAccessory($0) }
                    self.onStatusMessage?(String(localized: "USB listener registered."))
                    self.onEventLog?("USB listener registered with \(connectedAccessories.count) existing device(s).")
                    self.notifyStateChanged()
                    completion?()
                case .failure(let error):
                    self.isAccessoryMonitoring = false
                    self.onStatusMessage?(error.localizedDescription)
                    self.onEventLog?("USB listener failed: \(error.localizedDescription)")
                    self.notifyStateChanged()
                    completion?()
                }
            }
        }
    }

    func stopMonitoring(reason: String, completion: (() -> Void)? = nil) {
        guard isAccessoryMonitoring || !accessoryObjects.isEmpty || !accessories.isEmpty else {
            completion?()
            return
        }

        isAccessoryMonitoring = false
        isUnregistrationPending = true
        accessoryObjects.removeAll()
        accessories.removeAll()
        selectedAccessoryID = nil
        manuallyDetachedDescriptorKeys.removeAll()
        manualDetachEventSuppressedUntilByDescriptor.removeAll()
        manualDetachEventSuppressedUntilByRegistryID.removeAll()
        manualPassthroughDisconnectSuppressedUntil = nil
        reconnectDescriptorKey = nil
        announcedAccessoryIDs.removeAll()
        notifyStateChanged()

        monitor.stop { [weak self] in
            Task { @MainActor in
                self?.onEventLog?("AccessoryAccess USB listener stopped: \(reason)")
                self?.isUnregistrationPending = false
                self?.notifyStateChanged()
                completion?()
            }
        }
    }

    func reloadMonitoring(reason: String) {
        guard canReloadMonitoring else {
            onEventLog?("USB listener reload ignored while another listener transition is active.")
            return
        }

        isReloadInProgress = true
        notifyStateChanged()
        stopMonitoring(reason: "Reloading USB listener: \(reason)") { [weak self] in
            guard let self else { return }
            self.startMonitoring(reason: "reload after \(reason)") { [weak self] in
                guard let self else { return }
                self.isReloadInProgress = false
                self.onEventLog?("AccessoryAccess USB listener reload completed: \(reason).")
                self.notifyStateChanged()
            }
        }
    }

    func prepareForIntentionalVMStop() {
        isIntentionalVMStopInProgress = true
    }

    func resetForVMStart() {
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingDetachDevice = nil
        pendingAttachAccessoryID = nil
        pendingAttachToken = nil
        lastAttachAttemptByDescriptor.removeAll()
        attachSuppressedUntilByDescriptor.removeAll()
        manuallyDetachedDescriptorKeys.removeAll()
        manualDetachEventSuppressedUntilByDescriptor.removeAll()
        manualDetachEventSuppressedUntilByRegistryID.removeAll()
        manualPassthroughDisconnectSuppressedUntil = nil
        reconnectDescriptorKey = nil
        vmSessionAccessoryID = nil
        isIntentionalVMStopInProgress = false
        notifyStateChanged()
    }

    func clearAttachmentForStoppedVM() {
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingDetachDevice = nil
        pendingAttachAccessoryID = nil
        pendingAttachToken = nil
        reconnectDescriptorKey = nil
        vmSessionAccessoryID = nil
        isIntentionalVMStopInProgress = false
        notifyStateChanged()
    }

    func attachAccessory(
        id accessoryID: UInt64,
        to virtualMachine: VZVirtualMachine?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let virtualMachine else {
            onStatusMessage?(String(localized: "Start the VM before attaching USB."))
            completion?(false)
            return
        }
        guard let accessory = accessoryObjects[accessoryID] else {
            onStatusMessage?(String(localized: "The selected USB accessory is no longer available."))
            completion?(false)
            return
        }

        let record = USBAccessoryRecord(accessory: accessory)
        guard record.hasConfigurationDescriptor else {
            onStatusMessage?(String(localized: "USB descriptor is incomplete."))
            onEventLog?("USB attach not started for registry \(record.registryIDText): AccessoryAccess reported no configuration descriptor. Reconnect the device after enabling USB tethering, then attach when the configuration and interfaces appear.")
            completion?(false)
            return
        }

        if let remaining = attachSuppressionRemaining(for: record) {
            onStatusMessage?(String(localized: "USB attach cooling down."))
            onEventLog?("USB attach not started for registry \(record.registryIDText): retry allowed in \(Self.secondsText(remaining)).")
            completion?(false)
            return
        }

        manuallyDetachedDescriptorKeys.remove(record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByDescriptor.removeValue(forKey: record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByRegistryID.removeValue(forKey: accessoryID)
        reconnectDescriptorKey = nil
        selectedAccessoryID = accessoryID
        attach(
            accessory,
            record: record,
            to: virtualMachine,
            reason: "approved request",
            completion: completion
        )
    }

    func detachAccessory(
        from virtualMachine: VZVirtualMachine?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let virtualMachine, let device = attachedDevice else {
            completion?(false)
            return
        }

        guard let controller = virtualMachine.usbControllers.first else {
            completion?(false)
            return
        }

        guard pendingDetachDevice == nil else {
            onEventLog?("USB detach ignored because a detach is already pending.")
            completion?(false)
            return
        }

        let detachedAccessoryID = attachedAccessoryID
        let detachedRecord = detachedAccessoryID.flatMap { id in
            accessories.first { $0.id == id }
        }

        if let detachedRecord {
            noteManualDetach(for: detachedRecord)
        }
        manualPassthroughDisconnectSuppressedUntil = Date().addingTimeInterval(USBPassthroughPolicy.manualDetachAccessoryEventGraceInterval)
        pendingDetachDevice = device
        notifyStateChanged()

        controller.detach(device: device) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                guard self.pendingDetachDevice === device else {
                    self.onEventLog?("Ignoring stale USB detach completion from an earlier attachment.")
                    completion?(false)
                    return
                }

                self.pendingDetachDevice = nil

                if let error {
                    if let detachedRecord {
                        self.manuallyDetachedDescriptorKeys.remove(detachedRecord.descriptorIdentityKey)
                        self.manualDetachEventSuppressedUntilByDescriptor.removeValue(forKey: detachedRecord.descriptorIdentityKey)
                        self.manualDetachEventSuppressedUntilByRegistryID.removeValue(forKey: detachedRecord.id)
                    }
                    self.manualPassthroughDisconnectSuppressedUntil = nil
                    self.onStatusMessage?(error.localizedDescription)
                    self.onEventLog?("USB detach failed: \(error.localizedDescription)")
                } else {
                    self.attachedAccessoryID = nil
                    self.attachedDevice = nil
                    self.onStatusMessage?(String(localized: "USB accessory detached from VM."))
                    self.onEventLog?("USB accessory detached from VM by user.")
                }
                self.notifyStateChanged()
                completion?(error == nil)
            }
        }
    }

    func handlePassthroughDisconnect(device: VZUSBPassthroughDevice) {
        guard let attachedDevice else {
            onEventLog?("Ignoring stale USB passthrough disconnect because no device is attached.")
            return
        }

        guard attachedDevice === device else {
            onEventLog?("Ignoring stale USB passthrough disconnect from an earlier VM or attachment.")
            return
        }

        let disconnectedAccessoryID = attachedAccessoryID
        let attachedRegistry = disconnectedAccessoryID.map(Self.registryIDText) ?? "none"
        let reconnectRecord = attachedAccessoryID.flatMap { id in
            accessories.first { $0.id == id }
        }
        if isManualPassthroughDisconnectSuppressed() || isIntentionalVMStopInProgress {
            attachedAccessoryID = nil
            self.attachedDevice = nil
            notifyStateChanged()
            onEventLog?("USB passthrough disconnect ignored because it was produced by an intentional detach or VM stop, attached registry \(attachedRegistry).")
            return
        }

        attachedAccessoryID = nil
        self.attachedDevice = nil
        if let reconnectRecord {
            reconnectDescriptorKey = reconnectRecord.descriptorIdentityKey
        }
        notifyStateChanged()
        let reason = "USB passthrough device disconnected by the system, attached registry \(attachedRegistry)."
        onEventLog?(reason)
        if let disconnectedAccessoryID {
            onUnexpectedDetach?(disconnectedAccessoryID, reason)
        }
    }

    private func configureAccessoryMonitor() {
        monitor.onConnect = { [weak self] accessory in
            Task { @MainActor in
                self?.addAccessory(accessory)
            }
        }

        monitor.onDisconnect = { [weak self] accessory in
            Task { @MainActor in
                self?.removeAccessory(accessory)
            }
        }
    }

    private func attach(
        _ accessory: AAUSBAccessory,
        record: USBAccessoryRecord,
        to virtualMachine: VZVirtualMachine,
        reason: String,
        completion: ((Bool) -> Void)?
    ) {
        let registryID = accessory.registryID
        let descriptorKey = record.descriptorIdentityKey

        guard pendingDetachDevice == nil else {
            onEventLog?("USB attach skipped while a detach is pending.")
            completion?(false)
            return
        }

        if let vmSessionAccessoryID, vmSessionAccessoryID != registryID {
            onStatusMessage?(String(localized: "Restart the VM before attaching a different USB accessory."))
            onEventLog?("USB attach skipped for registry \(record.registryIDText): this VM session is reserved for registry \(Self.registryIDText(vmSessionAccessoryID)).")
            completion?(false)
            return
        }

        guard attachedAccessoryID == nil, attachedDevice == nil else {
            let attachedRegistry = attachedAccessoryID.map(Self.registryIDText) ?? "unknown"
            onStatusMessage?(String(localized: "Only one USB passthrough accessory is supported per VM session."))
            onEventLog?("USB attach skipped for registry \(record.registryIDText): single passthrough device limit is already active with registry \(attachedRegistry).")
            completion?(false)
            return
        }

        guard pendingAttachAccessoryID == nil else {
            onEventLog?("USB attach skipped for registry \(record.registryIDText): attach already pending for \(Self.registryIDText(pendingAttachAccessoryID!)).")
            completion?(false)
            return
        }

        let attachToken = UUID()
        pendingAttachAccessoryID = registryID
        pendingAttachToken = attachToken
        lastAttachAttemptByDescriptor[descriptorKey] = Date()
        notifyStateChanged()
        onEventLog?("USB attach requested: \(record.descriptorDiagnosticText), registry \(record.registryIDText), reason=\(reason), vm=\(currentRuntimeState.rawValue), usbControllers=\(virtualMachine.usbControllers.count).")

        do {
            let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
            let device = try VZUSBPassthroughDevice(configuration: configuration)

            guard let controller = virtualMachine.usbControllers.first else {
                pendingAttachAccessoryID = nil
                pendingAttachToken = nil
                notifyStateChanged()
                onStatusMessage?(String(localized: "VM has no USB controller."))
                onEventLog?("USB attach failed: VM has no USB controller for registry \(record.registryIDText).")
                completion?(false)
                return
            }

            controller.attach(device: device) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }

                    guard self.pendingAttachAccessoryID == registryID,
                          self.pendingAttachToken == attachToken else {
                        self.onEventLog?("USB attach completion ignored for registry \(record.registryIDText): attach is no longer current.")
                        completion?(false)
                        return
                    }

                    self.pendingAttachAccessoryID = nil
                    self.pendingAttachToken = nil

                    if let error {
                        self.onStatusMessage?(error.localizedDescription)
                        self.onEventLog?("USB attach failed: \(error.localizedDescription)")
                        self.suppressAttach(
                            for: record,
                            interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                            reason: "VZ USB controller attach failed: \(error.localizedDescription)"
                        )
                    } else {
                        self.attachedAccessoryID = registryID
                        self.attachedDevice = device
                        self.vmSessionAccessoryID = registryID
                        self.onStatusMessage?(String(localized: "USB accessory attached."))
                        self.onEventLog?("USB accessory attached: registry \(record.registryIDText).")
                    }
                    self.notifyStateChanged()
                    completion?(error == nil)
                }
            }
        } catch {
            pendingAttachAccessoryID = nil
            pendingAttachToken = nil
            notifyStateChanged()
            onStatusMessage?(error.localizedDescription)
            onEventLog?("USB passthrough device creation failed for registry \(record.registryIDText): \(error.localizedDescription)")
            suppressAttach(
                for: record,
                interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                reason: "VZ passthrough device creation failed: \(error.localizedDescription)"
            )
            completion?(false)
        }
    }

    private func addAccessory(_ accessory: AAUSBAccessory) {
        accessoryObjects[accessory.registryID] = accessory
        let record = USBAccessoryRecord(accessory: accessory)
        let previousRecord = accessories.first { $0.id == record.id }
        let replacedSelectedRecord = accessories.contains { existingRecord in
            existingRecord.descriptorIdentityKey == record.descriptorIdentityKey
                && selectedAccessoryID == existingRecord.id
        }
        let shouldReconnect = reconnectDescriptorKey == record.descriptorIdentityKey

        if manuallyDetachedDescriptorKeys.contains(record.descriptorIdentityKey) {
            accessories.removeAll { $0.id == record.id || $0.descriptorIdentityKey == record.descriptorIdentityKey }
        } else {
            accessories.removeAll { $0.id == record.id }
        }

        accessories.append(record)
        accessories.sort { $0.usbIDText < $1.usbIDText }
        attachSuppressedUntilByDescriptor.removeValue(forKey: record.descriptorIdentityKey)
        if selectedAccessoryID == nil || replacedSelectedRecord || shouldReconnect {
            selectedAccessoryID = record.id
        }
        if shouldReconnect {
            reconnectDescriptorKey = nil
        }
        notifyStateChanged()
        onEventLog?("USB connected: \(record.descriptorDiagnosticText), registry \(record.registryIDText), \(accessoryEventContext(for: record, kind: "connect")).")

        let becameReady = previousRecord?.hasConfigurationDescriptor != true && record.hasConfigurationDescriptor
        let shouldAnnounce = becameReady
            && attachedAccessoryID != record.id
            && !manuallyDetachedDescriptorKeys.contains(record.descriptorIdentityKey)
            && announcedAccessoryIDs.insert(record.id).inserted

        if shouldAnnounce {
            onAccessoryAvailable?(record)
        }
    }

    private func removeAccessory(_ accessory: AAUSBAccessory) {
        let record = USBAccessoryRecord(accessory: accessory)
        let wasSelected = selectedAccessoryID == accessory.registryID
        let wasAttached = attachedAccessoryID == accessory.registryID

        if manualDetachEventSuppressionRemaining(for: record) != nil {
            accessoryObjects[accessory.registryID] = nil
            notifyStateChanged()
            onEventLog?("USB AccessoryAccess disconnect ignored during manual VM detach: registry \(record.registryIDText), \(accessoryEventContext(for: record, kind: "disconnect")).")
            return
        }

        accessoryObjects[accessory.registryID] = nil
        accessories.removeAll { $0.id == accessory.registryID }
        announcedAccessoryIDs.remove(accessory.registryID)

        if wasSelected {
            selectedAccessoryID = accessories.first?.id
        }

        if wasAttached {
            reconnectDescriptorKey = record.descriptorIdentityKey
            attachedAccessoryID = nil
            attachedDevice = nil
        }

        if pendingAttachAccessoryID == accessory.registryID {
            pendingAttachAccessoryID = nil
            pendingAttachToken = nil
            suppressAttach(
                for: record,
                interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                reason: "device disconnected while VZ attach was pending."
            )
            onEventLog?("USB disconnected while VZ attach was pending for registry \(record.registryIDText).")
        }

        notifyStateChanged()
        let isIntentionalSessionDevice = isIntentionalVMStopInProgress
            && vmSessionAccessoryID == record.id
        if !isIntentionalSessionDevice {
            onAccessoryUnavailable?(record.id)
        }
        onEventLog?("USB disconnected: \(record.descriptorDiagnosticText), registry \(record.registryIDText), wasSelected=\(wasSelected), wasAttached=\(wasAttached), \(accessoryEventContext(for: record, kind: "disconnect")).")

        if wasAttached {
            if isIntentionalVMStopInProgress {
                onEventLog?("USB disconnect matched the attached passthrough accessory during an intentional VM stop.")
            } else {
                let reason = "AccessoryAccess disconnected the attached USB accessory, registry \(record.registryIDText)."
                onEventLog?(reason)
                onUnexpectedDetach?(record.id, reason)
            }
        }
    }

    private func noteManualDetach(for record: USBAccessoryRecord) {
        let suppressedUntil = Date().addingTimeInterval(USBPassthroughPolicy.manualDetachAccessoryEventGraceInterval)
        manuallyDetachedDescriptorKeys.insert(record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey] = suppressedUntil
        manualDetachEventSuppressedUntilByRegistryID[record.id] = suppressedUntil
        onEventLog?("USB manual detach policy: keeping \(record.registryIDText) in the device list and blocking automatic reattach until the next manual attach.")
    }

    private func attachSuppressionRemaining(for record: USBAccessoryRecord) -> TimeInterval? {
        guard let suppressedUntil = attachSuppressedUntilByDescriptor[record.descriptorIdentityKey] else {
            return nil
        }

        let now = Date()
        guard suppressedUntil > now else {
            attachSuppressedUntilByDescriptor[record.descriptorIdentityKey] = nil
            return nil
        }

        return suppressedUntil.timeIntervalSince(now)
    }

    private func suppressAttach(for record: USBAccessoryRecord, interval: TimeInterval, reason: String) {
        let suppressedUntil = Date().addingTimeInterval(interval)
        attachSuppressedUntilByDescriptor[record.descriptorIdentityKey] = suppressedUntil
        onEventLog?("USB attach retry suppressed for descriptor \(record.usbIDText) for \(Self.secondsText(interval)): \(reason)")
    }

    private func manualDetachEventSuppressionRemaining(for record: USBAccessoryRecord) -> TimeInterval? {
        if let remaining = suppressionRemaining(
            until: manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey],
            onExpired: {
                manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey] = nil
            }
        ) {
            return remaining
        }

        return suppressionRemaining(
            until: manualDetachEventSuppressedUntilByRegistryID[record.id],
            onExpired: {
                manualDetachEventSuppressedUntilByRegistryID[record.id] = nil
            }
        )
    }

    private func suppressionRemaining(until suppressedUntil: Date?, onExpired: () -> Void) -> TimeInterval? {
        guard let suppressedUntil else {
            return nil
        }

        let now = Date()
        guard suppressedUntil > now else {
            onExpired()
            return nil
        }

        return suppressedUntil.timeIntervalSince(now)
    }

    private func isManualPassthroughDisconnectSuppressed() -> Bool {
        guard let suppressedUntil = manualPassthroughDisconnectSuppressedUntil else {
            return false
        }

        let now = Date()
        guard suppressedUntil > now else {
            manualPassthroughDisconnectSuppressedUntil = nil
            return false
        }

        return true
    }

    private func accessoryEventContext(for record: USBAccessoryRecord, kind: String) -> String {
        accessoryEventSequence += 1

        let now = Date()
        let previousEvent = lastAccessoryEventByDescriptor[record.descriptorIdentityKey]
        lastAccessoryEventByDescriptor[record.descriptorIdentityKey] = (kind: kind, date: now)

        var components = [
            "event #\(accessoryEventSequence)",
            "vm=\(currentRuntimeState.rawValue)"
        ]

        if let previousEvent {
            let interval = now.timeIntervalSince(previousEvent.date)
            components.append(String(format: "%.2fs after previous %@ for same descriptor", interval, previousEvent.kind))
        } else {
            components.append("first event for descriptor")
        }

        if let selectedAccessoryID {
            components.append("selected=\(Self.registryIDText(selectedAccessoryID))")
        } else {
            components.append("selected=none")
        }

        if let attachedAccessoryID {
            components.append("attached=\(Self.registryIDText(attachedAccessoryID))")
        } else {
            components.append("attached=none")
        }

        return components.joined(separator: ", ")
    }

    private var currentRuntimeState: VMRuntimeState {
        runtimeStateProvider?() ?? .idle
    }

    private func notifyStateChanged() {
        onStateChange?()
    }

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }

    private static func secondsText(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", max(0, interval))
    }
}
