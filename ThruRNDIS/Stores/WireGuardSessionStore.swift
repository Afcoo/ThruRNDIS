/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import Foundation

@MainActor
final class WireGuardSessionStore: ObservableObject {
    @Published private(set) var tunnelStatus: WireGuardTunnelStatus = .unconfigured
    @Published private(set) var tunnelFailure: WireGuardTunnelFailure?
    @Published private(set) var systemExtensionStatus: WireGuardSystemExtensionStatus = .notChecked
    @Published private(set) var discoveredEndpoint: String?
    @Published private(set) var invalidConnectionFields: Set<WireGuardConnectionField> = []
    @Published private(set) var keyMaterial: WireGuardKeyMaterial?
    @Published private(set) var wireGuardConnectionPrompt: WireGuardConnectionPrompt?
    @Published private var systemExtensionActivationTask: Task<Void, Never>?

    @Published var dnsServersText: String {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(dnsServersText, forKey: DefaultsKey.dnsServersText)
            refreshConnectionConfiguration()
            notifyReadinessChange()
        }
    }

    @Published var endpointText: String {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(endpointText, forKey: DefaultsKey.endpointText)
            refreshConnectionConfiguration()
            notifyReadinessChange()
        }
    }

    @Published var allowedIPsText: String {
        didSet {
            guard !isResettingPersistedValues else {
                return
            }
            defaults.set(allowedIPsText, forKey: DefaultsKey.allowedIPsText)
            refreshConnectionConfiguration()
            notifyReadinessChange()
        }
    }

    var onReadinessChange: (() -> Void)?

    private let configurationStore: WireGuardConfigurationStore
    private let configurationBuilder: WireGuardConfigurationBuilder
    private let tunnelController: WireGuardTunnelController
    private let eventLog: EventLogStore
    private let systemExtensionSettingsOpener: @MainActor () -> Bool
    private let defaults: UserDefaults
    private var connectTask: Task<Void, Never>?
    private var connectTaskID: UUID?
    private var isPreparingForApplicationTermination = false
    private var isResettingPersistedValues = false
    private var connectionConfiguration: WireGuardConnectionConfiguration?

    init(
        configurationStore: WireGuardConfigurationStore,
        configurationBuilder: WireGuardConfigurationBuilder,
        tunnelController: WireGuardTunnelController,
        eventLog: EventLogStore,
        systemExtensionSettingsOpener: @escaping @MainActor () -> Bool = {
            NetworkExtensionSettingsOpener.open()
        },
        defaults: UserDefaults = .standard,
        shouldRefreshManagedWireGuardStatus: Bool = true
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

        if shouldRefreshManagedWireGuardStatus {
            refreshSystemExtensionStatus()
            Task { @MainActor [weak self] in
                await self?.tunnelController.refreshStatus()
            }
        }
    }

    var hasKeyMaterial: Bool {
        keyMaterial != nil
    }

    var isSystemExtensionActivationInProgress: Bool {
        systemExtensionActivationTask != nil
    }

    var configurationDirectoryURL: URL {
        configurationStore.files.wireGuardDirectoryURL
    }

    var sharedConfigurationDirectoryURL: URL {
        configurationStore.sharedDirectoryURL
    }

    var canExportConfiguration: Bool {
        connectionConfiguration != nil
    }

    var resolvedEndpoint: String? {
        normalizedInput(endpointText) ?? discoveredEndpoint
    }

    var resolvedAllowedIPs: String {
        normalizedInput(allowedIPsText)
            ?? configurationBuilder.elements.clientAllowedIPs
                .joined(separator: ", ")
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
        tunnelStatus.canRequestStop
    }

    var renderedClientConfiguration: String {
        guard keyMaterial != nil else {
            return "# WireGuard key material is unavailable in Application Support."
        }
        guard let connectionConfiguration else {
            return "# A valid VM endpoint and connection settings are required."
        }
        return WgQuickConfigurationRenderer().render(connectionConfiguration)
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
            refreshConnectionConfiguration()
            appendEventLog(
                "Regenerated WireGuard configuration.",
                level: .debug
            )
            appendEventLog(
                "WireGuard configuration regeneration details: directory=" +
                    "\(prepared.files.wireGuardDirectoryURL.path), reason=\(reason).",
                level: .debug
            )
            notifyReadinessChange()
            return true
        } catch {
            keyMaterial = nil
            refreshConnectionConfiguration()
            appendEventLog(
                "WireGuard configuration load failed: " +
                    EventLogErrorFormatter.description(for: error),
                level: .error
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
        refreshConnectionConfiguration()
        wireGuardConnectionPrompt = nil
        updateTunnelFailure(nil)
        notifyReadinessChange()
    }

    func presentWireGuardConnectionPrompt(for accessory: USBAccessoryRecord) {
        wireGuardConnectionPrompt = WireGuardConnectionPrompt(accessory: accessory)
    }

    func takeWireGuardConnectionPrompt(id promptID: UUID) -> WireGuardConnectionPrompt? {
        guard wireGuardConnectionPrompt?.id == promptID else {
            return nil
        }
        defer { wireGuardConnectionPrompt = nil }
        return wireGuardConnectionPrompt
    }

    func clearWireGuardConnectionPrompt() {
        wireGuardConnectionPrompt = nil
    }

    private func hasValidConnectionInputs() -> Bool {
        var fields = invalidConnectionFields
        if resolvedEndpoint == nil {
            fields.insert(.endpoint)
        }
        guard fields.isEmpty else {
            let invalidFieldNames = WireGuardConnectionField.allCases
                .filter(fields.contains)
                .map(\.displayName)
                .joined(separator: ", ")
            appendEventLog(
                "WireGuard tunnel not started: invalid connection values " +
                    "(\(invalidFieldNames)).",
                level: .warning
            )
            return false
        }
        return true
    }

    @discardableResult
    func connect() -> Bool {
        guard hasValidConnectionInputs() else {
            return false
        }
        guard systemExtensionStatus.isActive else {
            appendEventLog(
                "WireGuard tunnel not started: network extension is not active.",
                level: .error
            )
            return false
        }
        guard let configuration = connectionConfiguration else {
            updateTunnelStatus(.unconfigured)
            appendEventLog(
                "WireGuard tunnel not started: connection configuration is not ready.",
                level: .warning
            )
            return false
        }
        updateTunnelFailure(nil)
        connectTask?.cancel()
        let taskID = UUID()
        connectTaskID = taskID
        connectTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.tunnelController.connect(configuration: configuration)
            guard self.connectTaskID == taskID else {
                return
            }
            self.connectTask = nil
            self.connectTaskID = nil
        }
        return true
    }

    func disconnect() {
        cancelPendingConnectTask()
        let controller = tunnelController
        Task { @MainActor in
            await controller.disconnect(waitUntilStopped: false)
        }
    }

    @discardableResult
    func disconnectAndWait() async -> Bool {
        cancelPendingConnectTask()
        return await tunnelController.disconnect(waitUntilStopped: true)
    }

    @discardableResult
    func removeSavedTunnelIfNeeded() async -> Bool {
        cancelPendingConnectTask()
        return await tunnelController.removeSavedTunnelIfNeeded()
    }

    func refreshTunnelStatus() {
        let allowsTransitionRefresh = tunnelStatus.isTransitioning
            && tunnelFailure != nil
        Task { @MainActor [weak self] in
            await self?.tunnelController.refreshStatus(
                allowDuringTransition: allowsTransitionRefresh
            )
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
        }
        return true
    }

    func openSystemExtensionSettings() {
        guard !isPreparingForApplicationTermination else {
            return
        }
        guard systemExtensionSettingsOpener() else {
            appendEventLog(
                "Could not open Network Extensions settings.",
                level: .error
            )
            return
        }
        appendEventLog(
            "Opened Network Extensions settings.",
            level: .info
        )
    }

    func stopForApplicationTermination() async -> Bool {
        wireGuardConnectionPrompt = nil
        cancelPendingConnectTask()
        systemExtensionActivationTask?.cancel()
        systemExtensionActivationTask = nil
        tunnelController.cancelPendingSystemExtensionOperations()
        return await tunnelController.disconnect(waitUntilStopped: true)
    }

    func finishApplicationTerminationPreparation() {
        isPreparingForApplicationTermination = true
        tunnelController.invalidateSystemExtensionOperations()
    }

    func cancelTunnel(reason: String) {
        guard connectTask != nil || tunnelStatus.canRequestStop else {
            return
        }
        let shouldLogStop = tunnelStatus.canRequestStop
        cancelPendingConnectTask()
        if shouldLogStop {
            appendEventLog(
                "Stopping WireGuard tunnel because \(reason).",
                level: .debug
            )
        }
        let controller = tunnelController
        Task { @MainActor in
            await controller.disconnect(waitUntilStopped: false)
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
        refreshConnectionConfiguration()
        if alwaysDisconnectTunnel || resolvedEndpoint != previousResolvedEndpoint {
            cancelTunnel(reason: reason)
        }
        appendEventLog(
            "WireGuard endpoint cleared: \(reason).",
            level: .debug
        )
        notifyReadinessChange()
    }

    func updateDiscoveredEndpoint(_ endpoint: String) {
        guard endpoint != discoveredEndpoint else {
            return
        }

        let previousResolvedEndpoint = resolvedEndpoint
        discoveredEndpoint = endpoint
        refreshConnectionConfiguration()
        if resolvedEndpoint != previousResolvedEndpoint,
           tunnelStatus.canRequestStop || connectTask != nil {
            cancelTunnel(reason: "VM WireGuard endpoint changed")
        }
        appendEventLog(
            "WireGuard guest address discovered from guest console.",
            level: .debug
        )
        appendEventLog(
            "Discovered WireGuard guest endpoint: \(endpoint).",
            level: .debug
        )
        notifyReadinessChange()
    }

    func updateTunnelStatus(_ status: WireGuardTunnelStatus) {
        guard tunnelStatus != status else {
            return
        }
        tunnelStatus = status
        appendEventLog(
            "Provider: \(status.eventLogDescription)",
            level: Self.eventLogLevel(for: status)
        )
        notifyReadinessChange()
    }

    func updateTunnelFailure(_ failure: WireGuardTunnelFailure?) {
        guard tunnelFailure != failure else {
            return
        }
        tunnelFailure = failure
    }

    func updateSystemExtensionStatus(_ status: WireGuardSystemExtensionStatus) {
        guard !isPreparingForApplicationTermination,
              systemExtensionStatus != status else {
            return
        }
        systemExtensionStatus = status
        appendEventLog(
            "Network Extension: \(status.eventLogDescription)",
            level: Self.eventLogLevel(for: status)
        )
        notifyReadinessChange()
    }

    private var resolvedDNSServersText: String {
        normalizedInput(dnsServersText)
            ?? configurationBuilder.elements.dnsServers.joined(separator: ", ")
    }

    private func refreshConnectionConfiguration() {
        let endpointValue = resolvedEndpoint
        let endpoint = endpointValue.flatMap {
            WireGuardConnectionValidator.endpoint(from: $0)
        }
        let allowedIPs = WireGuardConnectionValidator.allowedIPRanges(
            from: resolvedAllowedIPs
        )
        let dnsServers = WireGuardConnectionValidator.dnsServerAddresses(
            from: resolvedDNSServersText
        )

        var invalidFields: Set<WireGuardConnectionField> = []
        if endpointValue != nil, endpoint == nil {
            invalidFields.insert(.endpoint)
        }
        if allowedIPs == nil {
            invalidFields.insert(.allowedIPs)
        }
        if dnsServers == nil {
            invalidFields.insert(.dnsServers)
        }
        invalidConnectionFields = invalidFields

        guard let keyMaterial, let endpoint, let allowedIPs, let dnsServers else {
            connectionConfiguration = nil
            return
        }
        connectionConfiguration = configurationBuilder.connectionConfiguration(
            keyMaterial: keyMaterial,
            endpoint: endpoint,
            dnsServers: dnsServers,
            allowedIPs: allowedIPs
        )
    }

    private func configureTunnelController() {
        tunnelController.onStatusChange = { [weak self] status in
            self?.updateTunnelStatus(status)
        }
        tunnelController.onFailureChange = { [weak self] failure in
            self?.updateTunnelFailure(failure)
        }
        tunnelController.onSystemExtensionStatusChange = { [weak self] status in
            self?.updateSystemExtensionStatus(status)
        }
        tunnelController.onEventLog = { [weak self] message, level in
            guard let self, !self.isPreparingForApplicationTermination else {
                return
            }
            self.appendEventLog(message, level: level)
        }
    }

    private func cancelPendingConnectTask() {
        connectTask?.cancel()
        connectTask = nil
        connectTaskID = nil
    }

    private func prepareConfiguration() {
        do {
            let prepared = try configurationStore.prepareConfigurationIfNeeded(
                builder: configurationBuilder
            )
            keyMaterial = prepared.keyMaterial
            refreshConnectionConfiguration()
            appendEventLog(
                "Prepared WireGuard configuration from Application Support keys.",
                level: .debug
            )
            appendEventLog(
                "WireGuard Application Support directory: " +
                    "\(prepared.files.wireGuardDirectoryURL.path).",
                level: .debug
            )
        } catch {
            keyMaterial = nil
            refreshConnectionConfiguration()
            appendEventLog(
                "WireGuard key/configuration initialization failed without replacing " +
                    "existing keys: \(EventLogErrorFormatter.description(for: error))",
                level: .error
            )
        }
    }

    private func normalizedInput(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func notifyReadinessChange() {
        onReadinessChange?()
    }

    private func appendEventLog(
        _ message: String,
        level: EventLogLevel
    ) {
        eventLog.append(message, level: level, category: .wireGuard)
    }

    private static func eventLogLevel(
        for status: WireGuardTunnelStatus
    ) -> EventLogLevel {
        switch status {
        case .connecting, .disconnecting:
            .debug
        case .disconnected, .connected:
            .info
        case .unconfigured:
            .warning
        }
    }

    private static func eventLogLevel(
        for status: WireGuardSystemExtensionStatus
    ) -> EventLogLevel {
        switch status {
        case .unknown(nil):
            .debug
        case .active:
            .info
        case .inactive:
            .warning
        case .unknown:
            .error
        }
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
