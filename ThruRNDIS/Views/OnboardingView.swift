/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var assetController: VMAssetController
    @State private var step = 0
    @State private var alert: OnboardingAlert?

    let onFinish: () -> Void

    private let releasesURL = URL(
        string: "https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases"
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
                        assetInstallStep
                    default:
                        assetReadyStep
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
                        if assetController.hasConfiguredAssets {
                            onFinish()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!assetController.hasConfiguredAssets || assetController.isBusy)
                }
            }
            .padding(12)
        }
        .onReceive(assetController.$errorMessage.compactMap { $0 }) { message in
            alert = OnboardingAlert(message: message)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text("VM Asset Error"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    assetController.clearError()
                }
            )
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Welcome to ThruRNDIS")
                .font(.largeTitle.bold())

            Text("ThruRNDIS keeps the VM stopped until you approve a USB tethering device.\nIt then starts the Linux VM and attaches exactly one USB device for that VM session.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                onboardingPoint("The AccessoryAccess listener runs whenever the app is open.", image: "dot.radiowaves.left.and.right")
                onboardingPoint("VM and USB actions stay available from the menu bar.", image: "menubar.rectangle")
                onboardingPoint("VM assets can be installed directly from the latest published release.", image: "arrow.down.circle")
            }
        }
    }

    private var assetInstallStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Install the VM Assets", systemImage: "shippingbox.and.arrow.backward")
                .font(.largeTitle.bold())

            Text("ThruRNDIS downloads the latest published Linux kernel and initramfs, verifies vm_assets.zip against SHA256SUMS, and installs it in Application Support.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(assetController.installState.statusText, systemImage: assetStatusImage)
                        .foregroundStyle(assetStatusColor)

                    if let progress = assetController.installState.progress {
                        ProgressView(value: progress)
                    }

                    HStack {
                        if assetController.isBusy {
                            Button("Cancel") {
                                assetController.cancelInstall()
                            }
                        } else {
                            Button("Download & Install Latest") {
                                assetController.installLatest()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canEditVMConfiguration)
                        }

                        Spacer()

                        Link("View Releases", destination: releasesURL)
                    }
                }
                .padding(.vertical, 2)
            }

            Text("No WireGuard keys or configuration are downloaded with the VM assets. ThruRNDIS creates those separately in Application Support.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var assetReadyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Confirm the VM Assets", systemImage: "checkmark.seal")
                .font(.largeTitle.bold())

            Text("The managed installation is recommended. You can also select an extracted vm_assets folder manually as a fallback.")
                .font(.title3)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Folder") {
                        Text(assetController.selectedFolderURL?.path ?? "Not selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(assetController.hasConfiguredAssets ? .primary : .secondary)
                    }

                    if let release = assetController.installedRelease {
                        LabeledContent("Managed release", value: release.displayName)
                    }

                    if assetController.hasConfiguredAssets {
                        Label("Kernel and ThruRNDIS initramfs are ready.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Install or select valid assets to finish.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button("Choose Asset Folder…") {
                            guard let url = FilePicker.chooseDirectory(
                                title: "Choose extracted vm_assets folder",
                                initialURL: assetController.selectedFolderURL
                            ) else {
                                return
                            }
                            if let error = assetController.selectManualFolder(url) {
                                alert = OnboardingAlert(message: error.localizedDescription)
                            }
                        }

                        if !assetController.installedReleases.isEmpty {
                            Button("Use Installed Assets") {
                                if let error = assetController.useMostRecentInstalledAssets() {
                                    alert = OnboardingAlert(message: error.localizedDescription)
                                }
                            }
                        }
                    }
                    .disabled(!store.canEditVMConfiguration || assetController.isBusy)
                }
                .padding(.vertical, 2)
            }

            Link("Open the manual release fallback", destination: releasesURL)
        }
    }

    private var assetStatusImage: String {
        switch assetController.installState {
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "circle"
        default:
            return "arrow.triangle.2.circlepath"
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

    private func onboardingPoint(_ title: String, image: String) -> some View {
        Label(title, systemImage: image)
            .font(.headline)
    }
}

private struct OnboardingAlert: Identifiable {
    let id = UUID()
    let message: String
}
