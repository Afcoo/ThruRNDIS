/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
@preconcurrency import Virtualization

@MainActor
protocol USBAccessoryCoordinating: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var onStatusMessage: ((String) -> Void)? { get set }
    var onEventLog: ((String) -> Void)? { get set }
    var onAccessoryAvailable: ((USBAccessoryRecord) -> Void)? { get set }
    var onAccessoryUnavailable: ((UInt64) -> Void)? { get set }
    var onUnexpectedDetach: ((UInt64, String) -> Void)? { get set }
    var runtimeStateProvider: (() -> VMRuntimeState)? { get set }

    var accessories: [USBAccessoryRecord] { get }
    var isAccessoryMonitoring: Bool { get }
    var selectedAccessoryID: UInt64? { get }
    var attachedAccessoryID: UInt64? { get }
    var vmSessionAccessoryID: UInt64? { get }
    var canStartMonitoring: Bool { get }
    var canStopMonitoring: Bool { get }
    var canReloadMonitoring: Bool { get }

    func canRequestAttachment(for accessoryID: UInt64) -> Bool
    func canDetachAccessory(runtimeState: VMRuntimeState) -> Bool
    func selectAccessory(id: UInt64?)
    func startMonitoring(reason: String, completion: (() -> Void)?)
    func stopMonitoring(reason: String, completion: (() -> Void)?)
    func reloadMonitoring(reason: String)
    func prepareForIntentionalVMStop()
    func resetForVMStart()
    func clearAttachmentForStoppedVM()
    func attachAccessory(
        id accessoryID: UInt64,
        to virtualMachine: VZVirtualMachine?,
        completion: ((Bool) -> Void)?
    )
    func handlePassthroughDisconnect(device: VZUSBPassthroughDevice)
}

extension USBAccessoryCoordinator: USBAccessoryCoordinating {}
