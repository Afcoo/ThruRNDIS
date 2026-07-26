/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct EventLogGroup: View {
    let text: String
    let hasEntries: Bool
    let clearAction: () -> Void
    let copyAction: () -> Void
    let saveAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogTextView(text: text.isEmpty ? String(localized: "No events.") : text)
                .frame(height: 300)

            HStack(spacing: 8) {
                Button(action: clearAction) {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(!hasEntries)
                .help("Clear all event logs")

                Spacer()

                Button(action: copyAction) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(text.isEmpty)

                Button(action: saveAction) {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasEntries)
            }
        }
    }
}
