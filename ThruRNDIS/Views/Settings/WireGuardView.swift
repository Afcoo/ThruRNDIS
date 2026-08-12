/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct WireGuardView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var wireGuardSession: WireGuardSessionStore
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @EnvironmentObject private var dummyEthernet: DummyEthernetStore

    let openConfigurationFolder: () -> Void
    let copyConfiguration: () -> Void
    let saveConfiguration: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Manual Configuration Mode",
                    isOn: Binding(
                        get: {
                            appPreferences
                                .isWireGuardManualConfigurationModeEnabled
                        },
                        set: store
                            .setWireGuardManualConfigurationModeEnabled
                    )
                )
                .disabled(!store.canChangeWireGuardManualConfigurationMode)
            }

            if !appPreferences.isWireGuardManualConfigurationModeEnabled
                && (!store.runtimeEntitlements.packetTunnelProvider
                    || !store.runtimeEntitlements.systemExtensionInstall) {
                Section {
                    Label(
                        "WireGuard connections are unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if !appPreferences.isWireGuardManualConfigurationModeEnabled {
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

                if !appPreferences.isWireGuardManualConfigurationModeEnabled {
                    HStack {
                        Button {
                            store.connectWireGuardTunnel()
                        } label: {
                            Text(
                                wireGuardSession.tunnelStatus.isConnectingOrConnected
                                    ? String(localized: "Reconnect")
                                    : String(localized: "Connect")
                            )
                        }
                        .disabled(!store.canConnectWireGuardTunnel)

                        Button("Disconnect") {
                            store.disconnectWireGuardTunnel()
                        }
                        .disabled(!store.canDisconnectWireGuardTunnel)

                        Button("Refresh") {
                            store.refreshWireGuardTunnelStatus()
                        }
                        .disabled(!store.canRefreshWireGuardTunnelStatus)

                        Spacer()

                        Toggle(
                            "Connect automatically when device is attached",
                            isOn: $appPreferences.shouldAutomaticallyConnectWireGuardWhenUSBDeviceAttaches
                        )
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Section("Host Configuration (Debug / Export)") {
                GroupBox {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: wireGuardSession.renderedClientConfiguration)
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
