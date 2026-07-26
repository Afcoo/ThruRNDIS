/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct GeneralView: View {
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @EnvironmentObject private var eventLog: EventLogStore
    @State private var eventLogSaveError: EventLogSaveError?
    @State private var selectedEventLogCategory: EventLogCategory?

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
                    clearAction: {
                        eventLog.clear()
                    },
                    copyAction: {
                        Clipboard.copy(displayedEventLogText)
                    },
                    saveAction: saveEventLog
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

    private func saveEventLog() {
        let logText = eventLog.text
        guard !logText.isEmpty,
              let url = FilePicker.chooseSaveFile(
                title: String(localized: "Event Log"),
                defaultName: EventLogExportFormatter.defaultFileName()
              ) else {
            return
        }

        do {
            try EventLogExportFormatter.content(logText: logText)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            eventLogSaveError = EventLogSaveError(message: error.localizedDescription)
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
