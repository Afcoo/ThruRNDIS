/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

enum SettingsStatusAppearance {
    case active
    case stopped
    case inactive
    case transitioning
    case attention
    case failed
    case unknown

    var systemImage: String {
        switch self {
        case .active:
            "checkmark.circle.fill"
        case .stopped:
            "stop.circle.fill"
        case .transitioning:
            "arrow.triangle.2.circlepath"
        case .inactive, .attention, .failed:
            "exclamationmark.triangle.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .active:
            .green
        case .stopped, .unknown:
            .secondary
        case .inactive, .failed:
            .red
        case .transitioning, .attention:
            .orange
        }
    }
}

struct SettingsStatusLabel: View {
    let title: String
    let appearance: SettingsStatusAppearance

    var body: some View {
        Label(title, systemImage: appearance.systemImage)
            .foregroundStyle(appearance.color)
    }
}
