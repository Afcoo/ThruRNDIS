/*
Copyright (C) 2026 Afcoo.
*/

import AccessoryAccess
import Foundation
@preconcurrency import Virtualization

private enum USBPassthroughPolicy {
    static let attachFailureSuppressionInterval: TimeInterval = 10
    static let intentionalDisconnectExpectationInterval: Duration = .seconds(10)
    static let intentionalReenumerationInterval: Duration = .seconds(3)
    static let descriptorReadinessInterval: Duration = .seconds(10)
}

private struct ExpectedAccessoryReenumeration {
    let registryID: UInt64
    let reconnectIdentity: USBAccessoryReconnectIdentity
    let attachmentProfile: USBAccessoryAttachmentProfile
    let disconnectDeadline: ContinuousClock.Instant
    var reconnectDeadline: ContinuousClock.Instant?
}

private struct SuppressedAccessoryReenumeration {
    let reconnectIdentity: USBAccessoryReconnectIdentity
    let attachmentProfile: USBAccessoryAttachmentProfile
    let readinessDeadline: ContinuousClock.Instant
}

@MainActor
final class USBAccessoryCoordinator {
    var onStateChange: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var onEventLog: EventLogHandler?
    var onAccessoryAvailable: ((USBAccessoryRecord) -> Void)?
    var onAccessoryPromptSuppressed: ((UInt64) -> Void)?
    var onAccessoryUnavailable: ((UInt64) -> Void)?
    var onUnexpectedDetach: ((UInt64, String) -> Void)?
    var runtimeStateProvider: (() -> VMRuntimeState)?

    private let monitor: USBAccessoryMonitor
    private let clock = ContinuousClock()
    private var accessoryObjects: [UInt64: AAUSBAccessory] = [:]
    private var attachedDevice: VZUSBPassthroughDevice?
    private var attachedReconnectIdentity: USBAccessoryReconnectIdentity?
    private var attachedAttachmentProfile: USBAccessoryAttachmentProfile?
    private var accessoryEventSequence = 0
    private var pendingAttachAccessoryID: UInt64?
    private var pendingAttachToken: UUID?
    private var lastAccessoryEventByDescriptor: [String: (kind: String, date: Date)] = [:]
    private var lastAttachAttemptByDescriptor: [String: Date] = [:]
    private var attachSuppressedUntilByDescriptor: [String: Date] = [:]
    private var reconnectIdentity: USBAccessoryReconnectIdentity?
    private var expectedAccessoryReenumeration: ExpectedAccessoryReenumeration?
    private var suppressedAccessoryReenumerations: [UInt64: SuppressedAccessoryReenumeration] = [:]
    private var announcedAccessoryIDs: Set<UInt64> = []
    private var isIntentionalVMStopInProgress = false
    private var isRegistrationPending = false
    private var isUnregistrationPending = false
    private var isReloadInProgress = false
    private var monitorGeneration = 0
    private var stopMonitoringCompletions: [() -> Void] = []

    private(set) var accessories: [USBAccessoryRecord] = []
    private(set) var isAccessoryMonitoring = false
    private(set) var selectedAccessoryID: UInt64?
    private(set) var attachedAccessoryID: UInt64?
    private(set) var vmSessionAccessoryID: UInt64?

