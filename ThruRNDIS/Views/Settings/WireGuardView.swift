/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct WireGuardView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        Form {
            if !store.runtimeEntitlements.packetTunnelProvider
                || !store.runtimeEntitlements.systemExtensionInstall {
                Section {
                    Label(
                        "WireGuard connections are unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Network Extension") {
                LabeledContent("Status") {
                    Label(
                        store.wireGuardSystemExtensionStatus.title,
                        systemImage: systemExtensionStatusImage
                    )
                    .foregroundStyle(systemExtensionStatusColor)
                }

                Text(systemExtensionStatusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Request Activation") {
                        store.requestWireGuardSystemExtensionActivation()
                    }
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

            Section("Connection") {
                LabeledContent("Endpoint") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Endpoint",
                            text: $store.wireGuardEndpointText,
                            prompt: Text(verbatim: store.wireGuardEndpointPrompt)
                        )
                        .labelsHidden()
                        .monospaced()
                        .frame(minWidth: 320)

                        if store.hasWireGuardEndpointValidationError {
                            connectionValidationError
                        }
                    }
                }

                LabeledContent("Allowed IPs") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Allowed IPs",
                            text: $store.wireGuardAllowedIPsText,
                            prompt: Text(verbatim: "0.0.0.0/0")
                        )
                        .labelsHidden()
                        .monospaced()
                        .frame(minWidth: 320)

                        if store.hasWireGuardAllowedIPsValidationError {
                            connectionValidationError
                        }
                    }
                }

                LabeledContent("DNS Servers") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "DNS Servers",
                            text: $store.wireGuardDNSServersText,
                            prompt: Text(verbatim: store.defaultWireGuardDNSServersText)
                        )
                        .labelsHidden()
                        .monospaced()
                        .frame(minWidth: 320)

                        if store.hasWireGuardDNSServersValidationError {
                            connectionValidationError
                        }
                    }
                }

                HStack {
                    Button {
                        store.connectHostWireGuardTunnel()
                    } label: {
                        Text(
                            store.hostWireGuardTunnelStatus.isConnectingOrConnected
                                ? String(localized: "Reconnect")
                                : String(localized: "Connect")
                        )
                    }
                    .disabled(!store.canConnectHostWireGuardTunnel)

                    Button("Disconnect") {
                        store.disconnectHostWireGuardTunnel()
                    }
                    .disabled(!store.canDisconnectHostWireGuardTunnel)

                    Button("Refresh") {
                        store.refreshHostWireGuardTunnelStatus()
                    }
                    .disabled(store.hostWireGuardTunnelStatus.isTransitioning)

                    Spacer()
                }
            }

            Section("Host Configuration (Debug / Export)") {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: store.wireGuardClientConfiguration)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 260)
                .background(.quaternary.opacity(0.2))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.quaternary)
                }

                HStack {
                    Button("Copy") {
                        store.copyWireGuardConfiguration()
                    }
                    .disabled(!store.canExportWireGuardConfiguration)

                    Button("Save…") {
                        store.saveWireGuardConfiguration()
                    }
                    .disabled(!store.canExportWireGuardConfiguration)

                    Button("Reload") {
                        store.reloadWireGuardConfiguration()
                    }

                    Button("Open Config Folder") {
                        store.openWireGuardConfigurationFolder()
                    }

                    Spacer()

                    Button("Clear Discovered Endpoint") {
                        store.clearWireGuardEndpoint()
                    }
                    .disabled(!store.hasDiscoveredWireGuardEndpoint)
                }
            }
        }
        .onAppear {
            store.refreshWireGuardSystemExtensionStatus()
        }
    }

    private var connectionValidationError: some View {
        Text("Check that the value is entered correctly")
            .font(.caption)
            .foregroundStyle(.red)
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
}
