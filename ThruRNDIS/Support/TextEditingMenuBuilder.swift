/*
Copyright (C) 2026 Afcoo.
*/

import AppKit

@MainActor
enum TextEditingMenuBuilder {
    static func makeMenu(target: NSResponder? = nil) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        let commands: [(title: String, action: Selector, keyEquivalent: String)] = [
            (String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            (String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            (String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ]

        for command in commands {
            menu.addItem(
                withTitle: command.title,
                action: command.action,
                keyEquivalent: target == nil ? command.keyEquivalent : ""
            ).target = target
        }
        return menu
    }
}
