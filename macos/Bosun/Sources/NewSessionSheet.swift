import AppKit
import BosunCore
import SwiftUI

/// The new-session form: the same fields and defaults as the TUI's modal (src/ui/modal/new_session.rs).
@MainActor
@Observable
final class NewSessionModel {
    enum Mode: Equatable {
        case create
        case modify(session: String)
        case addTab(containerID: String)
    }

    let mode: Mode
    let recents: [Recent]
    let worktreeLocation: String
    var name = ""
    var path = ""
    var worktree = false
    var branch = ""
    var agent = "claude" { didSet { if agent != oldValue { applyRemembered() } } }
    var args = ""
    var options = SpecOptions()
    var error: String?

    init(mode: Mode, recents: [Recent], defaultAgent: String, worktreeLocation: String, path: String? = nil, name: String = "") {
        self.mode = mode
        self.recents = recents
        self.worktreeLocation = worktreeLocation
        self.name = name
        // Default path: the most recently used session's path, as the TUI does.
        self.path = path ?? recents.first?.path ?? "~"
        self.agent = agentNames.contains(defaultAgent) ? defaultAgent : "claude"
        applyRemembered()
    }

    convenience init(modify session: String, spec: Spec, recents: [Recent]) {
        self.init(mode: .modify(session: session), recents: recents, defaultAgent: spec.agent, worktreeLocation: "subdir", path: spec.path, name: spec.name)
        args = spec.args
        options = spec.options
    }

    var isModify: Bool { if case .modify = mode { return true }; return false }
    var isAddTab: Bool { if case .addTab = mode { return true }; return false }

    var title: String {
        switch mode {
        case .create: "New Session"
        case .modify: "Modify Session"
        case .addTab: "New Tab"
        }
    }

    var effectiveBranch: String { branch.isEmpty ? Slug.make(name) : branch }

    var worktreePreview: String {
        if worktreeLocation == "sibling" {
            let repo = path.split(separator: "/").last.map(String.init) ?? "repo"
            return "\(repo)-\(effectiveBranch)"
        }
        return ".worktrees/\(effectiveBranch)"
    }

    /// Options remembered from the freshest recent of the chosen agent.
    func applyRemembered() {
        guard let r = recents.first(where: { $0.agent == agent }) else { return }
        switch agent {
        case "claude": options.claude = r.options.claude
        case "codex": options.codex = r.options.codex
        case "kimi": options.kimi = r.options.kimi
        case "opencode": options.opencode = r.options.opencode
        case "qwen": options.qwen = r.options.qwen
        default: break
        }
    }

    func fill(from r: Recent) {
        name = r.name
        if !isAddTab { path = r.path }
        agent = r.agent
        args = r.args
        options = r.options
    }

    /// Same checks as the TUI's `build_spec`.
    func buildSpec() -> Spec? {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("bosun-") { n = String(n.dropFirst(6)) }
        guard !n.isEmpty else { error = "Name is required."; return nil }
        guard n.contains(where: { $0.isLetter || $0.isNumber }) else { error = "Name must contain at least one letter or digit."; return nil }
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { error = "Path is required."; return nil }
        var wt: String?
        if worktree && !isModify && !isAddTab {
            let b = effectiveBranch
            guard b.contains(where: { $0.isLetter || $0.isNumber }) else { error = "Branch must contain at least one letter or digit."; return nil }
            guard !b.contains("/") else { error = "Branch can't contain “/”."; return nil }
            guard !b.contains(where: \.isWhitespace) else { error = "Branch can't contain spaces."; return nil }
            wt = b
        }
        error = nil
        var containerID: String?
        if case .addTab(let c) = mode { containerID = c }
        return Spec(name: n, path: p, agent: agent, args: args.trimmingCharacters(in: .whitespaces), options: options,
                    containerID: containerID, resume: false, worktreeBranch: wt)
    }
}

