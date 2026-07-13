/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import SwiftUI

struct VirtualMachineView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var vmConfiguration: VMConfigurationStore
    @EnvironmentObject private var assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    @State private var assetAlert: VMAssetAlert?

    let openConsole: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: store.vmDisplayState.rawValue)

                Text(store.statusMessage)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Start") {
                        store.startVirtualMachine()
                    }
                    .disabled(!store.canStartVirtualMachine)

                    Button("Stop") {
                        store.stopVirtualMachine()
                    }
                    .disabled(!store.canStopVirtualMachine)

                    Button("Restart") {
                        store.restartVirtualMachine()
                    }
                    .disabled(!store.canRestartVirtualMachine)

                    Spacer()

                    Button(action: openConsole) {
                        Label("Open VM Console…", systemImage: "terminal")
                    }
                }
            }

            Section("Runtime") {
                Stepper(value: $vmConfiguration.cpuCount, in: 1...8) {
                    LabeledContent("CPUs", value: "\(vmConfiguration.cpuCount)")
                }

                Stepper(
                    value: $vmConfiguration.memorySizeMiB,
                    in: vmConfiguration.memorySizeRangeMiB,
                    step: vmConfiguration.memorySizeStepMiB
                ) {
                    LabeledContent("Memory", value: vmConfiguration.memorySizeLabel)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kernel arguments")
                    TextEditor(text: $vmConfiguration.kernelCommandLine)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 56)
                }
            }
            .disabled(!store.canEditVMConfiguration)

            Section("VM Assets") {
                LabeledContent("Status") {
                    Text(assetWorkflowCoordinator.installState.statusText)
                        .foregroundStyle(assetStatusColor)
                }

                if let progress = assetWorkflowCoordinator.installState.progress {
                    ProgressView(value: progress)
                }

                if let release = assetWorkflowCoordinator.installedRelease {
                    LabeledContent("Managed release", value: release.displayName)
                }

                LabeledContent("Asset folder") {
                    Text(assetWorkflowCoordinator.selectedFolderURL?.path ?? "Not selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    if assetWorkflowCoordinator.isBusy {
                        Button("Cancel") {
                            assetWorkflowCoordinator.cancelInstall()
                        }
                    } else {
                        Button("Check & Install Latest") {
                            assetWorkflowCoordinator.installLatest()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Choose Folder…") {
                        if let url = FilePicker.chooseDirectory(
                            title: "Choose extracted vm_assets folder",
                            initialURL: assetWorkflowCoordinator.selectedFolderURL
                        ), let error = assetWorkflowCoordinator.selectManualFolder(url) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    }
                    .disabled(assetWorkflowCoordinator.isBusy)

                    if !assetWorkflowCoordinator.installedReleases.isEmpty {
                        Button("Use Installed") {
                            if let error = assetWorkflowCoordinator.useMostRecentInstalledAssets() {
                                assetAlert = VMAssetAlert(message: error.localizedDescription)
                            }
                        }
                        .disabled(assetWorkflowCoordinator.isBusy)
                    }

                    Button("Clear") {
                        assetWorkflowCoordinator.clearSelection()
                    }
                    .disabled(assetWorkflowCoordinator.currentSelection == nil || assetWorkflowCoordinator.isBusy)
                    .help("Clear the selected VM asset paths without deleting managed release files.")
                }
                .disabled(!store.canEditVMConfiguration)
            }

            Section("Asset Overrides") {
                SettingsAssetRow(
                    title: "Linux kernel",
                    url: assetWorkflowCoordinator.kernelURL,
                    systemImage: "doc",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: "Choose Linux kernel override",
                            initialURL: assetWorkflowCoordinator.kernelURL
                        ), let error = assetWorkflowCoordinator.setKernelOverride(url) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    },
                    clear: assetWorkflowCoordinator.kernelOverrideURL == nil ? nil : {
                        if let error = assetWorkflowCoordinator.setKernelOverride(nil) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    }
                )

                SettingsAssetRow(
                    title: "ThruRNDIS initramfs",
                    url: assetWorkflowCoordinator.initialRamdiskURL,
                    systemImage: "doc.zipper",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: "Choose initial ramdisk override",
                            initialURL: assetWorkflowCoordinator.initialRamdiskURL
                        ), let error = assetWorkflowCoordinator.setInitialRamdiskOverride(url) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    },
                    clear: assetWorkflowCoordinator.initialRamdiskOverrideURL == nil ? nil : {
                        if let error = assetWorkflowCoordinator.setInitialRamdiskOverride(nil) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
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
                            title: "Choose optional scratch disk image",
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
        .onReceive(assetWorkflowCoordinator.$errorMessage.compactMap { $0 }) { message in
            assetAlert = VMAssetAlert(message: message)
        }
        .alert(item: $assetAlert) { alert in
            Alert(
                title: Text("VM Asset Error"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    assetWorkflowCoordinator.clearError()
                }
            )
        }
    }

    private var assetStatusColor: Color {
        switch assetWorkflowCoordinator.installState {
        case .ready:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }
}

private struct VMAssetAlert: Identifiable {
    let id = UUID()
    let message: String
}

private struct SettingsAssetRow: View {
    let title: String
    let url: URL?
    let systemImage: String
    let choose: () -> Void
    var clear: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)

                Spacer()

                Text(url?.lastPathComponent ?? "Not selected")
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button("Choose…", action: choose)

                if let clear, url != nil {
                    Button("Clear", action: clear)
                }
            }

            if let url {
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
