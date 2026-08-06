/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var dummyEthernet: DummyEthernetStore
    @EnvironmentObject private var assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    @State private var step = 0

    let contentWidth: CGFloat
    let onFinish: () -> Void
    let onStepChange: (Int) -> Void

    init(
        contentWidth: CGFloat,
        onFinish: @escaping () -> Void,
        onStepChange: @escaping (Int) -> Void
    ) {
        self.contentWidth = contentWidth
        self.onFinish = onFinish
        self.onStepChange = onStepChange
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                stepContent
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical, showsIndicators: false) {
                    stepContent
                }
            }
            .frame(maxWidth: .infinity)

            ZStack {
                HStack {
                    if step > 0 {
                        Button {
                            step -= 1
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                    }

                    Spacer()

                    if step < 3 {
                        Button("Continue") {
                            step += 1
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .tint(.accentColor)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                    } else {
                        Button {
                            store.completeOnboarding()
                            if assetWorkflowCoordinator.hasConfiguredAssets {
                                onFinish()
                            }
                        } label: {
                            Label("Finish", systemImage: "checkmark")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .tint(.accentColor)
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            !assetWorkflowCoordinator.hasConfiguredAssets
                                || assetWorkflowCoordinator.isBusy
                        )
                    }
                }

                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(
                                index == step
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.35)
                            )
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .frame(width: contentWidth)
        .containerBackground(.thickMaterial, for: .window)
        .vmAssetErrorAlert()
        .onChange(of: step) { _, newStep in
            onStepChange(newStep)
        }
    }

    private var stepContent: some View {
        Form {
            switch step {
            case 0:
                welcomeStep
            case 1:
                assetInstallStep
            case 2:
                permissionsStep
            default:
                accessoryAttachStep
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var welcomeStep: some View {
        Section {
            onboardingPoint("Install the VM Assets.", image: "arrow.down.circle")
            onboardingPoint(
                "Grant the Network Extension and Dummy Ethernet helper permissions.",
                image: "checkmark.shield"
            )
            onboardingPoint(
                "Connect your tethering device to this Mac.",
                image: "cable.connector"
            )
            onboardingPoint(
                "Use Virtual Machine Accessories to attach the device to ThruRNDIS.",
                image: "menubar.rectangle"
            )
        } header: {
            onboardingStepHeader(
                "Welcome to ThruRNDIS",
                detail: "Follow these four steps to use USB tethering.",
                image: "cable.connector.horizontal"
            )
        }
    }

    private var assetInstallStep: some View {
        Section {
            VMAssetConfigurationView()
        } header: {
            onboardingStepHeader(
                "Install the Required Files",
                detail: "Download and install the VM Assets.",
                image: "shippingbox.and.arrow.backward"
            )
        } footer: {
            VMAssetDocumentationLinkView()
        }
    }

    private var accessoryAttachStep: some View {
        Section {
            onboardingInstruction(
                "Connect your device",
                detail: "Turn on USB tethering, then connect the device to this Mac with USB.",
                image: "cable.connector"
            )
            onboardingInstruction(
                "Open Virtual Machine Accessories",
                detail: "Click the USB icon in the menu bar and choose the tethering device.",
                image: "menubar.rectangle"
            )
            onboardingInstruction(
                "Use it with ThruRNDIS",
                detail: "Select \u{201c}Use with ThruRNDIS\u{201d}",
                image: "checkmark.circle"
            )
        } header: {
            VStack(alignment: .leading, spacing: 20) {
                onboardingStepHeader(
                    "Connect Your Tethering Device",
                    detail: "Use the menu bar to pass your tethering device through to ThruRNDIS.",
                    image: "cable.connector.horizontal"
                )

                connectionVideo
            }
        }
    }

    private var permissionsStep: some View {
        Group {
            Section {
                NetworkExtensionPermissionView()
            } header: {
                VStack(alignment: .leading, spacing: 24) {
                    onboardingStepHeader(
                        "Enable the permissions",
                        detail: "ThruRNDIS requires Network Extension and Dummy Ethernet helper permissions.",
                        image: "checkmark.shield"
                    )

                    Text("Network Extension")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            } footer: {
                Text("Network Extension permission is required for WireGuard connections.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                DummyEthernetHelperPermissionView()
            } header: {
                Text("Dummy Ethernet helper")
            } footer: {
                Text("The Dummy Ethernet helper is required to configure the Dummy Ethernet network service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            store.refreshWireGuardSystemExtensionStatus()
            dummyEthernet.refresh()
        }
    }

    private var connectionVideo: some View {
        ReplayableVideoView(
            url: Bundle.main.url(
                forResource: "AccessoryAccessOnboarding",
                withExtension: "mp4"
            ),
            replayAppearanceDelay: .seconds(2),
            loadingText: "Preparing device connection video…",
            unavailableText: "Device connection video unavailable",
            replayAccessibilityLabel: "Replay device connection video"
        )
        .frame(width: 400, height: 400 * 410 / 620)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("How to connect a tethering device to ThruRNDIS")
    }

    private func onboardingStepHeader(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        image: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: image)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)

            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
    }

    private var canContinue: Bool {
        guard step == 1 else {
            return true
        }
        return assetWorkflowCoordinator.hasConfiguredAssets && !assetWorkflowCoordinator.isBusy
    }

    private func onboardingInstruction(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        image: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: image)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func onboardingPoint(_ title: LocalizedStringKey, image: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 24, height: 20)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
