/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct InfoView: View {
    @EnvironmentObject private var store: TetheringStore
    @EnvironmentObject private var assetWorkflowCoordinator: VMAssetWorkflowCoordinator
    @State private var resetConfirmation: ResetConfirmation?
    @State private var isOpenSourceAcknowledgementsPresented = false

    let resetAndRestart: () -> Void

    private let projectURL = URL(
        string: "https://github.com/Afcoo/ThruRNDIS"
    )!
    private let vmAssetReleasesURL = URL(
        string: "https://github.com/Afcoo/ThruRNDIS_VM_Assets/releases"
    )!

    var body: some View {
        Form {
            Section("ThruRNDIS") {
                LabeledContent("Version", value: versionText)
            }

            Section("Reset") {
                HStack(spacing: 16) {
                    Button("Restart Onboarding…") {
                        store.requestOnboardingPresentation()
                    }

                    Button("Reset All Settings…", role: .destructive) {
                        resetConfirmation = .reset
                    }
                    .disabled(!store.canResetAppSettings || assetWorkflowCoordinator.isBusy)
                }
            }

            Section("Help") {
                HStack(spacing: 16) {
                    Link("Project Website", destination: projectURL)

                    Link("VM Asset Releases", destination: vmAssetReleasesURL)
                }
            }

            Section("Open Source Acknowledgements") {
                Button {
                    isOpenSourceAcknowledgementsPresented = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SwiftTerm")
                                .foregroundStyle(.primary)

                            Text("VT100/Xterm terminal emulator · MIT License")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $isOpenSourceAcknowledgementsPresented) {
            OpenSourceAcknowledgementsView()
        }
        .alert(item: $resetConfirmation) { confirmation in
            switch confirmation {
            case .reset:
                Alert(
                    title: Text("Reset All Settings?"),
                    message: Text("Saved asset selections, VM runtime preferences, onboarding state, and Launch at Login will be reset. Managed VM asset files will be preserved."),
                    primaryButton: .destructive(Text("Continue")) {
                        Task { @MainActor in
                            resetConfirmation = .restart
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .restart:
                Alert(
                    title: Text("ThruRNDIS Will Restart"),
                    message: Text("ThruRNDIS will restart immediately after resetting. Onboarding will appear again; preserved managed VM assets can be selected without downloading them again."),
                    primaryButton: .destructive(Text("Reset and Restart")) {
                        resetAndRestart()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? String(localized: "Unknown")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? String(localized: "Unknown")
        return String(localized: "\(version) (\(build))")
    }
}

private enum ResetConfirmation: Identifiable {
    case reset
    case restart

    var id: Self { self }
}

private struct OpenSourceAcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private let projectURL = URL(
        string: "https://github.com/migueldeicaza/SwiftTerm/tree/b1262db5b6bea699a8260a8c66999436c508ca56"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SwiftTerm")
                        .font(.title2.weight(.semibold))

                    Text("VT100/Xterm terminal emulator used by the VM console.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Link("Project Website", destination: projectURL)
            }

            Divider()

            ScrollView {
                Text(verbatim: Self.licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("MIT License")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
    }

    private static let licenseText = """
    Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
    Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
    Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
    Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

    Permission is hereby granted, free of charge, to any person obtaining
    a copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
    LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
    OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
    WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
