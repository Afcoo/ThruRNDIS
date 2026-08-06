/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct DummyEthernetView: View {
    @EnvironmentObject private var dummyEthernet: DummyEthernetStore
    @EnvironmentObject private var helper: DummyEthernetHelperStore

    var body: some View {
        Form {
            if !helper.isSignedBuild {
                Section {
                    Label(
                        "Dummy Ethernet is unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section {
                DummyEthernetHelperPermissionView()
            } header: {
                Text("Dummy Ethernet helper")
            } footer: {
                Text("The Dummy Ethernet helper is required to configure the Dummy Ethernet network service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Dummy Ethernet Status") {
                LabeledContent("Status") {
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

    private var networkStatusPresentation: (
        title: String,
        appearance: SettingsStatusAppearance
    ) {
        if let operation = dummyEthernet.operation {
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
