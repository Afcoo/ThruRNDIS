/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct CommandBlock: View {
    let title: LocalizedStringKey
    let command: String
    var copyEnabled = true

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.headline)

                    Spacer()

                    Button {
                        Clipboard.copy(command)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(!copyEnabled)
                }

                Text(verbatim: command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
