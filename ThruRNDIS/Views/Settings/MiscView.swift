/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct MiscView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var networkRoute: NetworkRouteStore
    @EnvironmentObject private var portForwarding: PortForwardingStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Enable Port Forwarding",
                    isOn: Binding(
                        get: { portForwarding.isEnabled },
                        set: portForwarding.setEnabled
                    )
                )
                .disabled(!store.canEditVMConfiguration)

                if portForwarding.isEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Ports") {
                            TextField(
                                "Ports",
                                text: Binding(
                                    get: { portForwarding.portSpecification },
                                    set: portForwarding.setPortSpecification
                                )
                            )
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 180)
                        }

                        Text(
                            "Separate entries with commas and ranges with hyphens."
                        )
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(!store.canEditVMConfiguration)
                }

                LabeledContent("Status") {
                    SettingsStatusLabel(
                        title: portForwardingStatus.title,
                        appearance: portForwardingStatus.appearance
                    )
                }
                if case .failed(let message) = portForwarding.runtimeState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("TCP/UDP Port Forwarding")
            }
        }
        .onAppear { networkRoute.refresh() }
    }

    private var activeRNDISIPv4Address: String? {
        guard portForwarding.isEnabled,
              portForwarding.runtimeState == .active,
              networkRoute.lastErrorMessage == nil,
              networkRoute.operation != .stopping,
              networkRoute.snapshot?.state == .active else {
            return nil
        }
        return networkRoute.rndisIPv4Address
    }

    private var portForwardingStatus: (
        title: String,
        appearance: SettingsStatusAppearance
    ) {
        if let validationErrorMessage = portForwarding.validationErrorMessage {
            return (validationErrorMessage, .failed)
        }
        switch portForwarding.runtimeState {
        case .disabled:
            return (String(localized: "Off"), .stopped)
        case .saved:
            return (String(localized: "Saved"), .unknown)
        case .pending:
            return (String(localized: "Pending"), .attention)
        case .active:
            if let activeRNDISIPv4Address {
                return (
                    String(
                        localized: "Listening on \(activeRNDISIPv4Address)"
                    ),
                    .active
                )
            }
            return (String(localized: "Active"), .active)
        case .failed:
            return (String(localized: "Needs Attention"), .failed)
        }
    }
}