    init(monitor: USBAccessoryMonitor) {
        self.monitor = monitor
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
        reportEventLog(
            "Selected USB registry: \(id.map(Self.registryIDText) ?? "none").",
            level: .debug
        )
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
        monitorGeneration &+= 1
        configureAccessoryMonitor(generation: monitorGeneration)
        notifyStateChanged()
        reportEventLog(
            "Registering AccessoryAccess USB listener: \(reason).",
            level: .debug
        )

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
                                guard let self else {
                                    return
                                }
                                self.isUnregistrationPending = false
                                self.notifyStateChanged()
                                completion?()
                                self.finishStopMonitoringIfSettled()
                            }
                        }
                        return
                    }

                    connectedAccessories.forEach { self.addAccessory($0) }
                    self.onStatusMessage?(String(localized: "USB listener registered."))
                    self.reportEventLog(
                        "USB listener registered with \(connectedAccessories.count) " +
                            "existing device(s).",
                        level: self.isReloadInProgress ? .debug : .info
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
                    self.finishStopMonitoringIfSettled()
                }
            }
        }
    }

    func stopMonitoring(reason: String, completion: (() -> Void)? = nil) {
        stopMonitoring(
            reason: reason,
            cancelsReload: true,
            completion: completion
        )
    }

    private func stopMonitoring(
        reason: String,
        cancelsReload: Bool,
        completion: (() -> Void)?
    ) {
        if cancelsReload, isReloadInProgress {
            isReloadInProgress = false
            reportEventLog(
                "AccessoryAccess USB listener reload cancelled: \(reason)",
                level: .debug
            )
            notifyStateChanged()
        }

        if let completion {
            stopMonitoringCompletions.append(completion)
        }

        expectedAccessoryReenumeration = nil
        suppressedAccessoryReenumerations.removeAll()
        monitorGeneration &+= 1

        let hasMonitoringState = isAccessoryMonitoring
            || isRegistrationPending
            || isUnregistrationPending
            || !accessoryObjects.isEmpty
            || !accessories.isEmpty
        guard hasMonitoringState else {
            finishStopMonitoringIfSettled()
            return
        }

        isAccessoryMonitoring = false
        accessoryObjects.removeAll()
        accessories.removeAll()
        selectedAccessoryID = nil
        reconnectIdentity = nil
        announcedAccessoryIDs.removeAll()
        notifyStateChanged()

        guard !isRegistrationPending, !isUnregistrationPending else {
            return
        }

        isUnregistrationPending = true
        monitor.stop { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.reportEventLog(
                    "AccessoryAccess USB listener stopped: \(reason)",
                    level: self.isReloadInProgress ? .debug : .info
                )
                self.isUnregistrationPending = false
                self.notifyStateChanged()
                self.finishStopMonitoringIfSettled()
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
        stopMonitoring(
            reason: "Reloading USB listener: \(reason)",
            cancelsReload: false
        ) { [weak self] in
            guard let self else { return }
            guard self.isReloadInProgress else {
                return
            }
            self.startMonitoring(reason: "reload after \(reason)") { [weak self] in
                guard let self else { return }
                guard self.isReloadInProgress else {
                    return
                }
                self.isReloadInProgress = false
                if self.isAccessoryMonitoring {
                    self.reportEventLog(
                        "AccessoryAccess USB listener reload completed: \(reason).",
                        level: .info
                    )
                } else {
                    self.reportEventLog(
                        "AccessoryAccess USB listener reload did not complete: \(reason).",
                        level: .debug
                    )
                }
                self.notifyStateChanged()
            }
        }
    }

    func prepareForIntentionalVMStop(
        suppressReenumerationPrompt: Bool = true
    ) {
        expectedAccessoryReenumeration = nil
        suppressedAccessoryReenumerations.removeAll()
        if suppressReenumerationPrompt,
           let attachedAccessoryID,
           let reconnectIdentity = attachedReconnectIdentity,
           let attachmentProfile = attachedAttachmentProfile {
            expectedAccessoryReenumeration = ExpectedAccessoryReenumeration(
                registryID: attachedAccessoryID,
                reconnectIdentity: reconnectIdentity,
                attachmentProfile: attachmentProfile,
                disconnectDeadline: clock.now.advanced(
                    by: USBPassthroughPolicy.intentionalDisconnectExpectationInterval
                )
            )
        }
        isIntentionalVMStopInProgress = true
        reportEventLog(
            "Marked USB passthrough teardown as an intentional VM stop; " +
                "reenumeration prompt suppression=" +
                "\(expectedAccessoryReenumeration == nil ? "unavailable" : "armed").",
            level: .debug
        )
    }

    func resetForVMStart() {
        attachedAccessoryID = nil
        attachedDevice = nil
        attachedReconnectIdentity = nil
        attachedAttachmentProfile = nil
        pendingAttachAccessoryID = nil
        pendingAttachToken = nil
        lastAttachAttemptByDescriptor.removeAll()
        attachSuppressedUntilByDescriptor.removeAll()
        reconnectIdentity = nil
        expectedAccessoryReenumeration = nil
        suppressedAccessoryReenumerations.removeAll()
        vmSessionAccessoryID = nil
        isIntentionalVMStopInProgress = false
        reportEventLog(
            "Reset USB passthrough state for a new VM session.",
            level: .debug
        )
        notifyStateChanged()
    }

    func clearAttachmentForStoppedVM() {
        attachedAccessoryID = nil
        attachedDevice = nil
        attachedReconnectIdentity = nil
        attachedAttachmentProfile = nil
        pendingAttachAccessoryID = nil
        pendingAttachToken = nil
        reconnectIdentity = nil
        vmSessionAccessoryID = nil
        isIntentionalVMStopInProgress = false
        reportEventLog(
            "Cleared USB passthrough state after VM stop.",
            level: .debug
        )
        notifyStateChanged()
    }

    func attachAccessory(
        id accessoryID: UInt64,
        to virtualMachine: VZVirtualMachine?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let virtualMachine else {
            onStatusMessage?(String(localized: "Start the VM before attaching USB."))
            reportEventLog(
                "USB attach preflight failed for registry " +
                    "\(Self.registryIDText(accessoryID)): virtual machine reference unavailable.",
                level: .warning
            )
            completion?(false)
            return
        }
        guard let accessory = accessoryObjects[accessoryID] else {
            onStatusMessage?(String(localized: "The selected USB accessory is no longer available."))
            reportEventLog(
                "USB attach preflight failed for registry " +
                    "\(Self.registryIDText(accessoryID)): AccessoryAccess object no longer available.",
                level: .warning
            )
            completion?(false)
            return
        }

        let cachedRecord = accessories.first { $0.id == accessoryID }
        let record = USBAccessoryRecord(
            accessory: accessory,
            previousReconnectIdentity: cachedRecord?.reconnectIdentity
        )
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

        reconnectIdentity = nil
        expectedAccessoryReenumeration = nil
        suppressedAccessoryReenumerations.removeAll()
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
        let disconnectedReconnectIdentity = attachedReconnectIdentity
            ?? reconnectRecord?.reconnectIdentity
        if isIntentionalVMStopInProgress {
            noteExpectedAccessoryDisconnect(
                registryID: disconnectedAccessoryID,
                reconnectIdentity: disconnectedReconnectIdentity
            )
            attachedAccessoryID = nil
            self.attachedDevice = nil
            attachedReconnectIdentity = nil
            attachedAttachmentProfile = nil
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
        attachedReconnectIdentity = nil
        attachedAttachmentProfile = nil
        reconnectIdentity = disconnectedReconnectIdentity
        notifyStateChanged()
        let reason = "USB passthrough device disconnected by the system, attached registry \(attachedRegistry)."
        reportEventLog(reason, level: .warning)
        if let disconnectedAccessoryID {
            onUnexpectedDetach?(disconnectedAccessoryID, reason)
        }
    }

    private func configureAccessoryMonitor(generation: Int) {
        monitor.onConnect = { [weak self] accessory in
            Task { @MainActor in
                guard let self,
                      self.monitorGeneration == generation,
                      self.isAccessoryMonitoring else {
                    return
                }
                self.addAccessory(accessory)
            }
        }

        monitor.onDisconnect = { [weak self] accessory in
            Task { @MainActor in
                guard let self,
                      self.monitorGeneration == generation,
                      self.isAccessoryMonitoring else {
                    return
                }
                self.removeAccessory(accessory)
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
                        self.attachedReconnectIdentity = record.reconnectIdentity
                        self.attachedAttachmentProfile = record.attachmentProfile
                        self.vmSessionAccessoryID = registryID
                        self.onStatusMessage?(String(localized: "USB accessory attached."))
                        self.reportEventLog("USB accessory attached.", level: .info)
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
        let previousRecord = accessories.first { $0.id == accessory.registryID }
        let record = USBAccessoryRecord(
            accessory: accessory,
            previousReconnectIdentity: previousRecord?.reconnectIdentity
        )

        accessories.removeAll { $0.id == record.id }

        accessories.append(record)
        accessories.sort { $0.usbIDText < $1.usbIDText }
        let expectedDisconnectedRegistryID: UInt64?
        if let expectedAccessoryReenumeration,
           expectedAccessoryReenumeration.reconnectDeadline != nil,
           expectedAccessoryReenumeration.reconnectIdentity
            == record.reconnectIdentity {
            expectedDisconnectedRegistryID = expectedAccessoryReenumeration.registryID
        } else {
            expectedDisconnectedRegistryID = nil
        }
        let matchingIdentityCount = record.reconnectIdentity.map { identity in
            accessories.filter {
                $0.id != expectedDisconnectedRegistryID
                    && $0.reconnectIdentity == identity
            }.count
        } ?? 0
        matchExpectedAccessoryReenumeration(
            with: record,
            matchingIdentityCount: matchingIdentityCount
        )
        let shouldReconnect = reconnectIdentity != nil
            && reconnectIdentity == record.reconnectIdentity
            && matchingIdentityCount == 1
        attachSuppressedUntilByDescriptor.removeValue(forKey: record.descriptorIdentityKey)
        if selectedAccessoryID == nil || shouldReconnect {
            selectedAccessoryID = record.id
        }
        if shouldReconnect {
            reconnectIdentity = nil
        } else if reconnectIdentity == record.reconnectIdentity,
                  matchingIdentityCount > 1 {
            reconnectIdentity = nil
            reportEventLog(
                "USB reconnect identity is ambiguous across connected accessories; " +
                    "automatic identity matching was disabled.",
                level: .warning
            )
        }
        notifyStateChanged()
        if previousRecord == nil {
            reportEventLog("USB connected: \(record.deviceName).", level: .info)
        } else {
            reportEventLog(
                "USB descriptor state updated: \(record.deviceName).",
                level: .debug
            )
        }
        reportEventLog(
            "USB connect details: \(record.descriptorDiagnosticText), registry " +
                "\(record.registryIDText), " +
                "\(accessoryEventContext(for: record, kind: "connect")).",
            level: .debug
        )

        let becameReady = previousRecord?.hasConfigurationDescriptor != true
            && record.hasConfigurationDescriptor
        if becameReady, consumePromptSuppressionIfMatching(record) {
            _ = announcedAccessoryIDs.insert(record.id)
            onAccessoryPromptSuppressed?(record.id)
            reportEventLog(
                "USB accessory returned after intentional passthrough release; " +
                    "connection prompt suppressed for registry \(record.registryIDText).",
                level: .debug
            )
        } else if becameReady,
                  attachedAccessoryID != record.id,
                  announcedAccessoryIDs.insert(record.id).inserted {
            onAccessoryAvailable?(record)
        }
    }

    private func removeAccessory(_ accessory: AAUSBAccessory) {
        let record = accessories.first { $0.id == accessory.registryID }
            ?? USBAccessoryRecord(accessory: accessory)
        let wasSelected = selectedAccessoryID == accessory.registryID
        let wasAttached = attachedAccessoryID == accessory.registryID
        let wasPendingAttach = pendingAttachAccessoryID == accessory.registryID

        noteExpectedAccessoryDisconnect(
            registryID: record.id,
            reconnectIdentity: record.reconnectIdentity
        )

        accessoryObjects[accessory.registryID] = nil
        accessories.removeAll { $0.id == accessory.registryID }
        announcedAccessoryIDs.remove(accessory.registryID)
        suppressedAccessoryReenumerations[accessory.registryID] = nil

        if wasSelected {
            selectedAccessoryID = accessories.first?.id
        }

        if wasAttached {
            reconnectIdentity = attachedReconnectIdentity ?? record.reconnectIdentity
            attachedAccessoryID = nil
            attachedDevice = nil
            attachedReconnectIdentity = nil
            attachedAttachmentProfile = nil
        }

        if wasPendingAttach {
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
        reportEventLog(
            "USB disconnected: \(record.deviceName).",
            level: wasAttached || wasPendingAttach ? .debug : .info
        )
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

    private func noteExpectedAccessoryDisconnect(
        registryID: UInt64?,
        reconnectIdentity: USBAccessoryReconnectIdentity?
    ) {
        guard var expectedAccessoryReenumeration,
              expectedAccessoryReenumeration.registryID == registryID,
              expectedAccessoryReenumeration.reconnectIdentity
                == reconnectIdentity else {
            return
        }

        let now = clock.now
        guard expectedAccessoryReenumeration.disconnectDeadline > now else {
            self.expectedAccessoryReenumeration = nil
            return
        }

        if expectedAccessoryReenumeration.reconnectDeadline == nil {
            expectedAccessoryReenumeration.reconnectDeadline = now.advanced(
                by: USBPassthroughPolicy.intentionalReenumerationInterval
            )
        }
        self.expectedAccessoryReenumeration = expectedAccessoryReenumeration
        reconcileExpectedAccessoryReenumerationWithAvailableAccessories()
    }

    private func reconcileExpectedAccessoryReenumerationWithAvailableAccessories() {
        guard let expectedAccessoryReenumeration,
              expectedAccessoryReenumeration.reconnectDeadline != nil else {
            return
        }

        let candidates = accessories.filter {
            $0.id != expectedAccessoryReenumeration.registryID
                && $0.reconnectIdentity
                    == expectedAccessoryReenumeration.reconnectIdentity
        }
        guard candidates.count <= 1 else {
            self.expectedAccessoryReenumeration = nil
            reportEventLog(
                "USB reenumeration identity is ambiguous; connection prompt " +
                    "suppression was disabled.",
                level: .warning
            )
            return
        }
        guard let candidate = candidates.first else {
            return
        }

        matchExpectedAccessoryReenumeration(
            with: candidate,
            matchingIdentityCount: 1
        )
        guard candidate.hasConfigurationDescriptor,
              consumePromptSuppressionIfMatching(candidate) else {
            return
        }

        _ = announcedAccessoryIDs.insert(candidate.id)
        onAccessoryPromptSuppressed?(candidate.id)
        reportEventLog(
            "USB accessory returned before disconnect notification; " +
                "queued connection prompt suppressed for registry " +
                "\(candidate.registryIDText).",
            level: .debug
        )
    }

    private func matchExpectedAccessoryReenumeration(
        with record: USBAccessoryRecord,
        matchingIdentityCount: Int
    ) {
        guard let expectedAccessoryReenumeration else {
            return
        }

        let now = clock.now
        guard let reconnectDeadline = expectedAccessoryReenumeration.reconnectDeadline else {
            if expectedAccessoryReenumeration.disconnectDeadline <= now {
                self.expectedAccessoryReenumeration = nil
            }
            return
        }

        guard reconnectDeadline > now else {
            self.expectedAccessoryReenumeration = nil
            return
        }

        guard expectedAccessoryReenumeration.reconnectIdentity
                == record.reconnectIdentity else {
            return
        }

        guard matchingIdentityCount == 1 else {
            self.expectedAccessoryReenumeration = nil
            reportEventLog(
                "USB reenumeration identity is ambiguous; connection prompt " +
                    "suppression was disabled.",
                level: .warning
            )
            return
        }

        suppressedAccessoryReenumerations[record.id] = SuppressedAccessoryReenumeration(
            reconnectIdentity: expectedAccessoryReenumeration.reconnectIdentity,
            attachmentProfile: expectedAccessoryReenumeration.attachmentProfile,
            readinessDeadline: now.advanced(
                by: USBPassthroughPolicy.descriptorReadinessInterval
            )
        )
        self.expectedAccessoryReenumeration = nil
    }

    private func consumePromptSuppressionIfMatching(
        _ record: USBAccessoryRecord
    ) -> Bool {
        guard let suppressedReenumeration = suppressedAccessoryReenumerations[record.id]
        else {
            return false
        }

        suppressedAccessoryReenumerations[record.id] = nil
        let isMatching = suppressedReenumeration.readinessDeadline > clock.now
            && suppressedReenumeration.reconnectIdentity == record.reconnectIdentity
            && suppressedReenumeration.attachmentProfile == record.attachmentProfile
        if !isMatching {
            reportEventLog(
                "USB reenumeration profile changed; the connection prompt was retained.",
                level: .debug
            )
        }
        return isMatching
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

    private func finishStopMonitoringIfSettled() {
        guard !isAccessoryMonitoring,
              !isRegistrationPending,
              !isUnregistrationPending else {
            return
        }

        let completions = stopMonitoringCompletions
        stopMonitoringCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func reportEventLog(
        _ message: String,
        level: EventLogLevel
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
