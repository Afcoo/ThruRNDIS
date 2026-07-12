/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct GeneralView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Open RTPVM at Login",
                    isOn: Binding(
                        get: { store.launchAtLoginSnapshot.isEnabled },
                        set: { store.setLaunchAtLoginEnabled($0) }
                    )
                )

                if store.launchAtLoginSnapshot.requiresApproval {
                    Button("Open Login Items Settings") {
                        store.openLoginItemsSettings()
                    }
                }
            }
        }
    }
}
