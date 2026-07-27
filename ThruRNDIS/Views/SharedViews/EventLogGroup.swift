/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct EventLogGroup: View {
    let text: String
    let hasEntries: Bool
    let canExportLogs: Bool
    let showsOpenLogsButton: Bool
    let clearAction: () -> Void
    let copyAction: () -> Void
    let exportAction: () -> Void
    let openLogsAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogTextView(
                text: text.isEmpty ? String(localized: "No events.") : text
            )
                .frame(height: 300)

            HStack(spacing: 8) {
                Button(action: copyAction) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(text.isEmpty)

                Button(action: exportAction) {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!canExportLogs)

                if showsOpenLogsButton {
                    Button(action: openLogsAction) {
                        Label("Open Logs Folder", systemImage: "folder")
                    }
                }

                Spacer()

                Button(action: clearAction) {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(!hasEntries)
                .help("Clear event logs from this window without deleting saved log files")
            }
        }
    }
}
