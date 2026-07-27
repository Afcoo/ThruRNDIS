/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftUI

struct GeneralView: View {
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @EnvironmentObject private var eventLog: EventLogStore
    @State private var eventLogSaveError: EventLogSaveError?
    @State private var selectedEventLogCategory: EventLogCategory?
    @State private var isExportingEventLogs = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Open ThruRNDIS at Login",
                    isOn: Binding(
                        get: { appPreferences.launchAtLoginSnapshot.isEnabled },
                        set: setLaunchAtLoginEnabled
                    )
                )
            }

            Section("Debug Mode") {
                Toggle(
                    "Enable Debug Mode",
                    isOn: $appPreferences.isDebugModeEnabled
                )
            }

            Section {
                EventLogGroup(
                    text: displayedEventLogText,
                    hasEntries: !eventLog.isEmpty,
                    canExportLogs: eventLog.hasPersistedLogFiles
                        && !isExportingEventLogs,
                    clearAction: {
                        eventLog.clear()
                    },
                    copyAction: {
                        Clipboard.copy(displayedEventLogText)
                    },
                    exportAction: exportEventLogs
                )
            } header: {
                HStack(spacing: 10) {
                    Text("Event Log")

                    Spacer()

                    Picker("Category", selection: $selectedEventLogCategory) {
                        Text("All")
                            .tag(nil as EventLogCategory?)

                        ForEach(EventLogCategory.allCases) { category in
                            Text(category.localizedName)
                                .tag(category as EventLogCategory?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(width: 125)
                }
            }
        }
        .alert(item: $eventLogSaveError) { error in
            Alert(
                title: Text("Event Log"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            try appPreferences.setLaunchAtLoginEnabled(isEnabled)
        } catch {
            eventLog.append(
                "Could not update Launch at Login: " +
                    EventLogErrorFormatter.description(for: error),
                level: .error,
                category: .application
            )
        }
    }

    private func exportEventLogs() {
        guard !isExportingEventLogs,
              eventLog.hasPersistedLogFiles,
              let destinationDirectoryURL = FilePicker.chooseDirectory(
                title: String(localized: "Export Event Log")
              ) else {
            return
        }

        isExportingEventLogs = true
        Task { @MainActor in
            defer {
                isExportingEventLogs = false
            }

            do {
                let exportedURL =
                    try await eventLog.exportPersistedLogFiles(
                        to: destinationDirectoryURL
                    )
                NSWorkspace.shared.activateFileViewerSelecting([
                    exportedURL,
                ])
            } catch {
                eventLogSaveError = EventLogSaveError(
                    message: error.localizedDescription
                )
            }
        }
    }

    private var displayedEventLogText: String {
        eventLog.text(
            isDebugModeEnabled: appPreferences.isDebugModeEnabled,
            category: selectedEventLogCategory
        )
    }
}

private struct EventLogSaveError: Identifiable {
    let id = UUID()
    let message: String
}
