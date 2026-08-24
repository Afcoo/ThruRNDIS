/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct NetworkRouteView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @EnvironmentObject private var networkRoute: NetworkRouteStore
    @EnvironmentObject private var helper: NetworkRouteHelperStore
    @EnvironmentObject private var portForwarding: PortForwardingStore

    var body: some View {
        Form {
            if !helper.isSignedBuild {
                Section {
                    Label(
                        "The VM network helper is unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Privileged Helper") {
                NetworkRouteHelperPermissionView()
            }

            Section("Networking") {
                LabeledContent("Status") {
                    SettingsStatusLabel(
                        title: routeStatus.title,
                        appearance: routeStatus.appearance
                    )
                }
                HStack {
                    Button("Start") {
                        networkRoute.startManually()
                    }
                    .disabled(!networkRoute.canStart)

                    Button("Stop") {
                        networkRoute.stopManually()
                    }
                    .disabled(!networkRoute.canStop)

                    Spacer()
                }
                if appPreferences.isDebugModeEnabled {
                    LabeledContent(
                        "Guest VZNAT Address",
                        value: networkRoute.guestIPv4Address
                            ?? String(localized: "Waiting")
                    )
                    LabeledContent(
                        "VZNAT Gateway",
                        value: networkRoute.vznatGatewayIPv4Address
                            ?? String(localized: "Waiting")
                    )
                    LabeledContent(
                        "RNDIS Forwarding",
                        value: networkRoute.isRNDISRouteReady
                            ? String(localized: "Ready")
                            : String(localized: "Waiting")
                    )
                    if let snapshot = networkRoute.snapshot,
                       snapshot.state != .inactive {
                        LabeledContent(
                            "VM Bridge",
                            value: snapshot.bridgeInterfaceName
                                ?? String(localized: "Unknown")
                        )
                        LabeledContent(
                            "Ethernet Bond",
                            value: snapshot.bondInterfaceName
                                ?? String(localized: "Unknown")
                        )
                        LabeledContent(
                            "Routes",
                            value: snapshot.installedPrefixes.isEmpty
                                ? String(localized: "None")
                                : snapshot.installedPrefixes.joined(separator: ", ")
                        )
                    }
                    if let lastErrorMessage = networkRoute.lastErrorMessage {
                        Text(lastErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

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

                        Group {
                            if let validationErrorMessage =
                                portForwarding.validationErrorMessage {
                                Text(validationErrorMessage)
                                    .foregroundStyle(.red)
                            } else {
                                Text(
                                    "Separate entries with commas and ranges with hyphens."
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
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

    private var portForwardingStatus: (
        title: String,
        appearance: SettingsStatusAppearance
    ) {
        if portForwarding.validationErrorMessage != nil {
            return (String(localized: "Invalid Input"), .failed)
        }
        switch portForwarding.runtimeState {
        case .disabled:
            return (String(localized: "Off"), .stopped)
        case .saved:
            return (String(localized: "Saved"), .unknown)
        case .pending:
            return (String(localized: "Pending"), .attention)
        case .active:
            return (String(localized: "Active"), .active)
        case .failed:
            return (String(localized: "Needs Attention"), .failed)
        }
    }

    private var routeStatus: (
        title: String,
        appearance: SettingsStatusAppearance
    ) {
        if let operation = networkRoute.operation {
            return (operation.title, .transitioning)
        }
        if networkRoute.lastErrorMessage != nil {
            return (String(localized: "Needs Attention"), .failed)
        }
        switch networkRoute.snapshot?.state {
        case .active:
            return (String(localized: "Active"), .active)
        case .degraded:
            return (String(localized: "Needs Attention"), .attention)
        case .inactive:
            return (String(localized: "Stopped"), .stopped)
        case nil:
            return (String(localized: "Not Checked"), .unknown)
        }
    }
}
