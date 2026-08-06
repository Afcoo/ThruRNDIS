/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct DummyEthernetHelperPermissionView: View {
    @EnvironmentObject private var dummyEthernet: DummyEthernetStore
    @EnvironmentObject private var helper: DummyEthernetHelperStore

    var body: some View {
        Group {
            LabeledContent("Status") {
                SettingsStatusLabel(
                    title: helperStatusPresentation.title,
                    appearance: helperStatusPresentation.appearance
                )
            }

            Text(helperStatusPresentation.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if helper.isReinstallActionPresented {
                    Button("Reinstall") {
                        dummyEthernet.reinstallHelper()
                    }
                    .disabled(!dummyEthernet.canReinstallHelper)
                } else {
                    Button("Install") {
                        helper.enable()
                    }
                    .disabled(!dummyEthernet.canEnableHelper)
                }

                Button("Remove") {
                    dummyEthernet.disableHelper()
                }
                .disabled(!dummyEthernet.canDisableHelper)

                Button("Open Settings") {
                    helper.openSystemSettings()
                }
                .buttonStyle(.link)

                Spacer()

                Button("Refresh") {
                    helper.refresh()
                }
                .disabled(helper.isOperationInProgress)
            }
        }
    }

    private var helperStatusPresentation: (
        title: String,
        detail: LocalizedStringKey,
        appearance: SettingsStatusAppearance
    ) {
        if let operation = helper.operation {
            return (
                operation.title,
                "The privileged helper registration is being updated.",
                .transitioning
            )
        }

        return switch helper.registrationStatus {
        case .unknown:
            (
                String(localized: "Unknown"),
                "Refresh the helper status before managing Dummy Ethernet.",
                .unknown
            )
        case .notRegistered:
            (
                String(localized: "Not Enabled"),
                "Install the bundled helper.",
                .inactive
            )
        case .enabled:
            (
                String(localized: "Enabled"),
                "The privileged helper is ready.",
                .active
            )
        case .updateRequired:
            (
                String(localized: "Update Required"),
                "Reinstall the bundled helper.",
                .attention
            )
        case .requiresApproval:
            (
                String(localized: "Approval Required"),
                "Allow the helper in System Settings > General > Login Items, then return and refresh.",
                .attention
            )
        case .notFound:
            (
                String(localized: "Not Found"),
                "The bundled LaunchDaemon could not be found. Use a signed installed ThruRNDIS app.",
                .failed
            )
        }
    }
}
