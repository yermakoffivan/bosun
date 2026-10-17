import AppKit
import BosunCore
import SwiftUI

/// The Settings window's editor for file links. The value is the daemon's `editor` (config.toml), which the
/// TUI's `e` key runs too, so one setting covers both; picking one sends `apply_setting`.
@MainActor
final class EditorModel: ObservableObject {
    /// The setting: a command, or nil for the default app of each file type.
    @Published private(set) var editor: String?
    /// The known editors found on the login shell's PATH.
    @Published private(set) var installed: [(name: String, command: String)] = []
    /// The daemon knows the setting (an older `bosun serve` doesn't list it).
    @Published private(set) var supported = false
    /// Sends the change: a command, or nil to unset it.
    var onSet: ((String?) -> Void)?
    private var looked = false

    func update(from st: BosunState) {
        let v = st.config.value("editor")?.stringValue
        if editor != v { editor = v }
        let s = st.config.settings.contains { $0.key == "editor" }
        if supported != s { supported = s }
    }

    /// Look for the known editors once, off the main thread (the login shell's PATH can take a moment).
    func findInstalled() {
        guard !looked else { return }
        looked = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let path = ShellEnv.path()
            let found = EditorCommand.known.filter { EditorCommand.resolve($0.command, searchPath: path) != nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.installed = found } }
        }
    }

    /// Shown straight away, confirmed by the daemon's config delta.
    func set(_ command: String?) {
        let c = command?.trimmingCharacters(in: .whitespaces)
        editor = c?.isEmpty == false ? c : nil
        onSet?(editor)
    }
}

/// The "Files" group of the Settings window.
struct EditorSection: View {
    @ObservedObject var model: EditorModel
    @State private var other = false
    @State private var draft = ""
    private static let otherTag = "\u{0}other"

    var body: some View {
        Section("Files") {
            Picker("Open file links in", selection: selection) {
                Text("Default app for the file type").tag("")
                if !model.installed.isEmpty { Divider() }
                ForEach(model.installed, id: \.command) { Text($0.name).tag($0.command) }
                if let e = model.editor, !model.installed.contains(where: { $0.command == e }) { Text(e).tag(e) }
                Divider()
                Text("Other command…").tag(Self.otherTag)
            }
            .disabled(!model.supported)
            if other {
                HStack {
                    TextField("Command", text: $draft, prompt: Text("zed, code -n, …"))
                        .onSubmit(commit)
                    Button("Set", action: commit)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text(model.supported
                 ? "Cmd+click on a path in a terminal opens it here, at its line when the path ends in :line. Folders still open in Finder. This is `editor` in config.toml, which the TUI's e key uses too."
                 : "Needs a newer bosun: update it to choose an editor.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.findInstalled() }
    }

    private var selection: Binding<String> {
        Binding(get: { other ? Self.otherTag : (model.editor ?? "") },
                set: { v in
                    if v == Self.otherTag {
                        draft = model.editor ?? ""
                        other = true
                    } else {
                        other = false
                        model.set(v)
                    }
                })
    }

    private func commit() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.set(draft)
        other = false
    }
}
