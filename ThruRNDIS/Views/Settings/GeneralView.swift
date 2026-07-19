/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct GeneralView: View {
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @EnvironmentObject private var eventLog: EventLogStore
    @State private var eventLogSaveError: EventLogSaveError?

    var body: some View {
        Form {
            Section("앱") {
                Toggle(
                    "Open ThruRNDIS at Login",
                    isOn: Binding(
                        get: { appPreferences.launchAtLoginSnapshot.isEnabled },
                        set: setLaunchAtLoginEnabled
                    )
                )
            }

            Section("Event Log") {
                EventLogGroup(
                    text: eventLog.text,
                    clearAction: {
                        eventLog.clear()
                    },
                    copyAction: {
                        Clipboard.copy(eventLog.text)
                    },
                    saveAction: saveEventLog
                )
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
                source: .app
            )
        }
    }

    private func saveEventLog() {
        guard !eventLog.text.isEmpty,
              let url = FilePicker.chooseSaveFile(
                title: String(localized: "Event Log"),
                defaultName: "ThruRNDIS Event Log.txt"
              ) else {
            return
        }

        do {
            try eventLog.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            eventLogSaveError = EventLogSaveError(message: error.localizedDescription)
        }
    }
}

private struct EventLogSaveError: Identifiable {
    let id = UUID()
    let message: String
}
