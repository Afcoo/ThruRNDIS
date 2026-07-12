/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct VirtualMachineView: View {
    @EnvironmentObject private var store: TetheringStore
    @State private var assetFolderLoadAlert: AssetFolderLoadAlert?

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
                LabeledContent("Asset folder") {
                    Text(store.vmAssetFolderInitialURL?.path ?? "Not selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    Button("Choose Asset Folder…") {
                        if let url = FilePicker.chooseDirectory(
                            title: "Choose VM asset folder",
                            initialURL: store.vmAssetFolderInitialURL
                        ), let error = store.loadVMAssets(from: url) {
                            assetFolderLoadAlert = AssetFolderLoadAlert(message: error.localizedDescription)
                        }
                    }
                    .disabled(!store.canEditVMConfiguration)

                    Button("Clear") {
                        store.clearVMAssets()
                    }
                    .disabled(!store.canClearVMAssets)
                    .help("Clear the selected VM asset paths without deleting files.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Asset Overrides") {
                SettingsAssetRow(
                    title: "Linux kernel",
                    url: store.kernelURL,
                    systemImage: "doc"
                ) {
                    if let url = FilePicker.chooseFile(
                        title: "Choose Linux kernel",
                        initialURL: store.kernelURL
                    ) {
                        store.kernelURL = url
                    }
                }

                SettingsAssetRow(
                    title: "RTPVM initramfs",
                    url: store.initialRamdiskURL,
                    systemImage: "doc.zipper"
                ) {
                    if let url = FilePicker.chooseFile(
                        title: "Choose initial ramdisk",
                        initialURL: store.initialRamdiskURL
                    ) {
                        store.initialRamdiskURL = url
                    }
                }

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
                    clear: {
                        store.diskImageURL = nil
                    }
                )
            }
            .disabled(!store.canEditVMConfiguration)
        }
        .alert(item: $assetFolderLoadAlert) { alert in
            Alert(
                title: Text("Invalid VM Asset Folder"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct AssetFolderLoadAlert: Identifiable {
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
