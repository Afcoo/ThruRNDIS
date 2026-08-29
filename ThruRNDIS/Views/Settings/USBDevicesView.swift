/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct USBDevicesView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var usbSession: USBSessionStore
    @EnvironmentObject private var appPreferences: AppPreferencesStore

    var body: some View {
        Form {
            if !store.runtimeEntitlements.accessoryAccessUSB {
                Section {
                    Label(
                        "USB monitoring is unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Status") {
                    SettingsStatusLabel(
                        title: usbStatusTitle,
                        appearance: usbStatusAppearance
                    )
                }

                HStack {
                    if usbSession.isAccessoryMonitoring {
                        Button("Restart") {
                            store.reloadAccessoryMonitoring()
                        }
                        .disabled(!store.canReloadAccessoryMonitoring)
                    } else {
                        Button("Start") {
                            store.startAccessoryMonitoring()
                        }
                        .disabled(!store.canStartAccessoryMonitoring)
                    }

                    Button("Stop") {
                        store.stopAccessoryMonitoring()
                    }
                    .disabled(!store.canStopAccessoryMonitoring)
                }
            } header: {
                Text("AccessoryAccess Listener")
            } footer: {
                Text("New devices require approval, and only one USB device can be attached during a VM session.")
            }

            Section("USB Devices") {
                Table(
                    displayedAccessories,
                    selection: selectedAccessoryBinding
                ) {
                    TableColumn("") { accessory in
                        if accessory.id == usbSession.attachedAccessoryID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityLabel(Text("Attached"))
                        } else {
                            EmptyView()
                        }
                    }
                    .width(20)

                    TableColumn("VID:PID") { accessory in
                        Text(verbatim: accessory.usbIDText)
                            .monospaced()
                            .lineLimit(1)
                    }
                    .width(90)

                    TableColumn("Device") { accessory in
                        Text(verbatim: accessory.deviceName)
                            .lineLimit(1)
                    }

                    TableColumn("Class") { accessory in
                        Text(verbatim: accessory.classText)
                    }
                    .width(70)

                    TableColumn("Registry") { accessory in
                        Text(verbatim: accessory.registryIDText)
                    }
                    .width(100)
                }
                .frame(height: 180)

                HStack {
                    Toggle(
                        "Ask to attach when device is available",
                        isOn: $appPreferences.shouldAskToAttachDetectedUSBDevices
                    )
                    .toggleStyle(.checkbox)

                    Spacer()

                    Button("Attach") {
                        store.requestAttachSelectedAccessory()
                    }
                    .disabled(!store.canAttachSelectedAccessory)

                    Button("Detach") {
                        store.detachAccessory()
                    }
                    .disabled(!store.canDetachAccessory)
                }
            }
        }
    }

    private var displayedAccessories: [USBAccessoryRecord] {
        let accessories = usbSession.accessories
        guard let attachedAccessoryID = usbSession.attachedAccessoryID,
              let attachedIndex = accessories.firstIndex(where: {
                $0.id == attachedAccessoryID
              }),
              attachedIndex != accessories.startIndex else {
            return accessories
        }

        var displayedAccessories = accessories
        let attachedAccessory = displayedAccessories.remove(at: attachedIndex)
        displayedAccessories.insert(attachedAccessory, at: 0)
        return displayedAccessories
    }

    private var selectedAccessoryBinding: Binding<UInt64?> {
        Binding(
            get: { usbSession.selectedAccessoryID },
            set: { store.selectAccessory(id: $0) }
        )
    }

    private var usbStatusTitle: String {
        guard store.runtimeEntitlements.accessoryAccessUSB else {
            return String(localized: "Inactive")
        }

        return usbSession.isAccessoryMonitoring
            ? String(localized: "Listening")
            : String(localized: "Stopped")
    }

    private var usbStatusAppearance: SettingsStatusAppearance {
        guard store.runtimeEntitlements.accessoryAccessUSB else {
            return .inactive
        }

        return usbSession.isAccessoryMonitoring ? .active : .stopped
    }
}
