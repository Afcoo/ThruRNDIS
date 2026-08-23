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
                        "The network route helper is unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Privileged Helper") {
                NetworkRouteHelperPermissionView()
            }

            Section("IPv4 Route") {
                LabeledContent("Status") {
                    SettingsStatusLabel(
                        title: routeStatus.title,
                        appearance: routeStatus.appearance
                    )
                }
                LabeledContent(
                    "Guest",
                    value: networkRoute.guestIPv4Address
                        ?? String(localized: "Waiting")
                )
                LabeledContent(
                    "RNDIS",
                    value: networkRoute.isRNDISRouteReady
                        ? String(localized: "Ready")
                        : String(localized: "Waiting")
                )
                if let snapshot = networkRoute.snapshot,
                   snapshot.state != .inactive {
                    LabeledContent(
                        "Host Interface",
                        value: snapshot.interfaceName ?? String(localized: "Unknown")
                    )
                    LabeledContent(
                        "Host Address",
                        value: snapshot.hostIPv4Address ?? String(localized: "Unknown")
                    )
                    LabeledContent(
                        "Routes",
                        value: snapshot.installedPrefixes.joined(separator: ", ")
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
