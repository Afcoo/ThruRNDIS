/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

@MainActor
final class WireGuardSessionStore: ObservableObject {
    @Published private(set) var hostTunnelStatus: HostWireGuardTunnelStatus = .unconfigured
    @Published private(set) var systemExtensionStatus: WireGuardSystemExtensionStatus = .unknown
    @Published private(set) var isSystemExtensionActivationInProgress = false
    @Published private(set) var discoveredEndpoint: String?
    @Published private(set) var invalidConnectionFields: Set<WireGuardConnectionField> = []
    @Published private(set) var keyMaterial: WireGuardKeyMaterial?

    @Published var dnsServersText: String {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(dnsServersText, forKey: DefaultsKey.dnsServersText)
            revalidateConnectionField(.dnsServers)
            notifyReadinessChange()
        }
    }

    @Published var endpointText: String {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(endpointText, forKey: DefaultsKey.endpointText)
            revalidateConnectionField(.endpoint)
            notifyReadinessChange()
        }
    }

    @Published var allowedIPsText: String {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(allowedIPsText, forKey: DefaultsKey.allowedIPsText)
            revalidateConnectionField(.allowedIPs)
            notifyReadinessChange()
        }
    }

    var onReadinessChange: (() -> Void)?

    private let configurationStore: any WireGuardConfigurationStoring
    private let configurationBuilder: WireGuardConfigurationBuilder
    private let tunnelController: any HostWireGuardTunnelControlling
    private let eventLog: EventLogStore
    private let systemExtensionSettingsOpener: @MainActor () -> Bool
    private let defaults: UserDefaults
    private var connectTask: Task<Void, Never>?
    private var connectTaskID: UUID?
    private var systemExtensionActivationTask: Task<Void, Never>?
    private var isPreparingForApplicationTermination = false
    private var isResettingPersistedValues = false

    init(
        configurationStore: any WireGuardConfigurationStoring,
        configurationBuilder: WireGuardConfigurationBuilder,
        tunnelController: any HostWireGuardTunnelControlling,
        eventLog: EventLogStore,
        systemExtensionSettingsOpener: @escaping @MainActor () -> Bool = {
            NetworkExtensionSettingsOpener.open()
        },
        defaults: UserDefaults = .standard
    ) {
        self.configurationStore = configurationStore
        self.configurationBuilder = configurationBuilder
        self.tunnelController = tunnelController
        self.eventLog = eventLog
        self.systemExtensionSettingsOpener = systemExtensionSettingsOpener
        self.defaults = defaults
        self.dnsServersText = Self.restoredInput(
            defaults: defaults,
            key: DefaultsKey.dnsServersText
        )
        self.endpointText = Self.restoredInput(
            defaults: defaults,
            key: DefaultsKey.endpointText
        )
        self.allowedIPsText = Self.restoredInput(
            defaults: defaults,
            key: DefaultsKey.allowedIPsText
        )

        configureTunnelController()
        prepareConfiguration()
        revalidateAllConnectionFields()

        Task { @MainActor [weak self] in
            guard let self,
                  !self.isPreparingForApplicationTermination,
                  !Task.isCancelled else {
                return
            }
            await self.tunnelController.refreshSystemExtensionStatus()
        }
        Task { @MainActor [weak self] in
            await self?.tunnelController.refreshStatus()
        }
    }

    var hasKeyMaterial: Bool {
        keyMaterial != nil
    }

    var configurationDirectoryURL: URL {
        configurationStore.files.wireGuardDirectoryURL
    }

    var sharedConfigurationDirectoryURL: URL {
        configurationStore.sharedDirectoryURL
    }

    var canExportConfiguration: Bool {
        keyMaterial != nil && resolvedEndpoint != nil
    }

    var resolvedEndpoint: String? {
        normalizedInput(endpointText) ?? discoveredEndpoint
    }

    var resolvedAllowedIPs: String {
        normalizedInput(allowedIPsText)
            ?? configurationBuilder.elements.clientAllowedIPs
    }

    var resolvedDNSServers: [String] {
        resolvedDNSServersText
            .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .compactMap(normalizedInput)
    }

    var defaultDNSServersText: String {
        configurationBuilder.elements.dnsServers.joined(separator: ", ")
    }

    var endpointPrompt: String {
        discoveredEndpoint
            ?? String(localized: "Waiting for THRURNDIS_WG_ENDPOINT from guest")
    }

    var hasEndpointValidationError: Bool {
        invalidConnectionFields.contains(.endpoint)
    }

    var hasAllowedIPsValidationError: Bool {
        invalidConnectionFields.contains(.allowedIPs)
    }

    var hasDNSServersValidationError: Bool {
        invalidConnectionFields.contains(.dnsServers)
    }

    var canRequestSystemExtensionActivation: Bool {
        !isPreparingForApplicationTermination
            && systemExtensionStatus.canRequestActivation
            && !isSystemExtensionActivationInProgress
    }

    var canDisconnectTunnel: Bool {
        hostTunnelStatus.canRequestStop
    }

    var clientConfiguration: String {
        guard let keyMaterial else {
            return "# WireGuard key material is unavailable in Application Support."
        }

        return configurationBuilder.clientConfiguration(
            keyMaterial: keyMaterial,
            endpoint: resolvedEndpoint,
            dnsServers: resolvedDNSServers,
            allowedIPs: resolvedAllowedIPs
        )
    }

    @discardableResult
    func reloadConfiguration(
        reason: String = "manual request",
        requireExisting: Bool = true
    ) -> Bool {
        do {
            let prepared = requireExisting
                ? try configurationStore.requireExistingConfiguration(
                    builder: configurationBuilder
                )
                : try configurationStore.prepareConfigurationIfNeeded(
                    builder: configurationBuilder
                )
            keyMaterial = prepared.keyMaterial
            appendEventLog(
                "Regenerated WireGuard configuration from keys in " +
                    "\(prepared.files.wireGuardDirectoryURL.path): \(reason)."
            )
            notifyReadinessChange()
            return true
        } catch {
            keyMaterial = nil
            appendEventLog(
                "WireGuard configuration load failed: " +
                    EventLogErrorFormatter.description(for: error)
            )
            notifyReadinessChange()
            return false
        }
    }

    func removeConfigurationDirectory() throws {
        try configurationStore.removeConfigurationDirectory()
    }

    func resetPersistedValues() {
        isResettingPersistedValues = true
        dnsServersText = ""
        endpointText = ""
        allowedIPsText = ""
        isResettingPersistedValues = false

        defaults.removeObject(forKey: DefaultsKey.dnsServersText)
        defaults.removeObject(forKey: DefaultsKey.endpointText)
        defaults.removeObject(forKey: DefaultsKey.allowedIPsText)
        keyMaterial = nil
        discoveredEndpoint = nil
        invalidConnectionFields = []
        notifyReadinessChange()
    }

    @discardableResult
    func validateConnectionInputs() -> Bool {
        let invalidFields = currentInvalidConnectionFields()
        if invalidConnectionFields != invalidFields {
            invalidConnectionFields = invalidFields
        }
        guard invalidFields.isEmpty else {
            let invalidFieldNames = WireGuardConnectionField.allCases
                .filter(invalidFields.contains)
                .map(\.displayName)
                .joined(separator: ", ")
            appendEventLog(
                "Host WireGuard tunnel not started: invalid connection values " +
                    "(\(invalidFieldNames))."
            )
            return false
        }
        return true
    }

    @discardableResult
    func connect() -> Bool {
        guard validateConnectionInputs() else {
            return false
        }
        guard systemExtensionStatus.isActive else {
            appendEventLog(
                "Host WireGuard tunnel not started: network extension is not active."
            )
            return false
        }
        guard canExportConfiguration else {
            updateHostTunnelStatus(.unconfigured)
            appendEventLog(
                "Host WireGuard tunnel not started: VM endpoint is unknown."
            )
            return false
        }

        let configuration = clientConfiguration
        connectTask?.cancel()
        let taskID = UUID()
        connectTaskID = taskID
        connectTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.tunnelController.connect(
                wgQuickConfiguration: configuration
            )
            guard self.connectTaskID == taskID else {
                return
            }
            self.connectTask = nil
            self.connectTaskID = nil
        }
        return true
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        connectTaskID = nil
        Task { @MainActor [weak self] in
            await self?.tunnelController.disconnect(waitUntilStopped: false)
        }
    }

    @discardableResult
    func disconnectAndWait() async -> Bool {
        connectTask?.cancel()
        connectTask = nil
        connectTaskID = nil
        return await tunnelController.disconnect(waitUntilStopped: true)
    }

    @discardableResult
    func removeSavedTunnelIfNeeded() async -> Bool {
        await tunnelController.removeSavedTunnelIfNeeded()
    }

    func refreshHostTunnelStatus() {
        guard !hostTunnelStatus.isTransitioning else {
            appendEventLog(
                "Host WireGuard status refresh skipped during a tunnel transition."
            )
            return
        }

        Task { @MainActor [weak self] in
            await self?.tunnelController.refreshStatus()
        }
    }

    func refreshSystemExtensionStatus() {
        guard !isPreparingForApplicationTermination else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  !self.isPreparingForApplicationTermination,
                  !Task.isCancelled else {
                return
            }
            await self.tunnelController.refreshSystemExtensionStatus()
        }
    }

    @discardableResult
    func requestSystemExtensionActivation() -> Bool {
        guard canRequestSystemExtensionActivation else {
            return false
        }

        let controller = tunnelController
        isSystemExtensionActivationInProgress = true
        systemExtensionActivationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled,
                  let self,
                  !self.isPreparingForApplicationTermination else {
                return
            }
            await controller.activateSystemExtension()
            guard !Task.isCancelled,
                  !self.isPreparingForApplicationTermination else {
                return
            }
            self.systemExtensionActivationTask = nil
            self.isSystemExtensionActivationInProgress = false
        }
        return true
    }

    func openSystemExtensionSettings() {
        guard !isPreparingForApplicationTermination else {
            return
        }
        guard systemExtensionSettingsOpener() else {
            appendEventLog("Could not open Network Extensions settings.")
            return
        }
        appendEventLog("Opened Network Extensions settings.")
    }

    func prepareForApplicationTermination(disconnectTunnel: Bool) async {
        isPreparingForApplicationTermination = true
        connectTask?.cancel()
        connectTask = nil
        connectTaskID = nil
        systemExtensionActivationTask?.cancel()
        systemExtensionActivationTask = nil
        tunnelController.invalidateSystemExtensionOperations()
        isSystemExtensionActivationInProgress = false
        if disconnectTunnel {
            _ = await tunnelController.disconnect(waitUntilStopped: true)
        }
    }

    func cancelTunnel(reason: String) {
        guard connectTask != nil || hostTunnelStatus.canRequestStop else {
            return
        }
        let shouldLogStop = hostTunnelStatus.canRequestStop
        connectTask?.cancel()
        connectTask = nil
        connectTaskID = nil
        if shouldLogStop {
            appendEventLog(
                "Stopping Host WireGuard tunnel because \(reason)."
            )
        }
        Task { @MainActor [weak self] in
            await self?.tunnelController.disconnect(waitUntilStopped: false)
        }
    }

    func clearDiscoveredEndpoint(
        reason: String,
        alwaysDisconnectTunnel: Bool = true
    ) {
        let previousResolvedEndpoint = resolvedEndpoint
        guard discoveredEndpoint != nil else {
            if alwaysDisconnectTunnel {
                cancelTunnel(reason: reason)
            }
            return
        }

        discoveredEndpoint = nil
        revalidateConnectionField(.endpoint)
        if alwaysDisconnectTunnel || resolvedEndpoint != previousResolvedEndpoint {
            cancelTunnel(reason: reason)
        }
        appendEventLog("WireGuard endpoint cleared: \(reason).")
        notifyReadinessChange()
    }

    func updateDiscoveredEndpoint(_ endpoint: String) {
        guard endpoint != discoveredEndpoint else {
            return
        }

        let previousResolvedEndpoint = resolvedEndpoint
        discoveredEndpoint = endpoint
        revalidateConnectionField(.endpoint)
        if resolvedEndpoint != previousResolvedEndpoint,
           hostTunnelStatus.canRequestStop || connectTask != nil {
            cancelTunnel(reason: "VM WireGuard endpoint changed")
        }
        appendEventLog(
            "WireGuard guest address discovered from guest console: \(endpoint)."
        )
        notifyReadinessChange()
    }

    func updateHostTunnelStatus(_ status: HostWireGuardTunnelStatus) {
        hostTunnelStatus = status
        appendEventLog("Provider: \(status.eventLogDescription)")
        notifyReadinessChange()
    }

    func updateSystemExtensionStatus(_ status: WireGuardSystemExtensionStatus) {
        guard !isPreparingForApplicationTermination,
              systemExtensionStatus != status else {
            return
        }
        systemExtensionStatus = status
        appendEventLog("Network Extension: \(status.eventLogDescription)")
        notifyReadinessChange()
    }

    private var resolvedDNSServersText: String {
        normalizedInput(dnsServersText)
            ?? configurationBuilder.elements.dnsServers.joined(separator: ", ")
    }

    private func configureTunnelController() {
        tunnelController.onStatusChange = { [weak self] status in
            self?.updateHostTunnelStatus(status)
        }
        tunnelController.onSystemExtensionStatusChange = { [weak self] status in
            self?.updateSystemExtensionStatus(status)
        }
        tunnelController.onEventLog = { [weak self] message in
            guard let self, !self.isPreparingForApplicationTermination else {
                return
            }
            self.appendEventLog(message)
        }
    }

    private func prepareConfiguration() {
        do {
            let prepared = try configurationStore.prepareConfigurationIfNeeded(
                builder: configurationBuilder
            )
            keyMaterial = prepared.keyMaterial
            appendEventLog(
                "Prepared WireGuard configuration from Application Support keys: " +
                    "\(prepared.files.wireGuardDirectoryURL.path)."
            )
        } catch {
            keyMaterial = nil
            appendEventLog(
                "WireGuard key/configuration initialization failed without replacing " +
                    "existing keys: \(EventLogErrorFormatter.description(for: error))"
            )
        }
    }

    private func revalidateConnectionField(_ field: WireGuardConnectionField) {
        let isValid: Bool
        switch field {
        case .endpoint:
            guard let endpoint = normalizedInput(endpointText) ?? discoveredEndpoint else {
                var errors = invalidConnectionFields
                errors.remove(.endpoint)
                if errors != invalidConnectionFields {
                    invalidConnectionFields = errors
                }
                return
            }
            isValid = WireGuardConnectionValidator.isValidEndpoint(endpoint)
        case .allowedIPs:
            isValid = WireGuardConnectionValidator.isValidAllowedIPs(
                resolvedAllowedIPs
            )
        case .dnsServers:
            isValid = WireGuardConnectionValidator.isValidDNSServers(
                resolvedDNSServersText
            )
        }

        var errors = invalidConnectionFields
        if isValid {
            errors.remove(field)
        } else {
            errors.insert(field)
        }
        if errors != invalidConnectionFields {
            invalidConnectionFields = errors
        }
    }

    private func revalidateAllConnectionFields() {
        WireGuardConnectionField.allCases.forEach(revalidateConnectionField)
    }

    private func currentInvalidConnectionFields() -> Set<WireGuardConnectionField> {
        WireGuardConnectionValidator.invalidFields(
            endpoint: resolvedEndpoint,
            allowedIPs: resolvedAllowedIPs,
            dnsServers: resolvedDNSServersText
        )
    }

    private func normalizedInput(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func notifyReadinessChange() {
        onReadinessChange?()
    }

    private func appendEventLog(_ message: String) {
        eventLog.append(message, source: .wireGuard)
    }

    private static func restoredInput(
        defaults: UserDefaults,
        key: String
    ) -> String {
        guard defaults.object(forKey: key) != nil else {
            return ""
        }
        return defaults.string(forKey: key) ?? ""
    }

    private enum DefaultsKey {
        static let dnsServersText = "WireGuard.dnsServers"
        static let endpointText = "WireGuard.endpointOverride"
        static let allowedIPsText = "WireGuard.allowedIPs"
    }
}
