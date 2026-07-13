/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct USBDevicesView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        Form {
            if !store.runtimeEntitlements.accessoryAccessUSB {
                Section("Entitlement") {
                    Label(
                        "USB monitoring is unavailable in this unsigned build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)

                    Text(RuntimeEntitlement.accessoryAccessUSB.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("Status") {
                    Label(
                        store.isAccessoryMonitoring ? "Listening" : "Stopped",
                        systemImage: store.isAccessoryMonitoring
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
                if store.accessories.isEmpty {
                    LabeledContent("Available devices", value: "None")
                } else {
                    List(selection: $store.selectedAccessoryID) {
                        ForEach(store.accessories) { accessory in
                            USBAccessoryRow(
                                accessory: accessory,
                                isAttached: accessory.id == store.attachedAccessoryID
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
}

private struct USBAccessoryRow: View {
    let accessory: USBAccessoryRecord
    let isAttached: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isAttached ? "checkmark.circle.fill" : "cable.connector")
                .foregroundStyle(isAttached ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.usbIDText)

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
