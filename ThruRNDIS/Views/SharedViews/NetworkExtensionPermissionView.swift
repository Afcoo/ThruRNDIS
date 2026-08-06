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

                Button("Refresh Status") {
                    store.refreshWireGuardSystemExtensionStatus()
                }
                .disabled(wireGuardSession.systemExtensionStatus.isTransitioning)
            }
        }
    }

    private var systemExtensionStatusDetail: LocalizedStringKey {
        if wireGuardSession.systemExtensionStatus == .uninstalling {
            return "Restart macOS to finish removing the Network Extension before requesting activation again."
        }
        if !store.runtimeEntitlements.systemExtensionInstall {
            return "This build cannot activate the Network Extension. Run a signed copy of ThruRNDIS from Applications."
        }

        return switch wireGuardSession.systemExtensionStatus {
        case .unknown:
            "The Network Extension status has not been checked yet."
        case .checking:
            "Checking whether the Network Extension is active."
        case .inactive:
            "Request activation, then allow ThruRNDIS in System Settings before connecting."
        case .activationRequested, .awaitingUserApproval:
            "Activation was requested. Approve the Network Extension in System Settings."
        case .active:
            "The Network Extension is active and ready to connect."
        case .uninstalling:
            "Restart macOS to finish removing the Network Extension before requesting activation again."
        case .restartRequired:
            "Restart macOS to finish activating the Network Extension."
        case .failed:
            "The Network Extension status could not be determined."
        }
    }

    private var systemExtensionStatusAppearance: SettingsStatusAppearance {
        switch wireGuardSession.systemExtensionStatus {
        case .active:
            .active
        case .checking, .activationRequested:
            .transitioning
        case .inactive:
            .inactive
        case .awaitingUserApproval, .uninstalling, .restartRequired:
            .attention
        case .failed:
            .failed
        case .unknown:
            .unknown
        }
    }
}
