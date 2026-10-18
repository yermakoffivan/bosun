import AppKit
import SwiftUI

/// The Fonts tab of the Settings window: the terminal's font and the interface's, each a family and a size, with
/// a line of each to see it by. Changes apply as they're made (the app watches its defaults).
struct FontsSection: View {
    @AppStorage(AppSettings.Key.terminalFontFamily) private var terminalFamily = ""
    @AppStorage(AppSettings.Key.terminalFontSize) private var terminalSize = 0.0
    @AppStorage(AppSettings.Key.interfaceFontFamily) private var interfaceFamily = ""
    @AppStorage(AppSettings.Key.interfaceFontSize) private var interfaceSize = Fonts.baseInterfaceSize
    @State private var fixedPitch: [String] = []
    @State private var all: [String] = []
    /// What the Ghostty config gives terminals, shown for "From Ghostty config".
    let ghosttyFamily: String?
    let ghosttySize: Double?

    var body: some View {
        Section {
            Picker("Font", selection: $terminalFamily) {
                Text(ghosttyFamily.map { "From Ghostty config (\($0))" } ?? "From Ghostty config").tag("")
                Divider()
                ForEach(fixedPitch, id: \.self) { Text($0).tag($0) }
                if !terminalFamily.isEmpty, !fixedPitch.contains(terminalFamily) { Text(terminalFamily).tag(terminalFamily) }
            }
            LabeledContent("Size") {
                HStack(spacing: 8) {
                    if terminalSize > 0 {
                        Button("Use Ghostty's") { terminalSize = 0 }
                            .buttonStyle(.link)
                    } else {
                        Text("Ghostty's").foregroundStyle(.secondary)
                    }
                    Stepper(Self.points(terminalSizeShown.wrappedValue), value: terminalSizeShown, in: Fonts.terminalSizeRange, step: 1)
                        .monospacedDigit()
                }
            }
            Text(verbatim: "~/bosun ❯ claude --resume  {}[]()0O1lI")
                .font(Self.preview(family: terminalFamily.isEmpty ? ghosttyFamily : terminalFamily, size: terminalSizeShown.wrappedValue))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        } header: {
            Text("Terminal")
        } footer: {
            Caption("Your Ghostty config file is never changed: these are applied on top of it in Bosun only.")
        }

        Section {
            Picker("Font", selection: $interfaceFamily) {
                Text("System").tag("")
                Divider()
                ForEach(all, id: \.self) { Text($0).tag($0) }
                if !interfaceFamily.isEmpty, !all.contains(interfaceFamily) { Text(interfaceFamily).tag(interfaceFamily) }
            }
            LabeledContent("Size") {
                HStack(spacing: 8) {
                    if interfaceSize != Fonts.baseInterfaceSize {
                        Button("Use Default") { interfaceSize = Fonts.baseInterfaceSize }
                            .buttonStyle(.link)
                    } else {
                        Text("default").foregroundStyle(.secondary)
                    }
                    Stepper(Self.points(interfaceSize), value: $interfaceSize, in: Fonts.interfaceSizeRange, step: 1)
                        .monospacedDigit()
                }
            }
            Text(verbatim: "api-server   running · 4m")
                .font(Self.preview(family: interfaceFamily.isEmpty ? nil : interfaceFamily, size: interfaceSize, system: true))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        } header: {
            Text("Interface")
        } footer: {
            Caption("Used in the sidebar, pane headers, the title bar and the session palette. Rows and headers grow with it.")
        }
        .onAppear {
            if fixedPitch.isEmpty { fixedPitch = Fonts.fixedPitchFamilies }
            if all.isEmpty { all = Fonts.families }
        }
    }

    /// The terminal size as set, or the Ghostty config's while it isn't; stepping sets it.
    private var terminalSizeShown: Binding<Double> {
        Binding(get: { terminalSize > 0 ? terminalSize : ghosttySize ?? 13 }, set: { terminalSize = $0 })
    }

    private static func points(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v)) pt" : String(format: "%.1f pt", v)
    }

    private static func preview(family: String?, size: Double, system: Bool = false) -> Font {
        if let family, NSFont(name: family, size: size) != nil || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
            return .custom(family, fixedSize: size)
        }
        return system ? .system(size: size) : .system(size: size, design: .monospaced)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}
