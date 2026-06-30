/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

private enum AlpineBootDefaults {
    static let initramfsModules = "virtio_pci,virtio_mmio,virtio_console"
    static let initramfsKernelCommandLine = "console=hvc0 rdinit=/sbin/init modules=\(initramfsModules)"
}

private enum VMMemoryDefaults {
    static let minimumMiB = 256
    static let maximumMiB = 16 * 1024
    static let defaultMiB = 1024
    static let stepMiB = 256
}

private struct VMAssetFolderSelection {
    let kernelURL: URL
    let initialRamdiskURL: URL
}

private enum VMAssetFolderLoadError: LocalizedError {
    case notDirectory(URL)
    case missingKernel(URL)
    case missingInitramfs(URL)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let url):
            return "Selected VM asset path is not a folder: \(url.path)"
        case .missingKernel(let url):
            return "No Image-* kernel found in VM asset folder: \(url.path)"
        case .missingInitramfs(let url):
            return "No initramfs-rtpvm-* ramdisk found in VM asset folder: \(url.path)"
        }
    }
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published var kernelURL: URL? {
        didSet {
            persistFileURL(kernelURL, forKey: DefaultsKey.kernelURLPath)
            reloadWireGuardConfigurationFromAssets(reason: "kernel selection changed")
        }
    }
    @Published var initialRamdiskURL: URL? {
        didSet {
            persistFileURL(initialRamdiskURL, forKey: DefaultsKey.initialRamdiskURLPath)
            reloadWireGuardConfigurationFromAssets(reason: "initramfs selection changed")
        }
    }
    @Published var diskImageURL: URL? {
        didSet { persistFileURL(diskImageURL, forKey: DefaultsKey.diskImageURLPath) }
    }
    @Published var cpuCount = 1
    @Published var memorySizeMiB = VMMemoryDefaults.defaultMiB
    @Published var kernelCommandLine = AlpineBootDefaults.initramfsKernelCommandLine

    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private(set) var statusMessage = "Select Alpine VM assets to begin."
    @Published private(set) var runtimeEntitlements = RuntimeEntitlementSnapshot.current
    @Published private(set) var accessories: [USBAccessoryRecord] = []
    @Published private(set) var isAccessoryMonitoring = false
    @Published var selectedAccessoryID: UInt64? {
        didSet {
            guard !isSyncingUSBState else { return }
            usbCoordinator.selectAccessory(id: selectedAccessoryID)
        }
    }
    @Published private(set) var attachedAccessoryID: UInt64?
    @Published private(set) var consoleText = ""
    @Published private(set) var consoleOutputData = Data()
    @Published private(set) var consoleOutputSequence = 0
    @Published private(set) var consoleResetSequence = 0
    @Published private(set) var eventLog = ""
    @Published private(set) var wireGuardSettings: WireGuardSettings
    @Published private(set) var wireGuardStatusMessage = "Run the asset build script, select the generated assets, then start the VM to discover the endpoint."

    let guestMACAddress = "02:00:5E:10:00:02"

    private let vmCoordinator = VMCoordinator()
    private let usbCoordinator = USBAccessoryCoordinator()
    private let wireguardConfLoader: WireguardConfLoader
    private var didRequestLaunchAccessoryMonitoring = false
    private var isSyncingUSBState = false

    var canStartVirtualMachine: Bool {
        kernelURL != nil && initialRamdiskURL != nil && runtimeState != .starting && runtimeState != .running
    }

    var memorySizeRangeMiB: ClosedRange<Int> {
        VMMemoryDefaults.minimumMiB...VMMemoryDefaults.maximumMiB
    }

    var memorySizeStepMiB: Int {
        VMMemoryDefaults.stepMiB
    }

    var memorySizeLabel: String {
        guard memorySizeMiB >= 1024 else {
            return "\(memorySizeMiB) MiB"
        }

        let wholeGiB = memorySizeMiB / 1024
        let remainderMiB = memorySizeMiB % 1024

        switch remainderMiB {
        case 0:
            return "\(wholeGiB) GiB"
        case 256:
            return "\(wholeGiB).25 GiB"
        case 512:
            return "\(wholeGiB).5 GiB"
        case 768:
            return "\(wholeGiB).75 GiB"
        default:
            return "\(memorySizeMiB) MiB"
        }
    }

    var vmAssetFolderInitialURL: URL? {
        if let configuredVMAssetFolderURL {
            return configuredVMAssetFolderURL
        }
        if let diskImageURL {
            return vmAssetFolderURL(containing: diskImageURL)
        }

        return nil
    }

    private var configuredVMAssetFolderURL: URL? {
        if let initialRamdiskURL {
            return vmAssetFolderURL(containing: initialRamdiskURL)
        }
        if let kernelURL {
            return vmAssetFolderURL(containing: kernelURL)
        }

        return nil
    }

    var canStartAccessoryMonitoring: Bool {
        runtimeEntitlements.accessoryAccessUSB && usbCoordinator.canStartMonitoring
    }

    var canStopAccessoryMonitoring: Bool {
        usbCoordinator.canStopMonitoring
    }

    var canStopVirtualMachine: Bool {
        vmCoordinator.canStop
    }

    var canSendConsoleInput: Bool {
        vmCoordinator.canSendConsoleInput
    }

    var canAttachSelectedAccessory: Bool {
        usbCoordinator.canAttachSelectedAccessory(runtimeState: runtimeState)
    }

    var canDetachAccessory: Bool {
        usbCoordinator.canDetachAccessory(runtimeState: runtimeState)
    }

    var canExportWireGuardConfiguration: Bool {
        wireGuardSettings.hasKeyMaterial && wireGuardSettings.endpoint != nil
    }

    var wireGuardHostConfiguration: String {
        wireguardConfLoader.hostConfiguration(settings: wireGuardSettings)
    }

    init() {
        let wireguardConfLoader = WireguardConfLoader()
        self.wireguardConfLoader = wireguardConfLoader
        self.wireGuardSettings = wireguardConfLoader.emptySettings()
        configureCoordinators()
        restoreAssetSelections()
        reloadWireGuardConfigurationFromAssets(reason: "restored asset selection")
        appendRuntimeEntitlementSummary()
        appendAssetSelectionSummaryIfNeeded()
    }

    func startAccessoryMonitoring() {
        startAccessoryMonitoring(reason: "manual request")
    }

    func startAccessoryMonitoringOnLaunch() {
        guard !didRequestLaunchAccessoryMonitoring else {
            return
        }

        didRequestLaunchAccessoryMonitoring = true
        startAccessoryMonitoring(reason: "app launch")
    }

    @discardableResult
    func loadVMAssets(from directoryURL: URL) -> Error? {
        do {
            let selection = try resolveVMAssetFolder(directoryURL)
            kernelURL = selection.kernelURL
            initialRamdiskURL = selection.initialRamdiskURL
            statusMessage = "Loaded VM assets from folder."
            appendEvent("Loaded VM assets from folder: \(directoryURL.standardizedFileURL.path).")
            return nil
        } catch {
            statusMessage = error.localizedDescription
            appendEvent("VM asset folder load failed: \(error.localizedDescription)")
            return error
        }
    }

    func stopAccessoryMonitoring() {
        usbCoordinator.stopMonitoring(reason: "User stopped USB listener.")
    }

    func startVirtualMachine() {
        refreshRuntimeEntitlements()
        migrateLegacyInitramfsSelectionIfNeeded()
        reloadWireGuardConfigurationFromAssets(reason: "VM starting")

        guard runtimeEntitlements.virtualization else {
            reportMissingEntitlement(.virtualization, action: "VM start")
            return
        }

        guard let kernelURL, let initialRamdiskURL else {
            statusMessage = "Kernel and RTPVM initramfs are required."
            return
        }

        clearWireGuardEndpoint(reason: "VM starting")
        clearConsoleForVMStart()
        usbCoordinator.resetForVMStart()
        syncUSBState()

        let bootCommandLine = normalizedBootCommandLine()
        if bootCommandLine != kernelCommandLine {
            kernelCommandLine = bootCommandLine
            appendEvent("Adjusted kernel arguments for initramfs-only boot.")
        }

        let input = VMCoordinatorStartInput(
            kernelURL: kernelURL,
            initialRamdiskURL: initialRamdiskURL,
            diskImageURL: diskImageURL,
            cpuCount: cpuCount,
            memorySizeMiB: memorySizeMiB,
            bootCommandLine: bootCommandLine,
            guestMACAddress: guestMACAddress
        )

        appendSelectedAssetDiagnostics(kernelURL: kernelURL, initialRamdiskURL: initialRamdiskURL)
        appendEvent("Kernel arguments: \(bootCommandLine)")
        vmCoordinator.start(input: input)
    }

    func stopVirtualMachine() {
        vmCoordinator.stop()
    }

    func attachSelectedAccessory() {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB attach")
            return
        }

        usbCoordinator.attachSelectedAccessory(to: vmCoordinator.virtualMachine)
    }

    func detachAccessory() {
        usbCoordinator.detachAccessory(from: vmCoordinator.virtualMachine)
    }

    func prepareForApplicationTermination() {
        appendEvent("Application terminating.")
        vmCoordinator.invalidate()
        usbCoordinator.stopMonitoring(reason: "Application terminating.")
    }

    func reloadWireGuardConfiguration() {
        reloadWireGuardConfigurationFromAssets(reason: "manual request", reportIfMissing: true)
    }

    func copyWireGuardConfiguration() {
        guard canExportWireGuardConfiguration else {
            wireGuardStatusMessage = "Wait for RTPVM_WG_ENDPOINT before copying the host configuration."
            appendEvent("WireGuard configuration not copied: VM endpoint is unknown.")
            return
        }

        Clipboard.copy(wireGuardHostConfiguration)
        wireGuardStatusMessage = "WireGuard host configuration copied."
        appendEvent("WireGuard host configuration copied to clipboard.")
    }

    func saveWireGuardConfiguration() {
        guard canExportWireGuardConfiguration else {
            wireGuardStatusMessage = "Wait for RTPVM_WG_ENDPOINT before saving the host configuration."
            appendEvent("WireGuard configuration not saved: VM endpoint is unknown.")
            return
        }

        guard let url = FilePicker.chooseSaveFile(
            title: "Save WireGuard Configuration",
            defaultName: "rtpvm.conf"
        ) else {
            return
        }

        do {
            try wireGuardHostConfiguration.write(to: url, atomically: true, encoding: .utf8)
            wireGuardStatusMessage = "WireGuard host configuration saved."
            appendEvent("WireGuard host configuration saved to \(url.path).")
        } catch {
            wireGuardStatusMessage = error.localizedDescription
            appendEvent("WireGuard configuration save failed: \(error.localizedDescription)")
        }
    }

    func clearWireGuardEndpoint() {
        clearWireGuardEndpoint(reason: "manual request")
    }

    func clearConsole() {
        consoleText = ""
        consoleOutputData = Data()
        consoleOutputSequence = 0
        consoleResetSequence &+= 1
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        vmCoordinator.sendConsoleBytes(data)
    }

    func clearEventLog() {
        eventLog = ""
    }

    private func configureCoordinators() {
        vmCoordinator.onStateChange = { [weak self] state, message in
            guard let self else { return }
            self.runtimeState = state
            self.statusMessage = message
        }
        vmCoordinator.onEvent = { [weak self] message in
            self?.appendEvent(message)
        }
        vmCoordinator.onConsoleOutput = { [weak self] data in
            self?.appendConsole(data)
        }
        vmCoordinator.onUSBPassthroughDisconnect = { [weak self] in
            self?.usbCoordinator.handlePassthroughDisconnect()
        }
        vmCoordinator.onStopped = { [weak self] in
            guard let self else { return }
            self.usbCoordinator.clearAttachmentForStoppedVM()
            self.syncUSBState()
        }

        usbCoordinator.onStateChange = { [weak self] in
            self?.syncUSBState()
        }
        usbCoordinator.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }
        usbCoordinator.onEvent = { [weak self] message in
            self?.appendEvent(message)
        }
        usbCoordinator.runtimeStateProvider = { [weak self] in
            self?.runtimeState ?? .idle
        }
        usbCoordinator.virtualMachineProvider = { [weak self] in
            self?.vmCoordinator.virtualMachine
        }

        syncUSBState()
    }

    private func startAccessoryMonitoring(reason: String) {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB listener")
            return
        }

        usbCoordinator.startMonitoring(reason: reason)
    }

    private func syncUSBState() {
        isSyncingUSBState = true
        accessories = usbCoordinator.accessories
        isAccessoryMonitoring = usbCoordinator.isAccessoryMonitoring
        selectedAccessoryID = usbCoordinator.selectedAccessoryID
        attachedAccessoryID = usbCoordinator.attachedAccessoryID
        isSyncingUSBState = false
    }

    private func restoreAssetSelections() {
        kernelURL = restoredFileURL(forKey: DefaultsKey.kernelURLPath)
        initialRamdiskURL = restoredFileURL(forKey: DefaultsKey.initialRamdiskURLPath)

        if let restoredDiskURL = restoredFileURL(forKey: DefaultsKey.diskImageURLPath),
           restoredDiskURL.pathExtension.localizedCaseInsensitiveCompare("iso") != .orderedSame {
            diskImageURL = restoredDiskURL
        } else {
            diskImageURL = nil
        }

        if canStartVirtualMachine {
            statusMessage = "Previous VM asset selection restored."
        } else if kernelURL != nil || initialRamdiskURL != nil || diskImageURL != nil {
            statusMessage = "Select missing Alpine RTPVM assets to begin."
        }
    }

    private func resolveVMAssetFolder(_ directoryURL: URL) throws -> VMAssetFolderSelection {
        let directory = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VMAssetFolderLoadError.notDirectory(directory)
        }

        let searchDirectories = [
            directory,
            directory.appendingPathComponent("boot", isDirectory: true)
        ]

        guard let kernelURL = firstAsset(
            in: searchDirectories,
            preferredNames: ["Image-lts", "Image-virt"],
            prefix: "Image-"
        ) else {
            throw VMAssetFolderLoadError.missingKernel(directory)
        }

        guard let initialRamdiskURL = firstAsset(
            in: searchDirectories,
            preferredNames: ["initramfs-rtpvm-lts", "initramfs-rtpvm-virt"],
            prefix: "initramfs-rtpvm-"
        ) else {
            throw VMAssetFolderLoadError.missingInitramfs(directory)
        }

        return VMAssetFolderSelection(kernelURL: kernelURL, initialRamdiskURL: initialRamdiskURL)
    }

    private func firstAsset(
        in directories: [URL],
        preferredNames: [String],
        prefix: String
    ) -> URL? {
        for directory in directories {
            for preferredName in preferredNames {
                let url = directory.appendingPathComponent(preferredName, isDirectory: false)
                if isRegularFile(url) {
                    return url
                }
            }
        }

        for directory in directories {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            if let match = urls
                .filter({ $0.lastPathComponent.hasPrefix(prefix) && isRegularFile($0) })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                .first {
                return match
            }
        }

        return nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true
        } catch {
            return false
        }
    }

    private func vmAssetFolderURL(containing url: URL) -> URL {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

        if directory.lastPathComponent == "boot" {
            return directory.deletingLastPathComponent()
        }

        return directory
    }

    private func normalizedBootCommandLine() -> String {
        let blockedKeys: Set<String> = [
            "alpine_repo",
            "ip",
            "modules",
            "panic",
            "pkgs",
            "quiet",
            "ro",
            "root",
            "rootflags",
            "rootfstype",
            "rw"
        ]

        var tokens = kernelCommandLine
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                let key = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                return !blockedKeys.contains(key) && key != "rdinit"
            }

        if !tokens.contains(where: { $0.hasPrefix("console=") }) {
            tokens.insert("console=hvc0", at: 0)
        }

        let rdinitInsertIndex = min(tokens.lastIndex(where: { $0.hasPrefix("console=") }).map { $0 + 1 } ?? 0, tokens.count)
        tokens.insert("rdinit=/sbin/init", at: rdinitInsertIndex)

        let moduleToken = "modules=\(AlpineBootDefaults.initramfsModules)"
        let insertIndex = min(
            tokens.lastIndex(where: { $0.hasPrefix("console=") || $0.hasPrefix("rdinit=") }).map { $0 + 1 } ?? tokens.count,
            tokens.count
        )
        tokens.insert(moduleToken, at: insertIndex)

        return tokens.joined(separator: " ")
    }

    private func migrateLegacyInitramfsSelectionIfNeeded() {
        guard let initialRamdiskURL,
              initialRamdiskURL.lastPathComponent.hasPrefix("initramfs-tui-") else {
            return
        }

        let replacementName = initialRamdiskURL.lastPathComponent.replacingOccurrences(
            of: "initramfs-tui-",
            with: "initramfs-rtpvm-",
            options: [.anchored]
        )
        let replacementURL = initialRamdiskURL
            .deletingLastPathComponent()
            .appendingPathComponent(replacementName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: replacementURL.path) else {
            return
        }

        self.initialRamdiskURL = replacementURL
        appendEvent("Updated legacy initramfs selection to \(replacementName).")
    }

    private func appendAssetSelectionSummaryIfNeeded() {
        var restoredAssets: [String] = []

        if kernelURL != nil {
            restoredAssets.append("kernel")
        }
        if initialRamdiskURL != nil {
            restoredAssets.append("initramfs")
        }
        if diskImageURL != nil {
            restoredAssets.append("scratch disk")
        }

        if !restoredAssets.isEmpty {
            appendEvent("Restored previous VM asset selection: \(restoredAssets.joined(separator: ", ")).")
        }
    }

    private func reloadWireGuardConfigurationFromAssets(
        reason: String,
        reportIfMissing: Bool = false
    ) {
        let assetFolderURL = configuredVMAssetFolderURL

        do {
            if let result = try wireguardConfLoader.loadGeneratedSettings(
                from: assetFolderURL,
                preservingEndpoint: wireGuardSettings.endpoint
            ) {
                wireGuardSettings = result.settings
                wireGuardStatusMessage = "Loaded generated WireGuard configuration."
                appendEvent("Loaded generated WireGuard configuration from \(result.sourceURL.path): \(reason).")
                return
            }

            if reportIfMissing {
                wireGuardStatusMessage = "Generated WireGuard configs were not found near the selected assets."
                appendEvent("WireGuard configuration not loaded: selected VM asset folder must contain wireguard/wg-server.conf and wireguard/wg-client.conf.")
            }
        } catch {
            wireGuardStatusMessage = error.localizedDescription
            appendEvent("WireGuard configuration load failed: \(error.localizedDescription)")
        }
    }

    private func restoredFileURL(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        if let migratedURL = migratedLegacyAssetURL(from: url) {
            UserDefaults.standard.set(migratedURL.standardizedFileURL.path, forKey: key)
            return migratedURL
        }

        return url
    }

    private func migratedLegacyAssetURL(from url: URL) -> URL? {
        let legacySegment = "/script/VMAssets/"
        let migratedSegment = "/script/assets/"
        let path = url.standardizedFileURL.path

        if let range = path.range(of: legacySegment) {
            let migratedPath = path.replacingCharacters(in: range, with: migratedSegment)
            guard FileManager.default.fileExists(atPath: migratedPath) else {
                return nil
            }

            return URL(fileURLWithPath: migratedPath)
        }

        guard let assetRange = path.range(of: migratedSegment) else {
            return nil
        }

        let suffix = path[assetRange.upperBound...]
        let pathComponents = suffix.split(separator: "/")

        guard pathComponents.count >= 3,
              pathComponents[1] == "boot",
              let fileName = pathComponents.last else {
            return nil
        }

        let flattenedPath = String(path[..<assetRange.upperBound]) + String(fileName)
        guard FileManager.default.fileExists(atPath: flattenedPath) else {
            return nil
        }

        return URL(fileURLWithPath: flattenedPath)
    }

    private func persistFileURL(_ url: URL?, forKey key: String) {
        if let path = url?.standardizedFileURL.path {
            UserDefaults.standard.set(path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func appendSelectedAssetDiagnostics(kernelURL: URL, initialRamdiskURL: URL) {
        appendEvent(assetDiagnosticText(label: "Kernel", url: kernelURL))
        appendEvent(assetDiagnosticText(label: "Initramfs", url: initialRamdiskURL))
    }

    private func assetDiagnosticText(label: String, url: URL) -> String {
        let path = url.standardizedFileURL.path

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            var details: [String] = []

            if let size = (attributes[.size] as? NSNumber)?.int64Value {
                details.append("size=\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }

            if let modified = attributes[.modificationDate] as? Date {
                details.append("modified=\(Self.assetDateFormatter.string(from: modified))")
            }

            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            return "\(label) asset: \(path)\(suffix)"
        } catch {
            return "\(label) asset: \(path) (metadata unavailable: \(error.localizedDescription))"
        }
    }

    private func refreshRuntimeEntitlements() {
        let snapshot = RuntimeEntitlementSnapshot.current
        if snapshot != runtimeEntitlements {
            runtimeEntitlements = snapshot
            appendRuntimeEntitlementSummary()
        }
    }

    private func appendRuntimeEntitlementSummary() {
        let summary = RuntimeEntitlement.allCases.map { entitlement in
            "\(entitlement.rawValue)=\(runtimeEntitlements.has(entitlement) ? "present" : "missing")"
        }
        appendEvent("Runtime entitlements: \(summary.joined(separator: ", ")).")
    }

    private func reportMissingEntitlement(_ entitlement: RuntimeEntitlement, action: String) {
        statusMessage = "\(entitlement.label) entitlement missing."
        appendEvent("\(action) not started: missing \(entitlement.rawValue). The default RNDIS Tethering VM Passthrough scheme is for local UI builds; run the RNDIS Tethering VM Passthrough Runtime scheme with an approved provisioning profile to exercise this runtime path.")
    }

    private func clearWireGuardEndpoint(reason: String) {
        guard wireGuardSettings.endpoint != nil else {
            return
        }

        var settings = wireGuardSettings
        settings.endpoint = nil
        wireGuardSettings = settings
        wireGuardStatusMessage = "Waiting for RTPVM_WG_ENDPOINT from guest."
        appendEvent("WireGuard endpoint cleared: \(reason).")
    }

    private func updateWireGuardEndpoint(from text: String) {
        let marker = "RTPVM_WG_ENDPOINT="
        guard let markerRange = text.range(of: marker, options: [.backwards]) else {
            return
        }

        let suffix = text[markerRange.upperBound...]
        guard let token = suffix.split(whereSeparator: \.isWhitespace).first else {
            return
        }

        let endpoint = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard endpoint.contains(":"),
              endpoint != wireGuardSettings.endpoint else {
            return
        }

        var settings = wireGuardSettings
        settings.endpoint = endpoint
        wireGuardSettings = settings
        wireGuardStatusMessage = "WireGuard guest address discovered: \(endpoint)."
        appendEvent("WireGuard guest address discovered from guest console: \(endpoint).")
    }

    private func clearConsoleForVMStart() {
        consoleText = ""
        consoleOutputData = Data()
        consoleOutputSequence = 0
        consoleResetSequence &+= 1
    }

    private func appendConsole(_ data: Data) {
        appendConsoleOutputData(data)

        if let text = String(data: data, encoding: .utf8) {
            consoleText.append(text)
            updateWireGuardEndpoint(from: consoleText)
        } else {
            consoleText.append(data.map { String(format: "%02X", $0) }.joined(separator: " "))
            consoleText.append("\n")
        }
        trimConsoleIfNeeded()
    }

    private func appendEvent(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        eventLog.append("[\(timestamp)] \(message)\n")
        trimEventLogIfNeeded()
    }

    private func trimConsoleIfNeeded() {
        let maximumCharacters = 200_000
        if consoleText.count > maximumCharacters {
            consoleText.removeFirst(consoleText.count - maximumCharacters)
        }
    }

    private func appendConsoleOutputData(_ data: Data) {
        var outputData = consoleOutputData
        outputData.append(data)

        let maximumBytes = 4_000_000
        if outputData.count > maximumBytes {
            outputData.removeFirst(outputData.count - maximumBytes)
            consoleResetSequence &+= 1
        }

        consoleOutputData = outputData
        consoleOutputSequence &+= 1
    }

    private func trimEventLogIfNeeded() {
        let maximumCharacters = 60_000
        if eventLog.count > maximumCharacters {
            eventLog.removeFirst(eventLog.count - maximumCharacters)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let assetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private enum DefaultsKey {
        static let kernelURLPath = "VMAssets.kernelURLPath"
        static let initialRamdiskURLPath = "VMAssets.initialRamdiskURLPath"
        static let diskImageURLPath = "VMAssets.diskImageURLPath"
    }
}
