/*
Copyright (C) 2026 Afcoo.
*/

import AccessoryAccess
import Foundation
@preconcurrency import Virtualization

private enum USBPassthroughPolicy {
    static let attachFailureSuppressionInterval: TimeInterval = 10
}

@MainActor
final class USBAccessoryCoordinator {
    var onStateChange: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var onEventLog: EventLogHandler?
    var onAccessoryAvailable: ((USBAccessoryRecord) -> Void)?
    var onAccessoryUnavailable: ((UInt64) -> Void)?
    var onUnexpectedDetach: ((UInt64, String) -> Void)?
    var runtimeStateProvider: (() -> VMRuntimeState)?

    private let monitor: any USBAccessoryMonitoring
    private var accessoryObjects: [UInt64: AAUSBAccessory] = [:]
    private var attachedDevice: VZUSBPassthroughDevice?
    private var accessoryEventSequence = 0
    private var pendingAttachAccessoryID: UInt64?
    private var pendingAttachToken: UUID?
    private var lastAccessoryEventByDescriptor: [String: (kind: String, date: Date)] = [:]
    private var lastAttachAttemptByDescriptor: [String: Date] = [:]
    private var attachSuppressedUntilByDescriptor: [String: Date] = [:]
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
        isAccessoryMonitoring && !isReloadInProgress
    }

    var canReloadMonitoring: Bool {
        isAccessoryMonitoring
            && !isRegistrationPending
            && !isUnregistrationPending
            && !isReloadInProgress
    }

    func canRequestAttachment(for accessoryID: UInt64) -> Bool {
        guard let record = accessories.first(where: { $0.id == accessoryID }),
              record.hasConfigurationDescriptor,
              accessoryObjects[accessoryID] != nil,
              pendingAttachAccessoryID == nil,
              vmSessionAccessoryID == nil,
              attachedAccessoryID != accessoryID else {
            return false
        }

        return attachSuppressionRemaining(for: record) == nil
    }

    func canDetachAccessory(runtimeState: VMRuntimeState) -> Bool {
        runtimeState == .running
            && attachedDevice != nil
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
            reportEventLog("USB listener already active: \(reason).", level: .debug)
            completion?()
            return
        }

        isRegistrationPending = true
        isAccessoryMonitoring = true
        notifyStateChanged()
        reportEventLog("Registering AccessoryAccess USB listener: \(reason).")

        monitor.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRegistrationPending = false

                switch result {
                case .success(let connectedAccessories):
                    guard self.isAccessoryMonitoring else {
                        self.isUnregistrationPending = true
                        self.reportEventLog(
                            "USB listener registration ignored because listener was stopped.",
                            level: .debug
                        )
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
                    self.reportEventLog(
                        "USB listener registered with \(connectedAccessories.count) " +
                            "existing device(s)."
                    )
                    self.notifyStateChanged()
                    completion?()
                case .failure(let error):
                    self.isAccessoryMonitoring = false
                    self.onStatusMessage?(error.localizedDescription)
                    self.reportEventLog(
                        "USB listener failed: " + EventLogErrorFormatter.description(for: error),
                        level: .error
                    )
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
        reconnectDescriptorKey = nil
        announcedAccessoryIDs.removeAll()
        notifyStateChanged()

        monitor.stop { [weak self] in
            Task { @MainActor in
                self?.reportEventLog("AccessoryAccess USB listener stopped: \(reason)")
                self?.isUnregistrationPending = false
                self?.notifyStateChanged()
                completion?()
            }
        }
    }

    func reloadMonitoring(reason: String) {
        guard canReloadMonitoring else {
            reportEventLog(
                "USB listener reload ignored while another listener transition is active.",
                level: .debug
            )
            return
        }

        isReloadInProgress = true
        notifyStateChanged()
        stopMonitoring(reason: "Reloading USB listener: \(reason)") { [weak self] in
            guard let self else { return }
            self.startMonitoring(reason: "reload after \(reason)") { [weak self] in
                guard let self else { return }
                self.isReloadInProgress = false
                self.reportEventLog(
                    "AccessoryAccess USB listener reload completed: \(reason)."
                )
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
        pendingAttachAccessoryID = nil
        pendingAttachToken = nil
        lastAttachAttemptByDescriptor.removeAll()
        attachSuppressedUntilByDescriptor.removeAll()
        reconnectDescriptorKey = nil
        vmSessionAccessoryID = nil
        isIntentionalVMStopInProgress = false
        notifyStateChanged()
    }

    func clearAttachmentForStoppedVM() {
        attachedAccessoryID = nil
        attachedDevice = nil
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
            reportEventLog(
                "USB attach not started for registry \(record.registryIDText): " +
                    "AccessoryAccess reported no configuration descriptor. Reconnect " +
                    "the device after enabling USB tethering, then attach when the " +
                    "configuration and interfaces appear.",
                level: .warning
            )
            completion?(false)
            return
        }

        if let remaining = attachSuppressionRemaining(for: record) {
            onStatusMessage?(String(localized: "USB attach cooling down."))
            reportEventLog(
                "USB attach not started for registry \(record.registryIDText): " +
                    "retry allowed in \(Self.secondsText(remaining)).",
                level: .warning
            )
            completion?(false)
            return
        }

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

    func handlePassthroughDisconnect(device: VZUSBPassthroughDevice) {
        guard let attachedDevice else {
            reportEventLog(
                "Ignoring stale USB passthrough disconnect because no device is attached.",
                level: .debug
            )
            return
        }

        guard attachedDevice === device else {
            reportEventLog(
                "Ignoring stale USB passthrough disconnect from an earlier VM or attachment.",
                level: .debug
            )
            return
        }

        let disconnectedAccessoryID = attachedAccessoryID
        let attachedRegistry = disconnectedAccessoryID.map(Self.registryIDText) ?? "none"
        let reconnectRecord = attachedAccessoryID.flatMap { id in
            accessories.first { $0.id == id }
        }
        if isIntentionalVMStopInProgress {
            attachedAccessoryID = nil
            self.attachedDevice = nil
            notifyStateChanged()
            reportEventLog(
                "USB passthrough disconnect ignored because it was produced by an " +
                    "intentional VM stop, attached registry \(attachedRegistry).",
                level: .debug
            )
            return
        }

        attachedAccessoryID = nil
        self.attachedDevice = nil
        if let reconnectRecord {
            reconnectDescriptorKey = reconnectRecord.descriptorIdentityKey
        }
        notifyStateChanged()
        let reason = "USB passthrough device disconnected by the system, attached registry \(attachedRegistry)."
        reportEventLog(reason, level: .warning)
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

        if let vmSessionAccessoryID {
            onStatusMessage?(String(localized: "Detach the current USB accessory before attaching another USB accessory."))
            reportEventLog(
                "USB attach skipped for registry \(record.registryIDText): this VM " +
                    "session already used registry \(Self.registryIDText(vmSessionAccessoryID)) " +
                    "and must stop before another attach.",
                level: .warning
            )
            completion?(false)
            return
        }

        guard attachedAccessoryID == nil, attachedDevice == nil else {
            let attachedRegistry = attachedAccessoryID.map(Self.registryIDText) ?? "unknown"
            onStatusMessage?(String(localized: "Only one USB passthrough accessory is supported per VM session."))
            reportEventLog(
                "USB attach skipped for registry \(record.registryIDText): single " +
                    "passthrough device limit is already active with registry " +
                    "\(attachedRegistry).",
                level: .warning
            )
            completion?(false)
            return
        }

        guard pendingAttachAccessoryID == nil else {
            reportEventLog(
                "USB attach skipped for registry \(record.registryIDText): attach " +
                    "already pending for \(Self.registryIDText(pendingAttachAccessoryID!)).",
                level: .debug
            )
            completion?(false)
            return
        }

        let attachToken = UUID()
        pendingAttachAccessoryID = registryID
        pendingAttachToken = attachToken
        lastAttachAttemptByDescriptor[descriptorKey] = Date()
        notifyStateChanged()
        reportEventLog("USB attach requested.")
        reportEventLog(
            "USB attach details: \(record.descriptorDiagnosticText), registry " +
                "\(record.registryIDText), reason=\(reason), " +
                "vm=\(currentRuntimeState.rawValue), " +
                "usbControllers=\(virtualMachine.usbControllers.count).",
            level: .debug
        )

        do {
            let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
            let device = try VZUSBPassthroughDevice(configuration: configuration)

            guard let controller = virtualMachine.usbControllers.first else {
                pendingAttachAccessoryID = nil
                pendingAttachToken = nil
                notifyStateChanged()
                onStatusMessage?(String(localized: "VM has no USB controller."))
                reportEventLog(
                    "USB attach failed: VM has no USB controller for registry " +
                        "\(record.registryIDText).",
                    level: .error
                )
                completion?(false)
                return
            }

            controller.attach(device: device) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }

                    guard self.pendingAttachAccessoryID == registryID,
                          self.pendingAttachToken == attachToken else {
                        self.reportEventLog(
                            "USB attach completion ignored for registry " +
                                "\(record.registryIDText): attach is no longer current.",
                            level: .debug
                        )
                        completion?(false)
                        return
                    }

                    self.pendingAttachAccessoryID = nil
                    self.pendingAttachToken = nil

                    if let error {
                        let eventLogError = EventLogErrorFormatter.description(for: error)
                        self.onStatusMessage?(error.localizedDescription)
                        self.reportEventLog(
                            "USB attach failed: \(eventLogError)",
                            level: .error
                        )
                        self.suppressAttach(
                            for: record,
                            interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                            reason: "VZ USB controller attach failed: \(eventLogError)"
                        )
                    } else {
                        self.attachedAccessoryID = registryID
                        self.attachedDevice = device
                        self.vmSessionAccessoryID = registryID
                        self.onStatusMessage?(String(localized: "USB accessory attached."))
                        self.reportEventLog("USB accessory attached.")
                        self.reportEventLog(
                            "Attached USB registry: \(record.registryIDText).",
                            level: .debug
                        )
                    }
                    self.notifyStateChanged()
                    completion?(error == nil)
                }
            }
        } catch {
            let eventLogError = EventLogErrorFormatter.description(for: error)
            pendingAttachAccessoryID = nil
            pendingAttachToken = nil
            notifyStateChanged()
            onStatusMessage?(error.localizedDescription)
            reportEventLog(
                "USB passthrough device creation failed for registry " +
                    "\(record.registryIDText): \(eventLogError)",
                level: .error
            )
            suppressAttach(
                for: record,
                interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                reason: "VZ passthrough device creation failed: \(eventLogError)"
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

        accessories.removeAll { $0.id == record.id }

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
        reportEventLog("USB connected: \(record.deviceName).")
        reportEventLog(
            "USB connect details: \(record.descriptorDiagnosticText), registry " +
                "\(record.registryIDText), " +
                "\(accessoryEventContext(for: record, kind: "connect")).",
            level: .debug
        )

        let becameReady = previousRecord?.hasConfigurationDescriptor != true && record.hasConfigurationDescriptor
        let shouldAnnounce = becameReady
            && attachedAccessoryID != record.id
            && announcedAccessoryIDs.insert(record.id).inserted

        if shouldAnnounce {
            onAccessoryAvailable?(record)
        }
    }

    private func removeAccessory(_ accessory: AAUSBAccessory) {
        let record = USBAccessoryRecord(accessory: accessory)
        let wasSelected = selectedAccessoryID == accessory.registryID
        let wasAttached = attachedAccessoryID == accessory.registryID

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
            reportEventLog(
                "USB disconnected while VZ attach was pending for registry " +
                    "\(record.registryIDText).",
                level: .warning
            )
        }

        notifyStateChanged()
        let isIntentionalSessionDevice = isIntentionalVMStopInProgress
            && vmSessionAccessoryID == record.id
        if !isIntentionalSessionDevice {
            onAccessoryUnavailable?(record.id)
        }
        reportEventLog("USB disconnected: \(record.deviceName).")
        reportEventLog(
            "USB disconnect details: \(record.descriptorDiagnosticText), registry " +
                "\(record.registryIDText), wasSelected=\(wasSelected), " +
                "wasAttached=\(wasAttached), " +
                "\(accessoryEventContext(for: record, kind: "disconnect")).",
            level: .debug
        )

        if wasAttached {
            if isIntentionalVMStopInProgress {
                reportEventLog(
                    "USB disconnect matched the attached passthrough accessory during " +
                        "an intentional VM stop.",
                    level: .debug
                )
            } else {
                let reason = "AccessoryAccess disconnected the attached USB accessory, registry \(record.registryIDText)."
                reportEventLog(reason, level: .warning)
                onUnexpectedDetach?(record.id, reason)
            }
        }
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
        reportEventLog(
            "USB attach retry suppressed for descriptor \(record.usbIDText) for " +
                "\(Self.secondsText(interval)): \(reason)",
            level: .debug
        )
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

    private func reportEventLog(
        _ message: String,
        level: EventLogLevel = .info
    ) {
        onEventLog?(message, level)
    }

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }

    private static func secondsText(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", max(0, interval))
    }
}
