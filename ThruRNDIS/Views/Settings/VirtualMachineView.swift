/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct VirtualMachineView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var vmConfiguration: VMConfigurationStore
    @EnvironmentObject private var wireGuardSession: WireGuardSessionStore
    @EnvironmentObject private var assetWorkflowCoordinator: VMAssetWorkflowCoordinator

    let openConsole: () -> Void

    var body: some View {
        Form {
            if !store.runtimeEntitlements.virtualization {
                Section {
                    Label(
                        "Virtual machines are unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Virtual Machine") {
                LabeledContent("Status") {
                    SettingsStatusLabel(
                        title: vmStatusTitle,
                        appearance: vmStatusAppearance
                    )
                }

                Text(store.statusMessage)
                    .foregroundStyle(.secondary)

                HStack {
                    if store.runtimeState == .running {
                        Button("Restart") {
                            store.restartVirtualMachine()
                        }
                        .disabled(!store.canRestartVirtualMachine)
                    } else {
                        Button("Start") {
                            store.startVirtualMachine()
                        }
                        .disabled(
                            !store.canStartVirtualMachine
                                || !wireGuardSession.hasKeyMaterial
                        )
                    }

                    Button("Stop") {
                        store.stopVirtualMachine()
                    }
                    .disabled(!store.canStopVirtualMachine)

                    Spacer()

                    Button(action: openConsole) {
                        Label("Open VM Console…", systemImage: "terminal")
                    }
                }
            }

            Section("Runtime") {
                HStack(spacing: 32) {
                    LabeledContent("CPUs") {
                        HStack(spacing: 6) {
                            TextField(
                                "CPUs",
                                value: cpuCountBinding,
                                format: .number.grouping(.never)
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 48)

                            Stepper("CPUs", value: cpuCountBinding, in: 1...8)
                                .labelsHidden()
                        }
                    }
                    .frame(maxWidth: .infinity)

                    LabeledContent("Memory") {
                        HStack(spacing: 6) {
                            TextField(
                                "Memory",
                                value: memorySizeBinding,
                                format: .number.grouping(.never)
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)

                            Text(verbatim: "MiB")
                                .foregroundStyle(.secondary)

                            Stepper(
                                "Memory",
                                value: memorySizeBinding,
                                in: vmConfiguration.memorySizeRangeMiB,
                                step: vmConfiguration.memorySizeStepMiB
                            )
                            .labelsHidden()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kernel arguments")
                    TextEditor(text: $vmConfiguration.kernelCommandLine)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 56)
                }
            }
            .disabled(!store.canEditVMConfiguration)

            Section {
                VMAssetConfigurationView()
            } header: {
                Text("VM Assets")
            } footer: {
                VMAssetDocumentationLinkView()
            }

            Section("Asset Overrides") {
                SettingsAssetRow(
                    title: "Linux kernel",
                    url: assetWorkflowCoordinator.kernelURL,
                    systemImage: "doc",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: String(localized: "Choose Linux kernel override"),
                            initialURL: assetWorkflowCoordinator.kernelURL
                        ) {
                            assetWorkflowCoordinator.setKernelOverride(url)
                        }
                    },
                    clear: assetWorkflowCoordinator.kernelOverrideURL == nil ? nil : {
                        assetWorkflowCoordinator.setKernelOverride(nil)
                    }
                )

                SettingsAssetRow(
                    title: "ThruRNDIS initramfs",
                    url: assetWorkflowCoordinator.initialRamdiskURL,
                    systemImage: "doc.zipper",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: String(localized: "Choose initial ramdisk override"),
                            initialURL: assetWorkflowCoordinator.initialRamdiskURL
                        ) {
                            assetWorkflowCoordinator.setInitialRamdiskOverride(url)
                        }
                    },
                    clear: assetWorkflowCoordinator.initialRamdiskOverrideURL == nil ? nil : {
                        assetWorkflowCoordinator.setInitialRamdiskOverride(nil)
                    }
                )
            }
            .disabled(!store.canEditVMConfiguration || assetWorkflowCoordinator.isBusy || assetWorkflowCoordinator.currentSelection == nil)

            Section("Optional Storage") {
                SettingsAssetRow(
                    title: "Scratch disk",
                    url: vmConfiguration.diskImageURL,
                    systemImage: "internaldrive",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: String(localized: "Choose optional scratch disk image"),
                            initialURL: vmConfiguration.diskImageURL
                        ) {
                            vmConfiguration.diskImageURL = url
                        }
                    },
                    clear: vmConfiguration.diskImageURL == nil ? nil : {
                        vmConfiguration.diskImageURL = nil
                    }
                )
            }
            .disabled(!store.canEditVMConfiguration)
        }
        .vmAssetErrorAlert()
    }

    private var cpuCountBinding: Binding<Int> {
        Binding(
            get: { vmConfiguration.cpuCount },
            set: { newValue in
                vmConfiguration.cpuCount = min(max(newValue, 1), 8)
            }
        )
    }

    private var memorySizeBinding: Binding<Int> {
        Binding(
            get: { vmConfiguration.memorySizeMiB },
            set: { newValue in
                vmConfiguration.memorySizeMiB = min(
                    max(newValue, vmConfiguration.memorySizeRangeMiB.lowerBound),
                    vmConfiguration.memorySizeRangeMiB.upperBound
                )
            }
        )
    }

    private var vmStatusTitle: String {
        guard store.runtimeEntitlements.virtualization else {
            return String(localized: "Inactive")
        }

        if store.isRestartingVirtualMachine {
            return String(localized: "Restarting")
        }

        switch store.runtimeState {
        case .idle, .stopped:
            return String(localized: "Stopped")
        case .starting:
            return String(localized: "Starting")
        case .running:
            return String(localized: "Running")
        case .stopping:
            return String(localized: "Stopping")
        case .failed:
            return String(localized: "Failed")
        }
    }

    private var vmStatusAppearance: SettingsStatusAppearance {
        guard store.runtimeEntitlements.virtualization else {
            return .inactive
        }

        if store.isRestartingVirtualMachine {
            return .transitioning
        }

        switch store.runtimeState {
        case .idle, .stopped:
            return .stopped
        case .starting, .stopping:
            return .transitioning
        case .running:
            return .active
        case .failed:
            return .failed
        }
    }
}

private struct SettingsAssetRow: View {
    let title: LocalizedStringKey
    let url: URL?
    let systemImage: String
    let choose: () -> Void
    var clear: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)

                Spacer()

                if let url {
                    Text(verbatim: url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not selected")
                        .foregroundStyle(.secondary)
                }

                Button("Choose…", action: choose)

                if let clear, url != nil {
                    Button("Clear", action: clear)
                }
            }

            if let url {
                Text(verbatim: url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
