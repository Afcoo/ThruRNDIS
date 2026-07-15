/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct EventLogGroup: View {
    let text: String
    let clearAction: () -> Void
    let copyAction: () -> Void
    let saveAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogTextView(text: text.isEmpty ? String(localized: "No events.") : text)
                .frame(height: 260)

            HStack(spacing: 8) {
                Button(action: clearAction) {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear event log")

                Spacer()

                Button(action: copyAction) {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button(action: saveAction) {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(text.isEmpty)
        }
    }
}
