/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct LogTextView: View {
    let text: String

    var body: some View {
        GroupBox {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }
}
