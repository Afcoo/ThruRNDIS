/*
Copyright (C) 2026 Afcoo.
*/

import Combine
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

@MainActor
final class VMConfigurationStore: ObservableObject {
    @Published var diskImageURL: URL? {
        didSet { persistFileURL(diskImageURL, forKey: DefaultsKey.diskImageURLPath) }
    }
    @Published var cpuCount: Int {
        didSet { defaults.set(cpuCount, forKey: DefaultsKey.cpuCount) }
    }
    @Published var memorySizeMiB: Int {
        didSet { defaults.set(memorySizeMiB, forKey: DefaultsKey.memorySizeMiB) }
    }
    @Published var kernelCommandLine: String {
        didSet { defaults.set(kernelCommandLine, forKey: DefaultsKey.kernelCommandLine) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.diskImageURL = Self.restoredDiskImageURL(defaults: defaults)
        self.cpuCount = Self.restoredCPUCount(defaults: defaults)
        self.memorySizeMiB = Self.restoredMemorySizeMiB(defaults: defaults)
        self.kernelCommandLine = Self.restoredKernelCommandLine(defaults: defaults)
        persistRestoredValues()
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

    func normalizedBootCommandLine() -> String {
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

        let rdinitInsertIndex = min(
            tokens.lastIndex(where: { $0.hasPrefix("console=") }).map { $0 + 1 } ?? 0,
            tokens.count
        )
        tokens.insert("rdinit=/sbin/init", at: rdinitInsertIndex)

        let moduleToken = "modules=\(AlpineBootDefaults.initramfsModules)"
        let moduleInsertIndex = min(
            tokens.lastIndex(where: {
                $0.hasPrefix("console=") || $0.hasPrefix("rdinit=")
            }).map { $0 + 1 } ?? tokens.count,
            tokens.count
        )
        tokens.insert(moduleToken, at: moduleInsertIndex)

        return tokens.joined(separator: " ")
    }

    func reset() {
        diskImageURL = nil
        cpuCount = 1
        memorySizeMiB = VMMemoryDefaults.defaultMiB
        kernelCommandLine = AlpineBootDefaults.initramfsKernelCommandLine

        defaults.removeObject(forKey: DefaultsKey.diskImageURLPath)
        defaults.removeObject(forKey: DefaultsKey.cpuCount)
        defaults.removeObject(forKey: DefaultsKey.memorySizeMiB)
        defaults.removeObject(forKey: DefaultsKey.kernelCommandLine)
    }

    private func persistFileURL(_ url: URL?, forKey key: String) {
        if let path = url?.standardizedFileURL.path {
            defaults.set(path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func persistRestoredValues() {
        persistFileURL(diskImageURL, forKey: DefaultsKey.diskImageURLPath)

        if defaults.object(forKey: DefaultsKey.cpuCount) != nil {
            defaults.set(cpuCount, forKey: DefaultsKey.cpuCount)
        }

        if defaults.object(forKey: DefaultsKey.memorySizeMiB) != nil {
            defaults.set(memorySizeMiB, forKey: DefaultsKey.memorySizeMiB)
        }
    }

    private static func restoredDiskImageURL(defaults: UserDefaults) -> URL? {
        guard let path = defaults.string(forKey: DefaultsKey.diskImageURLPath),
              !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.localizedCaseInsensitiveCompare("iso") != .orderedSame else {
            return nil
        }
        return url
    }

    private static func restoredCPUCount(defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: DefaultsKey.cpuCount) != nil else {
            return 1
        }
        return min(max(defaults.integer(forKey: DefaultsKey.cpuCount), 1), 8)
    }

    private static func restoredMemorySizeMiB(defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: DefaultsKey.memorySizeMiB) != nil else {
            return VMMemoryDefaults.defaultMiB
        }

        let restoredMemory = defaults.integer(forKey: DefaultsKey.memorySizeMiB)
        let clampedMemory = min(
            max(restoredMemory, VMMemoryDefaults.minimumMiB),
            VMMemoryDefaults.maximumMiB
        )
        return (clampedMemory / VMMemoryDefaults.stepMiB) * VMMemoryDefaults.stepMiB
    }

    private static func restoredKernelCommandLine(defaults: UserDefaults) -> String {
        guard let value = defaults.string(forKey: DefaultsKey.kernelCommandLine),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AlpineBootDefaults.initramfsKernelCommandLine
        }
        return value
    }

    private enum DefaultsKey {
        static let diskImageURLPath = "VMAssets.diskImageURLPath"
        static let cpuCount = "VM.cpuCount"
        static let memorySizeMiB = "VM.memorySizeMiB"
        static let kernelCommandLine = "VM.kernelCommandLine"
    }
}
