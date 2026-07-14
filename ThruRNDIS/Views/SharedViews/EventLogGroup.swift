/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct EventLogGroup: View {
    let text: String
    var height: CGFloat? = nil
    var minHeight: CGFloat? = nil
    let eraseAction: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Event Log")
                        .font(.headline)

                    Spacer()

                    Button(action: eraseAction) {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(text.isEmpty)
                    .help("Clear event log")
                }

                LogTextView(text: text.isEmpty ? "No events." : text)
                    .frame(height: height)
                    .frame(minHeight: minHeight)
            }
            .padding(.vertical, 4)
        }
    }
}
