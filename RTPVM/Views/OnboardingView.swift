/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: TetheringStore
    @State private var step = 0
    @State private var alert: OnboardingAlert?

    let onFinish: () -> Void

    private let readmeURL = URL(
        string: "https://github.com/Afcoo/RNDIS-Tethering-VM-Passthrough/blob/main/README.en.md#vm-assets"
    )!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)

            ScrollView(.vertical) {
                Group {
                    switch step {
                    case 0:
                        welcomeStep
                    case 1:
                        assetBuildStep
                    default:
                        assetSelectionStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if step > 0 {
                    Button("Back") {
                        step -= 1
                    }
                }

                Spacer()

                if step < 2 {
                    Button("Continue") {
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Finish") {
                        store.completeOnboarding()
                        if store.hasConfiguredVMAssets {
                            onFinish()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.hasConfiguredVMAssets)
                }
            }
            .padding(12)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text("Invalid VM Asset Folder"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Welcome to RTPVM")
                .font(.largeTitle.bold())

            Text("RTPVM keeps the VM stopped until you approve a USB tethering device.\nIt then starts the Linux VM and attaches exactly one USB device for that VM session.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                onboardingPoint("The AccessoryAccess listener runs whenever the app is open.", image: "dot.radiowaves.left.and.right")
                onboardingPoint("VM and USB actions stay available from the menu bar.", image: "menubar.rectangle")
                onboardingPoint("Assets, CPU, memory, USB controls, and console live in Settings.", image: "gearshape")
            }

        }
    }

    private var assetBuildStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Build the VM Assets", systemImage: "shippingbox")
                .font(.largeTitle.bold())

            Text("Linux assets are not bundled with RTPVM.\nBuild them from the repository before selecting the generated folder.")
                .font(.title3)
                .foregroundStyle(.secondary)

            onboardingCommand(
                title: "Install WireGuard tools",
                command: "brew install wireguard-tools"
            )

            onboardingCommand(
                title: "From the repository root",
                command: "./script/make_vm_assets"
            )

            HStack {
                Label("Output: script/assets", systemImage: "folder")
                    .font(.headline)

                Spacer()

                Link("Open GitHub README", destination: readmeURL)
            }

        }
    }

    private var assetSelectionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Select the Asset Folder", systemImage: "folder.badge.gearshape")
                .font(.largeTitle.bold())

            Text("Choose the generated assets folder.\nRTPVM validates the Linux kernel, custom initramfs, and generated WireGuard server/client configs before saving the selection.")
                .font(.title3)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Folder") {
                        Text(store.vmAssetFolderInitialURL?.path ?? "Not selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(store.hasConfiguredVMAssets ? .primary : .secondary)
                    }

                    if store.hasConfiguredVMAssets {
                        Label("Kernel, initramfs, and WireGuard configs are ready.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("A valid asset folder is required to finish.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    Button("Choose Asset Folder…") {
                        guard let url = FilePicker.chooseDirectory(
                            title: "Choose VM asset folder",
                            initialURL: store.vmAssetFolderInitialURL
                        ) else {
                            return
                        }

                        if let error = store.loadVMAssets(from: url) {
                            alert = OnboardingAlert(message: error.localizedDescription)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canEditVMConfiguration)
                }
                .padding(.vertical, 2)
            }

            Link("Read the VM Assets guide on GitHub", destination: readmeURL)

        }
    }

    private func onboardingPoint(_ title: String, image: String) -> some View {
        Label(title, systemImage: image)
            .font(.headline)
    }

    private func onboardingCommand(title: String, command: String) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                Spacer()

                Button {
                    Clipboard.copy(command)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct OnboardingAlert: Identifiable {
    let id = UUID()
    let message: String
}