struct NewSessionForm: View {
    @Bindable var model: NewSessionModel
    var onSubmit: (Spec) -> Void
    var onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !model.recents.isEmpty {
                    Menu("From Recent") {
                        ForEach(model.recents.prefix(20), id: \.id) { r in
                            Button("\(r.name)  —  \(r.agent) · \(abbreviate(r.path))") { model.fill(from: r) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.bottom, 14)

            Form {
                TextField("Name", text: $model.name, prompt: Text("api"))
                    .focused($nameFocused)
                HStack {
                    TextField("Path", text: $model.path, prompt: Text("~/work/api"))
                        .disabled(model.isAddTab)
                    Button("Choose…") { choosePath() }
                        .disabled(model.isAddTab)
                }
                if !model.isModify && !model.isAddTab {
                    Toggle("Create in git worktree", isOn: $model.worktree)
                    if model.worktree {
                        TextField("Branch", text: $model.branch, prompt: Text(Slug.make(model.name).isEmpty ? "branch" : Slug.make(model.name)))
                        LabeledContent("Worktree") {
                            Text(model.worktreePreview).foregroundStyle(.secondary).font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
                Picker("Agent", selection: $model.agent) {
                    ForEach(agentNames, id: \.self) { Text(agentLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(model.agent == "terminal" ? "Command" : "Arguments", text: $model.args,
                          prompt: Text(model.agent == "terminal" ? "optional command to run" : "optional, e.g. --model opus"))
                agentOptions
            }
            .formStyle(.columns)

            if let e = model.error {
                Text(e).foregroundStyle(.red).font(.callout).padding(.top, 10)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isModify ? "Save" : "Create") {
                    if let spec = model.buildSpec() { onSubmit(spec) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 540)
        .onAppear { nameFocused = true }
    }

    @ViewBuilder private var agentOptions: some View {
        switch model.agent {
        case "claude":
            modePicker($model.options.claude.sessionMode, modes: SessionMode.allCases)
            Toggle("Skip permissions (--dangerously-skip-permissions)", isOn: $model.options.claude.skipPermissions)
            Toggle("Remote Control (--remote-control)", isOn: $model.options.claude.remoteControl)
        case "codex":
            modePicker($model.options.codex.sessionMode, modes: SessionMode.allCases)
            Toggle("YOLO mode (--yolo, bypass approvals and sandbox)", isOn: $model.options.codex.yolo)
        case "kimi":
            modePicker($model.options.kimi.sessionMode, modes: SessionMode.allCases)
            Toggle("YOLO mode (--yolo, auto-approve all actions)", isOn: $model.options.kimi.yolo)
        case "opencode":
            // OpenCode's CLI has no session picker, so Resume isn't offered.
            modePicker($model.options.opencode.sessionMode, modes: [.new, .continue])
            Toggle("Auto mode (--auto, auto-approve permissions)", isOn: $model.options.opencode.auto)
        case "qwen":
            modePicker($model.options.qwen.sessionMode, modes: SessionMode.allCases)
            Toggle("YOLO mode (--yolo, auto-approve all actions)", isOn: $model.options.qwen.yolo)
        default:
            EmptyView()
        }
    }

    private func modePicker(_ binding: Binding<SessionMode>, modes: [SessionMode]) -> some View {
        Picker("Session", selection: binding) {
            ForEach(modes, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
    }

    private func agentLabel(_ a: String) -> String {
        switch a {
        case "opencode": "OpenCode"
        case "terminal": "Terminal"
        default: a.prefix(1).uppercased() + a.dropFirst()
        }
    }

    private func abbreviate(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (model.path as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// App preferences (focus follows mouse, terminal colours, pool size).
struct SettingsView: View {
    @AppStorage("focusFollowsMouse") private var focusFollowsMouse = true
    @AppStorage("matchTerminalTheme") private var matchTerminalTheme = false
    @AppStorage("poolSize") private var poolSize = 8

    var body: some View {
        Form {
            Toggle("Focus follows the mouse between tiles", isOn: $focusFollowsMouse)
            Text("With two or more tiles, moving the pointer into a tile makes it active. Off: click to activate.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Match terminal colours to the Bosun theme", isOn: $matchTerminalTheme)
            Text("Off: terminals keep your Ghostty theme. Your Ghostty config file is never changed.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Warm terminals kept attached: \(poolSize)", value: $poolSize, in: 2...16)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
