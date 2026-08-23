/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct NetworkRouteView: View {
    @EnvironmentObject private var networkRoute: NetworkRouteStore
    @EnvironmentObject private var helper: NetworkRouteHelperStore

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

            Section("VM Network") {
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
        .onAppear { networkRoute.refresh() }
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
