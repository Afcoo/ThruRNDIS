/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: TetheringStore
    @State private var selectedSection: SettingsSection = .general

    let openConsole: () -> Void
    let resetAndRestart: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selectedSection {
                case .general:
                    GeneralView()
                case .virtualMachine:
                    VirtualMachineView(openConsole: openConsole)
                case .usbDevices:
                    USBDevicesView()
                case .wireGuard:
                    WireGuardView()
                case .info:
                    InfoView(resetAndRestart: resetAndRestart)
                }
            }
            .scenePadding()
        }
        .formStyle(.grouped)
        .frame(width: 800, height: 520)
        .onAppear {
            store.refreshLaunchAtLoginStatus()
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case virtualMachine
    case usbDevices
    case wireGuard
    case info

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general:
            "General"
        case .virtualMachine:
            "Virtual Machine"
        case .usbDevices:
            "USB Devices"
        case .wireGuard:
            "WireGuard"
        case .info:
            "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .virtualMachine:
            "server.rack"
        case .usbDevices:
            "cable.connector"
        case .wireGuard:
            "lock.shield"
        case .info:
            "info.circle"
        }
    }
}
