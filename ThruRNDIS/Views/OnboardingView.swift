/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    @State private var step = 0
    @State private var alert: OnboardingAlert?

    let onFinish: () -> Void
    let onStepChange: (Int) -> Void

    private let releasesURL = URL(
        string: "https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases"
    )!
    private let vmAssetsDocumentationURL = URL(
        string: "https://github.com/Afcoo/ThruRNDIS_VM_Assets"
    )!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
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
                    case 2:
                        accessoryAttachStep
                    default:
                        networkExtensionStep
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

                if step < 3 {
                    Button("Continue") {
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                } else {
                    Button("Finish") {
                        store.completeOnboarding()
                        if assetWorkflowCoordinator.hasConfiguredAssets {
                            onFinish()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!assetWorkflowCoordinator.hasConfiguredAssets || assetWorkflowCoordinator.isBusy)
                }
            }
            .padding(12)
        }
        .onReceive(assetWorkflowCoordinator.$errorMessage.compactMap { $0 }) { message in
            alert = OnboardingAlert(message: message)
        }
        .onChange(of: step) { _, newStep in
            onStepChange(newStep)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text("VM Asset Error"),
                message: Text(verbatim: alert.message),
                dismissButton: .default(Text("OK")) {
                    assetWorkflowCoordinator.clearError()
                }
            )
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Welcome to ThruRNDIS", systemImage: "cable.connector.horizontal")
                .font(.largeTitle.bold())

            Text("Set up ThruRNDIS once, then use the menu bar whenever you want to connect a USB tethering device.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                onboardingPoint("Install the required files in the next step.", image: "arrow.down.circle")
                onboardingPoint("Turn on USB tethering and connect your device to this Mac.", image: "cable.connector")
                onboardingPoint("Use Virtual Machine Accessories in the menu bar to connect the device to ThruRNDIS.", image: "menubar.rectangle")
                onboardingPoint("Enable the Network Extension before connecting.", image: "checkmark.shield")
            }
        }
    }

    private var assetInstallStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Install the Required Files", systemImage: "shippingbox.and.arrow.backward")
                .font(.largeTitle.bold())

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Download and install the VM Assets ThruRNDIS needs.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Link(destination: vmAssetsDocumentationURL) {
                    Label("What are VM Assets", systemImage: "questionmark.circle")
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(assetWorkflowCoordinator.installState.statusText, systemImage: assetStatusImage)
                        .foregroundStyle(assetStatusColor)

                    if let progress = assetWorkflowCoordinator.installState.progress {
                        ProgressView(value: progress)
                    }

                    if assetWorkflowCoordinator.hasConfiguredAssets {
                        Label("ThruRNDIS is ready to continue.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        if let release = assetWorkflowCoordinator.installedRelease {
                            LabeledContent("Installed version", value: release.displayName)
                        } else {
                            Label("Using manually selected files", systemImage: "folder")
                                .foregroundStyle(.secondary)
                        }
                    } else if !assetWorkflowCoordinator.isBusy {
                        Label("Install or choose valid files to continue.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 8) {
                        if assetWorkflowCoordinator.isBusy {
                            Button("Cancel") {
                                assetWorkflowCoordinator.cancelInstall()
                            }
                        } else {
                            Button(
                                assetWorkflowCoordinator.hasConfiguredAssets
                                    ? String(localized: "Check & Install Latest")
                                    : String(localized: "Download & Install Latest")
                            ) {
                                assetWorkflowCoordinator.installLatest()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canEditVMConfiguration)
                        }

                        Link("View VM Asset Release", destination: releasesURL)
                    }

                    Divider()

                    HStack {
                        Button("Choose Downloaded Assets…") {
                            guard let url = FilePicker.chooseDirectory(
                                title: String(localized: "Choose downloaded VM assets"),
                                initialURL: assetWorkflowCoordinator.selectedFolderURL
                            ) else {
                                return
                            }
                            if let error = assetWorkflowCoordinator.selectManualFolder(url) {
                                alert = OnboardingAlert(message: error.localizedDescription)
                            }
                        }

                        if !assetWorkflowCoordinator.installedReleases.isEmpty {
                            Button("Use Installed Assets") {
                                if let error = assetWorkflowCoordinator.useMostRecentInstalledAssets() {
                                    alert = OnboardingAlert(message: error.localizedDescription)
                                }
                            }
                        }
                    }
                    .disabled(!store.canEditVMConfiguration || assetWorkflowCoordinator.isBusy)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var accessoryAttachStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect Your Tethering Device", systemImage: "cable.connector.horizontal")
                .font(.largeTitle.bold())

            Text("Use the macOS menu bar to make your USB tethering device available to ThruRNDIS.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            connectionVideo

            VStack(alignment: .leading, spacing: 12) {
                onboardingInstruction(
                    "Connect your device",
                    detail: "Turn on USB tethering, then connect the device to this Mac with USB.",
                    image: "cable.connector"
                )
                onboardingInstruction(
                    "Open Virtual Machine Accessories",
                    detail: "Click the USB device icon in the menu bar and choose the tethering device you want to use.",
                    image: "menubar.rectangle"
                )
                onboardingInstruction(
                    "Use it with ThruRNDIS",
                    detail: "Select \u{201c}Use with ThruRNDIS,\u{201d} then choose \u{201c}Attach\u{201d} when ThruRNDIS asks.",
                    image: "checkmark.circle"
                )
            }
        }
    }

    private var networkExtensionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Enable the Network Extension", systemImage: "checkmark.shield")
                .font(.largeTitle.bold())

            Text("ThruRNDIS requires its Network Extension to be active before it can connect.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Status") {
                        Label(
                            store.wireGuardSystemExtensionStatus.title,
                            systemImage: systemExtensionStatusImage
                        )
                        .foregroundStyle(systemExtensionStatusColor)
                    }

                    Text(systemExtensionStatusDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Request Activation") {
                            store.requestWireGuardSystemExtensionActivation()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canRequestWireGuardSystemExtensionActivation)

                        Button("Open Settings") {
                            store.openWireGuardSystemExtensionSettings()
                        }
                        .buttonStyle(.link)

                        Spacer()

                        Button("Refresh Status") {
                            store.refreshWireGuardSystemExtensionStatus()
                        }
                        .disabled(store.wireGuardSystemExtensionStatus.isTransitioning)
                    }
                }
                .padding(.vertical, 2)
            }

            Text("In System Settings, turn on the ThruRNDIS network extension, then return to ThruRNDIS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            store.refreshWireGuardSystemExtensionStatus()
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

    private var assetStatusImage: String {
        switch assetWorkflowCoordinator.installState {
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
        switch assetWorkflowCoordinator.installState {
        case .ready:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var systemExtensionStatusDetail: LocalizedStringKey {
        if store.wireGuardSystemExtensionStatus == .uninstalling {
            return "Restart macOS to finish removing the Network Extension before requesting activation again."
        }
        if !store.runtimeEntitlements.systemExtensionInstall {
            return "This build cannot activate the Network Extension. Run a signed copy of ThruRNDIS from Applications."
        }

        return switch store.wireGuardSystemExtensionStatus {
        case .unknown:
            "The Network Extension status has not been checked yet."
        case .checking:
            "Checking whether the Network Extension is active."
        case .inactive:
            "Request activation, then allow ThruRNDIS in System Settings before connecting."
        case .activationRequested, .awaitingUserApproval:
            "Activation was requested. Approve the Network Extension in System Settings."
        case .active:
            "The Network Extension is active and ready to connect."
        case .uninstalling:
            "Restart macOS to finish removing the Network Extension before requesting activation again."
        case .restartRequired:
            "Restart macOS to finish activating the Network Extension."
        case .failed:
            "The Network Extension status could not be determined."
        }
    }

    private var systemExtensionStatusImage: String {
        switch store.wireGuardSystemExtensionStatus {
        case .active:
            "checkmark.shield.fill"
        case .checking, .activationRequested:
            "arrow.triangle.2.circlepath"
        case .awaitingUserApproval:
            "person.badge.clock"
        case .restartRequired:
            "restart.circle"
        case .inactive:
            "xmark.shield"
        case .uninstalling:
            "trash"
        case .failed:
            "exclamationmark.triangle.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    private var systemExtensionStatusColor: Color {
        switch store.wireGuardSystemExtensionStatus {
        case .active:
            .green
        case .checking, .activationRequested, .awaitingUserApproval, .restartRequired:
            .orange
        case .inactive, .uninstalling, .failed:
            .red
        case .unknown:
            .secondary
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

private struct OnboardingAlert: Identifiable {
    let id = UUID()
    let message: String
}
