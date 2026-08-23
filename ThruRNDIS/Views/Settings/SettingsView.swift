/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .general

    let openConsole: () -> Void
    let resetAndQuit: () -> Void

    var body: some View {
        NavigationSplitView {
            List(availableSections, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 170, max: 170)
        } detail: {
            Group {
                switch selectedSection {
                case .general:
                    GeneralView()
                case .virtualMachine:
                    VirtualMachineView(openConsole: openConsole)
                case .usbDevices:
                    USBDevicesView()
                case .networkRoute:
                    NetworkRouteView()
                case .info:
                    InfoView(resetAndQuit: resetAndQuit)
                }
            }
            .navigationTitle(selectedSection.title)
            .scrollEdgeEffectHidden(true, for: .top)
        }
        .formStyle(.grouped)
        .frame(minWidth: 760, minHeight: 480)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            // Individual settings stores refresh their own system state.
        }
    }

    private var availableSections: [SettingsSection] {
        SettingsSection.allCases
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case virtualMachine
    case usbDevices
    case networkRoute
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
        case .networkRoute:
            "Network Route"
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
        case .networkRoute:
            "network"
        case .info:
            "info.circle"
        }
    }
}
