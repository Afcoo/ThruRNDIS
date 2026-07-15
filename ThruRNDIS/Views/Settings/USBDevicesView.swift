/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct USBDevicesView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var usbSession: USBSessionStore

    var body: some View {
        Form {
            if !store.runtimeEntitlements.accessoryAccessUSB {
                Section("Entitlement") {
                    Label(
                        "USB monitoring is unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)

                    Text(verbatim: RuntimeEntitlement.accessoryAccessUSB.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("Status") {
                    Label(
                        usbSession.isAccessoryMonitoring
                            ? String(localized: "Listening")
                            : String(localized: "Stopped"),
                        systemImage: usbSession.isAccessoryMonitoring
                            ? "dot.radiowaves.left.and.right"
                            : "stop.circle"
                    )
                }

                HStack {
                    Button("Start") {
                        store.startAccessoryMonitoring()
                    }
                    .disabled(!store.canStartAccessoryMonitoring)

                    Button("Reload") {
                        store.reloadAccessoryMonitoring()
                    }
                    .disabled(!store.canReloadAccessoryMonitoring)

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
                if usbSession.accessories.isEmpty {
                    LabeledContent("Available devices", value: String(localized: "None"))
                } else {
                    List(selection: selectedAccessoryBinding) {
                        ForEach(usbSession.accessories) { accessory in
                            USBAccessoryRow(
                                accessory: accessory,
                                isAttached: accessory.id == usbSession.attachedAccessoryID
                            )
                            .tag(accessory.id)
                        }
                    }
                    .frame(height: 180)
                }

                HStack {
                    Button("Attach Selected") {
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

    private var selectedAccessoryBinding: Binding<UInt64?> {
        Binding(
            get: { usbSession.selectedAccessoryID },
            set: { store.selectAccessory(id: $0) }
        )
    }
}

private struct USBAccessoryRow: View {
    let accessory: USBAccessoryRecord
    let isAttached: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isAttached ? "checkmark.circle.fill" : "cable.connector")
                .foregroundStyle(isAttached ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: accessory.usbIDText)

                Text("Class \(accessory.classText) · Registry \(accessory.registryIDText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isAttached {
                Text("Attached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
