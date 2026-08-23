/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct NetworkRouteHelperPermissionView: View {
    @EnvironmentObject private var networkRoute: NetworkRouteStore
    @EnvironmentObject private var helper: NetworkRouteHelperStore

    var body: some View {
        Group {
            LabeledContent("Status") {
                SettingsStatusLabel(
                    title: presentation.title,
                    appearance: presentation.appearance
                )
            }

            Text(presentation.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if helper.registrationStatus == .enabled
                    || helper.registrationStatus == .updateRequired {
                    Button("Reinstall") { helper.reinstall() }
                        .disabled(
                            !helper.canReinstall
                                || networkRoute.operation != nil
                                || networkRoute.snapshot?.state != .inactive
                        )
                } else {
                    Button("Install") { helper.enable() }
                        .disabled(!helper.canEnable)
                }

                Button("Remove") { helper.disable() }
                    .disabled(
                        !helper.canDisable
                            || networkRoute.operation != nil
                            || networkRoute.snapshot?.state != .inactive
                    )

                Button("Open Settings") { helper.openSystemSettings() }
                    .buttonStyle(.link)

                Spacer()

                Button("Refresh") { networkRoute.refresh() }
                    .disabled(networkRoute.isOperationInProgress)
            }
        }
    }

    private var presentation: (
        title: String,
        detail: LocalizedStringKey,
        appearance: SettingsStatusAppearance
    ) {
        if let operation = helper.operation {
            return (
                operation.title,
                "The network route helper registration is being updated.",
                .transitioning
            )
        }
        return switch helper.registrationStatus {
        case .unknown:
            (String(localized: "Unknown"), "Refresh the helper status.", .unknown)
        case .notRegistered:
            (String(localized: "Not Enabled"), "Install the bundled network route helper.", .inactive)
        case .enabled:
            (String(localized: "Enabled"), "The network route helper is ready.", .active)
        case .updateRequired:
            (String(localized: "Update Required"), "Reinstall the bundled network route helper.", .attention)
        case .requiresApproval:
            (String(localized: "Approval Required"), "Allow the helper in System Settings > General > Login Items, then refresh.", .attention)
        case .notFound:
            (String(localized: "Not Found"), "Use a signed installed ThruRNDIS app.", .failed)
        }
    }
}
