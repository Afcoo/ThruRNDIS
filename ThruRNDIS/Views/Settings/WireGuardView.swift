/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct WireGuardView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        Form {
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
    }

    private var connectionValidationError: some View {
        Text("Check that the value is entered correctly")
            .font(.caption)
            .foregroundStyle(.red)
    }
}
