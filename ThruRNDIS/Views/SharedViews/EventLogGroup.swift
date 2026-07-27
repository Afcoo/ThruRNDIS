/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct EventLogGroup: View {
    let text: String
    let hasEntries: Bool
    let canExportLogs: Bool
    let clearAction: () -> Void
    let copyAction: () -> Void
    let exportAction: () -> Void

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
                    Label("Export Logs…", systemImage: "square.and.arrow.down")
                }
                .disabled(!canExportLogs)

                Spacer()

                Button(action: clearAction) {
                    Label("Clear Display", systemImage: "trash")
                }
                .disabled(!hasEntries)
                .help("Clear event logs from this window without deleting saved log files")
            }
        }
    }
}
