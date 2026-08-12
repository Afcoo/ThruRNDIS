/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct NetworkExtensionPermissionView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var wireGuardSession: WireGuardSessionStore

    var body: some View {
        Group {
            LabeledContent("Status") {
                SettingsStatusLabel(
                    title: wireGuardSession.systemExtensionStatus.title,
                    appearance: systemExtensionStatusAppearance
                )
            }

            Text(systemExtensionStatusDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Request Activation") {
                    store.requestWireGuardSystemExtensionActivation()
                }
                .disabled(!store.canRequestWireGuardSystemExtensionActivation)

                Button("Open Settings") {
                    store.openWireGuardSystemExtensionSettings()
                }
                .buttonStyle(.link)

                Spacer()

                Button("Refresh") {
                    store.refreshWireGuardSystemExtensionStatus()
                }
                .disabled(wireGuardSession.isSystemExtensionActivationInProgress)
            }
        }
    }

    private var systemExtensionStatusDetail: LocalizedStringKey {
        if !store.runtimeEntitlements.systemExtensionInstall {
            return "This build cannot activate the Network Extension. Run a signed copy of ThruRNDIS from Applications."
        }

        return switch wireGuardSession.systemExtensionStatus {
        case .unknown(nil):
            "The Network Extension status has not been checked yet."
        case .unknown:
            "The Network Extension status could not be determined."
        case .inactive(.activationAvailable):
            "Request activation, then allow ThruRNDIS in System Settings before connecting."
        case .inactive(.awaitingUserApproval):
            "Activation was requested. Approve the Network Extension in System Settings."
        case .inactive(.restartRequired(.activation)):
            "Restart macOS to finish activating the Network Extension."
        case .inactive(.restartRequired(.removal)):
            "Restart macOS to finish removing the Network Extension before requesting activation again."
        case .active:
            "The Network Extension is active and ready to connect."
        }
    }

    private var systemExtensionStatusAppearance: SettingsStatusAppearance {
        switch wireGuardSession.systemExtensionStatus {
        case .active:
            .active
        case .inactive(.activationAvailable):
            .inactive
        case .inactive(.awaitingUserApproval), .inactive(.restartRequired):
            .attention
        case .unknown(.some):
            .failed
        case .unknown(nil):
            .unknown
        }
    }
}
