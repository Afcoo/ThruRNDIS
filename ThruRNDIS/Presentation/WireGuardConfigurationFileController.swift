/*
Copyright (C) 2026 Afcoo.
*/

import AppKit

@MainActor
final class WireGuardConfigurationFileController {
    private let wireGuardSession: WireGuardSessionStore
    private let eventLog: EventLogStore

    init(
        wireGuardSession: WireGuardSessionStore,
        eventLog: EventLogStore
    ) {
        self.wireGuardSession = wireGuardSession
        self.eventLog = eventLog
    }

    func openConfigurationFolder() {
        let directoryURL = wireGuardSession.configurationDirectoryURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            appendEventLog(
                "WireGuard configuration folder not opened because it does not exist: " +
                    directoryURL.path
            )
            return
        }

        guard NSWorkspace.shared.open(directoryURL) else {
            appendEventLog(
                "WireGuard configuration folder open failed: \(directoryURL.path)"
            )
            return
        }

        appendEventLog(
            "Opened WireGuard configuration folder: \(directoryURL.path)"
        )
    }

    func copyConfiguration() {
        guard wireGuardSession.canExportConfiguration else {
            appendEventLog(
                "WireGuard configuration not copied: VM endpoint is unknown."
            )
            return
        }

        Clipboard.copy(wireGuardSession.clientConfiguration)
        appendEventLog("WireGuard host configuration copied to clipboard.")
    }

    func saveConfiguration() {
        guard wireGuardSession.canExportConfiguration else {
            appendEventLog(
                "WireGuard configuration not saved: VM endpoint is unknown."
            )
            return
        }

        guard let url = FilePicker.chooseSaveFile(
            title: String(localized: "Save WireGuard Configuration"),
            defaultName: "thrurndis.conf"
        ) else {
            return
        }

        do {
            try wireGuardSession.clientConfiguration.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            appendEventLog(
                "WireGuard host configuration saved to \(url.path)."
            )
        } catch {
            appendEventLog(
                "WireGuard configuration save failed: " +
                    EventLogErrorFormatter.description(for: error)
            )
        }
    }

    private func appendEventLog(_ message: String) {
        eventLog.append(message, source: .wireGuard)
    }
}
