/*
Copyright (C) 2026 Afcoo.
*/

import Combine
import SwiftUI

struct VMAssetConfigurationView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var assetWorkflowCoordinator: VMAssetWorkflowCoordinator

    var body: some View {
        Group {
            LabeledContent("Status") {
                SettingsStatusLabel(
                    title: assetWorkflowCoordinator.installState.statusText,
                    appearance: assetStatusAppearance
                )
            }

            selectedFolder

            HStack(spacing: 12) {
                if assetWorkflowCoordinator.isBusy {
                    Button("Cancel") {
                        assetWorkflowCoordinator.cancelInstall()
                    }
                } else {
                    Button("Check & Download Latest") {
                        assetWorkflowCoordinator.installLatest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canEditVMConfiguration)
                }

                Spacer()

                Button("Choose Folder…") {
                    chooseFolder()
                }
                .disabled(
                    !store.canEditVMConfiguration
                        || assetWorkflowCoordinator.isBusy
                )

                Button("Clear") {
                    assetWorkflowCoordinator.clearSelection()
                }
                .disabled(
                    !store.canEditVMConfiguration
                        || assetWorkflowCoordinator.currentSelection == nil
                        || assetWorkflowCoordinator.isBusy
                )
                .help(
                    "Clear the selected VM asset paths without deleting managed release files."
                )
            }
        }
    }

    private var selectedFolder: some View {
        LabeledContent("Asset folder") {
            Group {
                if let selectedFolderURL = assetWorkflowCoordinator.selectedFolderURL {
                    Text(verbatim: selectedFolderURL.path)
                } else {
                    Text("Not selected")
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 380, alignment: .trailing)
            .textSelection(.enabled)
        }
    }

    private var assetStatusAppearance: SettingsStatusAppearance {
        switch assetWorkflowCoordinator.installState {
        case .ready:
            .active
        case .failed:
            .failed
        case .checking, .downloading, .verifying, .extracting, .activating:
            .transitioning
        case .idle:
            .unknown
        }
    }

    private func chooseFolder() {
        guard let url = FilePicker.chooseDirectory(
            title: String(localized: "Choose extracted vm_assets folder"),
            initialURL: assetWorkflowCoordinator.selectedFolderURL
        ) else {
            return
        }
        assetWorkflowCoordinator.selectManualFolder(url)
    }
}

struct VMAssetDocumentationLinkView: View {
    private let documentationURL = URL(
        string: "https://github.com/Afcoo/ThruRNDIS_VM_Assets"
    )!

    var body: some View {
        HStack {
            Spacer()

            Link(destination: documentationURL) {
                Label(
                    "What are VM Assets",
                    systemImage: "questionmark.circle"
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct VMAssetAlert: Identifiable {
    let id = UUID()
    let message: String
}

private struct VMAssetErrorAlertModifier: ViewModifier {
    @EnvironmentObject private var assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    @State private var alert: VMAssetAlert?

    func body(content: Content) -> some View {
        content
            .onReceive(
                assetWorkflowCoordinator.$errorMessage.compactMap { $0 }
            ) { message in
                alert = VMAssetAlert(message: message)
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text("VM Asset Error"),
                    message: Text(verbatim: alert.message),
                    dismissButton: .default(Text("OK")) {
                        assetWorkflowCoordinator.clearError()
                    }
                )
            }
    }
}

extension View {
    func vmAssetErrorAlert() -> some View {
        modifier(VMAssetErrorAlertModifier())
    }
}
