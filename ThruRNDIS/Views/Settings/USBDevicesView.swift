/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct USBDevicesView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var usbSession: USBSessionStore
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @State private var replacementConfirmation: USBAccessoryReplacementConfirmation?

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
            }

            Section("USB Devices") {
                HStack {
                    Toggle(
                        "Ask to attach when device is available",
                        isOn: $appPreferences.shouldAskToAttachDetectedUSBDevices
                    )
                    .toggleStyle(.checkbox)

                    Spacer()

                    Button("Attach") {
                        requestSelectedAccessoryAttachment()
                    }
                    .disabled(!store.canAttachSelectedAccessory)

                    Button("Detach") {
                        store.detachAccessory()
                    }
                    .disabled(!store.canDetachSelectedAccessory)
                }

                Table(
                    displayedAccessories,
                    selection: selectedAccessoryBinding
                ) {
                    TableColumn("Auto Connect") { accessory in
                        Toggle(
                            isOn: autoConnectBinding(for: accessory)
                        ) {
                            Text("Auto Connect for \(accessory.deviceName)")
                        }
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .disabled(
                            !store.canEnableAutoConnect(for: accessory)
                                && !store.isAutoConnectEnabled(for: accessory)
                        )
                    }
                    .width(80)

                    TableColumn("Device") { accessory in
                        HStack(spacing: 6) {
                            Group {
                                if accessory.id == usbSession.attachedAccessoryID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityLabel(Text("Attached"))
                                }
                            }
                            .frame(width: 16)

                            Text(verbatim: accessory.deviceName)
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                    }

                    TableColumn("VID:PID") { accessory in
                        Text(verbatim: accessory.usbIDText)
                            .monospaced()
                            .lineLimit(1)
                    }
                    .width(90)

                    TableColumn("Registry") { accessory in
                        Text(verbatim: accessory.registryIDText)
                    }
                    .width(100)
                }
                .frame(height: 180)
            }
        }
        .alert(item: $replacementConfirmation) { confirmation in
            Alert(
                title: Text("Replace Attached USB Device?"),
                message: Text(
                    "The attached USB device will be detached, and the selected device will be attached."
                ),
                primaryButton: .destructive(Text("Detach and Attach")) {
                    store.replaceAttachedAccessory(
                        with: confirmation.replacementAccessoryID
                    )
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func requestSelectedAccessoryAttachment() {
        guard let selectedAccessoryID = usbSession.selectedAccessoryID else {
            store.requestAttachSelectedAccessory()
            return
        }

        if let attachedAccessoryID = usbSession.attachedAccessoryID,
           attachedAccessoryID != selectedAccessoryID {
            replacementConfirmation = USBAccessoryReplacementConfirmation(
                replacementAccessoryID: selectedAccessoryID
            )
            return
        }

        store.requestAttachSelectedAccessory()
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

    private func autoConnectBinding(
        for accessory: USBAccessoryRecord
    ) -> Binding<Bool> {
        Binding(
            get: { store.isAutoConnectEnabled(for: accessory) },
            set: {
                store.setAutoConnectEnabled($0, for: accessory)
            }
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

private struct USBAccessoryReplacementConfirmation: Identifiable {
    let replacementAccessoryID: UInt64

    var id: UInt64 { replacementAccessoryID }
}
