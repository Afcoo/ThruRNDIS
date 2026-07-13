/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import SwiftUI

struct VirtualMachineView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var assetController: VMAssetController
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
                Stepper(value: $store.cpuCount, in: 1...8) {
                    LabeledContent("CPUs", value: "\(store.cpuCount)")
                }

                Stepper(
                    value: $store.memorySizeMiB,
                    in: store.memorySizeRangeMiB,
                    step: store.memorySizeStepMiB
                ) {
                    LabeledContent("Memory", value: store.memorySizeLabel)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kernel arguments")
                    TextEditor(text: $store.kernelCommandLine)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 56)
                }
            }
            .disabled(!store.canEditVMConfiguration)

            Section("VM Assets") {
                LabeledContent("Status") {
                    Text(assetController.installState.statusText)
                        .foregroundStyle(assetStatusColor)
                }

                if let progress = assetController.installState.progress {
                    ProgressView(value: progress)
                }

                if let release = assetController.installedRelease {
                    LabeledContent("Managed release", value: release.displayName)
                }

                LabeledContent("Asset folder") {
                    Text(assetController.selectedFolderURL?.path ?? "Not selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    if assetController.isBusy {
                        Button("Cancel") {
                            assetController.cancelInstall()
                        }
                    } else {
                        Button("Check & Install Latest") {
                            assetController.installLatest()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Choose Folder…") {
                        if let url = FilePicker.chooseDirectory(
                            title: "Choose extracted vm_assets folder",
                            initialURL: assetController.selectedFolderURL
                        ), let error = assetController.selectManualFolder(url) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    }
                    .disabled(assetController.isBusy)

                    if !assetController.installedReleases.isEmpty {
                        Button("Use Installed") {
                            if let error = assetController.useMostRecentInstalledAssets() {
                                assetAlert = VMAssetAlert(message: error.localizedDescription)
                            }
                        }
                        .disabled(assetController.isBusy)
                    }

                    Button("Clear") {
                        assetController.clearSelection()
                    }
                    .disabled(assetController.currentSelection == nil || assetController.isBusy)
                    .help("Clear the selected VM asset paths without deleting managed release files.")
                }
                .disabled(!store.canEditVMConfiguration)
            }

            Section("Asset Overrides") {
                SettingsAssetRow(
                    title: "Linux kernel",
                    url: assetController.kernelURL,
                    systemImage: "doc",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: "Choose Linux kernel override",
                            initialURL: assetController.kernelURL
                        ), let error = assetController.setKernelOverride(url) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    },
                    clear: assetController.kernelOverrideURL == nil ? nil : {
                        if let error = assetController.setKernelOverride(nil) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    }
                )

                SettingsAssetRow(
                    title: "ThruRNDIS initramfs",
                    url: assetController.initialRamdiskURL,
                    systemImage: "doc.zipper",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: "Choose initial ramdisk override",
                            initialURL: assetController.initialRamdiskURL
                        ), let error = assetController.setInitialRamdiskOverride(url) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    },
                    clear: assetController.initialRamdiskOverrideURL == nil ? nil : {
                        if let error = assetController.setInitialRamdiskOverride(nil) {
                            assetAlert = VMAssetAlert(message: error.localizedDescription)
                        }
                    }
                )
            }
            .disabled(!store.canEditVMConfiguration || assetController.isBusy || assetController.currentSelection == nil)

            Section("Optional Storage") {
                SettingsAssetRow(
                    title: "Scratch disk",
                    url: store.diskImageURL,
                    systemImage: "internaldrive",
                    choose: {
                        if let url = FilePicker.chooseFile(
                            title: "Choose optional scratch disk image",
                            initialURL: store.diskImageURL
                        ) {
                            store.diskImageURL = url
                        }
                    },
                    clear: store.diskImageURL == nil ? nil : {
                        store.diskImageURL = nil
                    }
                )
            }
            .disabled(!store.canEditVMConfiguration)
        }
        .onReceive(assetController.$errorMessage.compactMap { $0 }) { message in
            assetAlert = VMAssetAlert(message: message)
        }
        .alert(item: $assetAlert) { alert in
            Alert(
                title: Text("VM Asset Error"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    assetController.clearError()
                }
            )
        }
    }

    private var assetStatusColor: Color {
        switch assetController.installState {
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
