/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct WireGuardView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var wireGuardSession: WireGuardSessionStore
    @EnvironmentObject private var appPreferences: AppPreferencesStore

    let openConfigurationFolder: () -> Void
    let copyConfiguration: () -> Void
    let saveConfiguration: () -> Void

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
                        wireGuardSession.systemExtensionStatus.title,
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
                    .disabled(wireGuardSession.systemExtensionStatus.isTransitioning)
                }
            }

            Section("Connection") {
                LabeledContent("Endpoint") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Endpoint",
                            text: $wireGuardSession.endpointText,
                            prompt: Text(verbatim: wireGuardSession.endpointPrompt)
                        )
                        .labelsHidden()
                        .monospaced()
                        .frame(minWidth: 320)

                        if wireGuardSession.hasEndpointValidationError {
                            connectionValidationError
                        }
                    }
                }

                LabeledContent("Allowed IPs") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Allowed IPs",
                            text: $wireGuardSession.allowedIPsText,
                            prompt: Text(verbatim: "0.0.0.0/0")
                        )
                        .labelsHidden()
                        .monospaced()
                        .frame(minWidth: 320)

                        if wireGuardSession.hasAllowedIPsValidationError {
                            connectionValidationError
                        }
                    }
                }

                LabeledContent("DNS Servers") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "DNS Servers",
                            text: $wireGuardSession.dnsServersText,
                            prompt: Text(verbatim: wireGuardSession.defaultDNSServersText)
                        )
                        .labelsHidden()
                        .monospaced()
                        .frame(minWidth: 320)

                        if wireGuardSession.hasDNSServersValidationError {
                            connectionValidationError
                        }
                    }
                }

                HStack {
                    Button {
                        store.connectHostWireGuardTunnel()
                    } label: {
                        Text(
                            wireGuardSession.hostTunnelStatus.isConnectingOrConnected
                                ? String(localized: "Reconnect")
                                : String(localized: "Connect")
                        )
                    }
                    .disabled(!store.canConnectHostWireGuardTunnel)

                    Button("Disconnect") {
                        store.disconnectHostWireGuardTunnel()
                    }
                    .disabled(!wireGuardSession.canDisconnectTunnel)

                    Button("Refresh") {
                        store.refreshHostWireGuardTunnelStatus()
                    }
                    .disabled(wireGuardSession.hostTunnelStatus.isTransitioning)

                    Spacer()

                    Toggle(
                        "Connect Automatically When a USB Device Is Attached",
                        isOn: $appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches
                    )
                    .toggleStyle(.checkbox)
                }
            }

            Section("Host Configuration (Debug / Export)") {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: wireGuardSession.clientConfiguration)
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
                        copyConfiguration()
                    }
                    .disabled(!wireGuardSession.canExportConfiguration)

                    Button("Save…") {
                        saveConfiguration()
                    }
                    .disabled(!wireGuardSession.canExportConfiguration)

                    Button("Reload") {
                        wireGuardSession.reloadConfiguration()
                    }

                    Button("Open Config Folder") {
                        openConfigurationFolder()
                    }

                    Spacer()

                    Button("Clear Discovered Endpoint") {
                        wireGuardSession.clearDiscoveredEndpoint(
                            reason: "manual request",
                            alwaysDisconnectTunnel: false
                        )
                    }
                    .disabled(wireGuardSession.discoveredEndpoint == nil)
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
        if wireGuardSession.systemExtensionStatus == .uninstalling {
            return "Restart macOS to finish removing the Network Extension before requesting activation again."
        }
        if !store.runtimeEntitlements.systemExtensionInstall {
            return "This build cannot activate the Network Extension. Run a signed copy of ThruRNDIS from Applications."
        }

        return switch wireGuardSession.systemExtensionStatus {
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
        switch wireGuardSession.systemExtensionStatus {
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
        switch wireGuardSession.systemExtensionStatus {
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
