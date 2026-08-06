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

            Section {
                NetworkExtensionPermissionView()
            } header: {
                Text("Network Extension")
            } footer: {
                Text("Network Extension permission is required for WireGuard connections.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        "Connect automatically when device is attached",
                        isOn: $appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches
                    )
                    .toggleStyle(.checkbox)
                }
            }

            Section("Host Configuration (Debug / Export)") {
                GroupBox {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: wireGuardSession.clientConfiguration)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                .frame(height: 260)

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

                    Button("Reset") {
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

}
