/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @State private var selectedSection: SettingsSection = .general

    let openConsole: () -> Void
    let resetAndRestart: () -> Void
    let openWireGuardConfigurationFolder: () -> Void
    let copyWireGuardConfiguration: () -> Void
    let saveWireGuardConfiguration: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
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
                case .wireGuard:
                    WireGuardView(
                        openConfigurationFolder: openWireGuardConfigurationFolder,
                        copyConfiguration: copyWireGuardConfiguration,
                        saveConfiguration: saveWireGuardConfiguration
                    )
                case .dummyEthernet:
                    DummyEthernetView()
                case .info:
                    InfoView(resetAndRestart: resetAndRestart)
                }
            }
            .navigationTitle(selectedSection.title)
            .scrollEdgeEffectHidden(true, for: .top)
        }
        .formStyle(.grouped)
        .frame(minWidth: 760, minHeight: 480)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            appPreferences.refreshLaunchAtLoginStatus()
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case virtualMachine
    case usbDevices
    case wireGuard
    case dummyEthernet
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
        case .dummyEthernet:
            "Dummy Ethernet"
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
        case .dummyEthernet:
            "network"
        case .info:
            "info.circle"
        }
    }
}
