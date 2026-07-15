/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct WireGuardView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        Form {
            Section("Status") {
                Text(store.wireGuardStatusMessage)
                    .foregroundStyle(.secondary)
            }

            Section("Host Configuration") {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: store.wireGuardHostConfiguration)
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

                    Button("Clear Endpoint") {
                        store.clearWireGuardEndpoint()
                    }
                    .disabled(!store.canExportWireGuardConfiguration)
                }
            }
        }
    }
}
