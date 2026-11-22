/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftTerm
import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var consoleSession: ConsoleSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("VM serial terminal", systemImage: "terminal")

                Text(store.vmDisplayState.localizedName)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    let transcript = consoleSession.output.plainText
                    if !transcript.isEmpty {
                        Clipboard.copy(transcript)
                    }
                } label: {
                    Label("Copy All", systemImage: "document.on.document")
                }
                .disabled(consoleSession.output.data.isEmpty)

                Button {
                    consoleSession.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }

            SwiftTermConsoleView(
                output: consoleSession.output,
                isInputEnabled: store.canSendConsoleInput,
                sendInput: { data in
                    store.sendConsoleBytes(data)
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(minWidth: 680, minHeight: 420)
    }
}

private struct SwiftTermConsoleView: NSViewRepresentable {
    let output: ConsoleOutputState
    let isInputEnabled: Bool
    let sendInput: @MainActor (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(sendInput: sendInput)
    }

    func makeNSView(context: Context) -> ConsoleTerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let terminalView = ConsoleTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), font: font)
        let foreground = NSColor(calibratedRed: 0.86, green: 0.90, blue: 0.86, alpha: 1)
        let background = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.07, alpha: 1)

        terminalView.terminalDelegate = context.coordinator
        terminalView.autoresizingMask = [.width, .height]
        terminalView.nativeForegroundColor = foreground
        terminalView.nativeBackgroundColor = background
        terminalView.layer?.backgroundColor = background.cgColor
        terminalView.caretColor = .systemGreen
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = false
        terminalView.backspaceSendsControlH = false
        terminalView.terminal.changeHistorySize(4_000)
        terminalView.menu = TextEditingMenuBuilder.makeMenu(target: terminalView)

        return terminalView
    }

    func updateNSView(_ terminalView: ConsoleTerminalView, context: Context) {
        terminalView.isInputEnabled = isInputEnabled
        terminalView.updateOutput(output)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let sendInput: @MainActor (Data) -> Void

        init(sendInput: @escaping @MainActor (Data) -> Void) {
            self.sendInput = sendInput
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard let terminalView = source as? ConsoleTerminalView, terminalView.isInputEnabled else {
                return
            }

            let payload = Data(data)
            Task { @MainActor [sendInput] in
                sendInput(payload)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

private final class ConsoleTerminalView: SwiftTerm.TerminalView {
    var isInputEnabled = false

    private var output = ConsoleOutputState()
    private var nextByteOffset = 0
    private var renderedResetSequence = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.initialFirstResponder = self
        window?.makeFirstResponder(self)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) {
            return isInputEnabled
        }
        return super.validateUserInterfaceItem(item)
    }

    func updateOutput(_ output: ConsoleOutputState) {
        self.output = output
        renderPendingOutput()
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        guard !selectionActive else { return }

        // Let the terminal finish handling the click or key that cleared the selection.
        DispatchQueue.main.async { [weak self] in
            self?.renderPendingOutput()
        }
    }

    private func renderPendingOutput() {
        let hasReset = renderedResetSequence != output.resetSequence
        guard hasReset || !selectionActive else { return }

        if hasReset || nextByteOffset < output.startOffset {
            renderedResetSequence = output.resetSequence
            nextByteOffset = output.startOffset
            selectNone()
            feed(text: "\u{1B}c\u{1B}[3J\u{1B}[2J\u{1B}[H")
        }

        let newBytes = output.data.dropFirst(nextByteOffset - output.startOffset)
        guard !newBytes.isEmpty else { return }
        nextByteOffset += newBytes.count
        feed(byteArray: Array(newBytes)[...])
    }
}
