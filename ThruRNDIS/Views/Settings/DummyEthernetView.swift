/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct DummyEthernetView: View {
    @EnvironmentObject private var dummyEthernet: DummyEthernetStore

    var body: some View {
        Form {
            if !dummyEthernet.isSignedBuild {
                Section {
                    Label(
                        "Dummy Ethernet is unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Privileged Helper") {
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
                    if dummyEthernet.isReinstallActionPresented {
                        Button("Reinstall") {
                            dummyEthernet.reinstallHelper()
                        }
                        .disabled(!dummyEthernet.canReinstallHelper)
                    } else {
                        Button("Install") {
                            dummyEthernet.enableHelper()
                        }
                        .disabled(!dummyEthernet.canEnableHelper)
                    }

                    Button("Remove") {
                        dummyEthernet.disableHelper()
                    }
                    .disabled(!dummyEthernet.canDisableHelper)

                    Button("Open Settings") {
                        dummyEthernet.openLoginItemsSettings()
                    }
                    .buttonStyle(.link)

                    Spacer()

                    Button("Refresh") {
                        dummyEthernet.refresh()
                    }
                    .disabled(dummyEthernet.isOperationInProgress)
                }
            }

            Section("Dummy Ethernet Status") {
                LabeledContent("Network") {
                    SettingsStatusLabel(
                        title: networkStatusPresentation.title,
                        appearance: networkStatusPresentation.appearance
                    )
                }

                HStack {
                    if dummyEthernet.isRestartActionPresented {
                        Button("Restart") {
                            dummyEthernet.restart()
                        }
                        .disabled(!dummyEthernet.canRestart)
                    } else {
                        Button("Start") {
                            dummyEthernet.start()
                        }
                        .disabled(!dummyEthernet.canStart)
                    }

                    Button("Stop") {
                        dummyEthernet.stop()
                    }
                    .disabled(!dummyEthernet.canStop)
                }
            }

            Section("Network Configuration") {
                LabeledContent("IPv4 Address") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "IPv4 Address",
                            text: $dummyEthernet.configurationInput
                                .hostIPv4Address,
                            prompt: Text(
                                verbatim: ThruRNDISDummyEthernet
                                    .defaultHostIPv4Address
                            )
                        )
                        .labelsHidden()
                        .monospaced()
                        .frame(minWidth: 220)
                        .disabled(!dummyEthernet.canEditConfiguration)
                    }
                }

                LabeledContent("Bond Member") {
                    TextField(
                        "Bond Member",
                        text: $dummyEthernet.configurationInput
                            .memberInterfaceName,
                        prompt: Text(
                            verbatim: ThruRNDISDummyEthernet
                                .defaultMemberInterfaceName
                        )
                    )
                    .labelsHidden()
                    .monospaced()
                    .frame(minWidth: 220)
                    .disabled(!dummyEthernet.canEditConfiguration)
                }

                LabeledContent("Router Peer") {
                    TextField(
                        "Router Peer",
                        text: $dummyEthernet.configurationInput
                            .peerInterfaceName,
                        prompt: Text(
                            verbatim: ThruRNDISDummyEthernet
                                .defaultPeerInterfaceName
                        )
                    )
                    .labelsHidden()
                    .monospaced()
                    .frame(minWidth: 220)
                    .disabled(!dummyEthernet.canEditConfiguration)
                }

                if let error = dummyEthernet.configurationErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            dummyEthernet.refresh()
        }
    }

    private var helperStatusPresentation: (
        title: String,
        detail: LocalizedStringKey,
        appearance: SettingsStatusAppearance
    ) {
        if let operation = dummyEthernet.helperStatusOperation {
            return (
                operation.title,
                "The privileged helper registration is being updated.",
                .transitioning
            )
        }

        return switch dummyEthernet.helperRegistrationStatus {
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

    private var networkStatusPresentation: (
        title: String,
        appearance: SettingsStatusAppearance
    ) {
        if let operation = dummyEthernet.networkStatusOperation {
            return (operation.title, .transitioning)
        }
        guard let runtimeState = dummyEthernet.runtimeState else {
            return (String(localized: "Not Checked"), .unknown)
        }
        switch runtimeState {
        case .inactive:
            return (String(localized: "Stopped"), .stopped)
        case .active:
            return (String(localized: "Active"), .active)
        case .degraded:
            return (String(localized: "Needs Attention"), .attention)
        }
    }
}
