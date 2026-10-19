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
        /// A section's starting values for new sessions: no name or worktree, and Save stores them.
        case sectionDefaults(section: String)
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
    /// The section a new session goes into (or whose defaults these are), for the title.
    var sectionName: String?
    /// Also store this sheet's folder, agent, options and arguments as the section's defaults.
    var saveAsDefaults = false

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
    var isSectionDefaults: Bool { if case .sectionDefaults = mode { return true }; return false }
    /// A new row going into a section: the sheet offers to save its values as the section's defaults.
    var offersSaveAsDefaults: Bool { mode == .create && sectionName != nil }

    var title: String {
        switch mode {
        case .create: sectionName.map { "New Session in \($0)" } ?? "New Session"
        case .modify: "Modify Session"
        case .addTab: "New Tab"
        case .sectionDefaults: "Defaults for \(sectionName ?? "Section")"
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

    /// Start from a section's defaults: each field it sets replaces the usual one.
    func apply(_ d: SectionDefaults) {
        if !d.path.isEmpty { path = d.path }
        if let a = d.agent, agentNames.contains(a) { agent = a }
        args = d.args
        options = d.options
    }

    /// This sheet's values as a section's defaults.
    var sectionDefaults: SectionDefaults {
        SectionDefaults(path: path.trimmingCharacters(in: .whitespaces), agent: agent, args: args.trimmingCharacters(in: .whitespaces),
                        options: options)
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
        if isSectionDefaults {
            // Every field is optional here; Save hands the values back as a spec.
            error = nil
            let d = sectionDefaults
            return Spec(name: "", path: d.path, agent: agent, args: d.args, options: options)
        }
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

/// The new-session / modify / new-tab form, laid out with AppKit at a fixed width so nothing in it
/// can push it wider than the sheet: labels in a right-aligned column, controls filling the rest,
/// long values scrolling inside their fields. The sheet is sized from it (see `fittingHeight`).
@MainActor
final class NewSessionFormView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 600
    static let margin: CGFloat = 24

    let model: NewSessionModel
    var onSubmit: ((Spec) -> Void)?
    var onCancel: (() -> Void)?
    /// Called when rows appear or disappear, so the sheet can follow the new height.
    var onHeightChange: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let recentButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let nameField = NSTextField()
    let pathField = NSTextField()
    private let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let worktreeBox = FormButton(checkboxWithTitle: "Create in git worktree", target: nil, action: nil)
    private let branchField = NSTextField()
    private let worktreePreview = NSTextField(labelWithString: "")
    private let agentControl = FormSegments()
    private let argsLabel = NSTextField(labelWithString: "Arguments")
    private let argsField = NSTextField()
    private var modeRadios: [SessionMode: FormButton] = [:]
    private var checkboxes: [(agent: String, button: NSButton, key: WritableKeyPath<SpecOptions, Bool>)] = []
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let submitButton = NSButton(title: "Create", target: nil, action: nil)
    private let saveDefaultsBox = FormButton(checkboxWithTitle: "Save as this section's defaults (folder, agent and arguments)", target: nil, action: nil)
    private let grid = NSGridView()
    let suggestions = PathSuggestionList()
    private var rows: [String: NSGridRow] = [:]
    private var lastHidden: [String: Bool] = [:]

    override var isFlipped: Bool { true }

    init(model: NewSessionModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: NewSessionFormView.width, height: 300))
        build()
        refresh()
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }

    private func field(_ f: NSTextField, placeholder: String) {
        f.placeholderString = placeholder
        f.delegate = self
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.usesSingleLineMode = true
        // Long text scrolls inside the field; it never asks for more width.
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func checkbox(_ title: String, agent: String, _ key: WritableKeyPath<SpecOptions, Bool>) -> NSButton {
        let b = FormButton(checkboxWithTitle: title, target: self, action: #selector(optionToggled(_:)))
        b.lineBreakMode = .byTruncatingTail
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkboxes.append((agent, b, key))
        return b
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.stringValue = model.title
        addSubview(titleLabel)

        recentButton.bezelStyle = .push
        recentButton.isBordered = false
        recentButton.addItem(withTitle: "From Recent")
        for (i, r) in model.recents.prefix(20).enumerated() {
            let item = NSMenuItem(title: "\(r.name)  —  \(r.agent) · \((r.path as NSString).abbreviatingWithTildeInPath)", action: #selector(recentChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            recentButton.menu?.addItem(item)
        }
        recentButton.isHidden = model.recents.isEmpty
        recentButton.sizeToFit()
        addSubview(recentButton)

        field(nameField, placeholder: "api")
        field(pathField, placeholder: "~/work/api")
        field(branchField, placeholder: "branch")
        field(argsField, placeholder: "")
        chooseButton.bezelStyle = .push
        chooseButton.target = self
        chooseButton.action = #selector(choosePath)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        chooseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pathRow = NSStackView(views: [pathField, chooseButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        worktreeBox.target = self
        worktreeBox.action = #selector(worktreeToggled)
        worktreePreview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        worktreePreview.textColor = .secondaryLabelColor
        worktreePreview.lineBreakMode = .byTruncatingMiddle
        worktreePreview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        agentControl.segmentCount = agentNames.count
        agentControl.trackingMode = .selectOne
        for (i, a) in agentNames.enumerated() { agentControl.setLabel(agentLabel(a), forSegment: i) }
        agentControl.target = self
        agentControl.action = #selector(agentChanged)
        agentControl.segmentDistribution = .fillEqually

        var radios: [NSView] = []
        for m in SessionMode.allCases {
            let b = FormButton(radioButtonWithTitle: m.label, target: self, action: #selector(modeChanged(_:)))
            b.onArrow = { [weak self] d in self?.stepMode(d) }
            modeRadios[m] = b
            radios.append(b)
        }
        let modeRow = NSStackView(views: radios)
        modeRow.orientation = .horizontal
        modeRow.spacing = 14

        let claudeSkip = checkbox("Skip permissions (--dangerously-skip-permissions)", agent: "claude", \.claude.skipPermissions)
        let claudeRC = checkbox("Remote Control (--remote-control)", agent: "claude", \.claude.remoteControl)
        let codexYolo = checkbox("YOLO mode (--yolo, bypass approvals and sandbox)", agent: "codex", \.codex.yolo)
        let kimiYolo = checkbox("YOLO mode (--yolo, auto-approve all actions)", agent: "kimi", \.kimi.yolo)
        let ocAuto = checkbox("Auto mode (--auto, auto-approve permissions)", agent: "opencode", \.opencode.auto)
        let qwenYolo = checkbox("YOLO mode (--yolo, auto-approve all actions)", agent: "qwen", \.qwen.yolo)

        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        func add(_ key: String, _ l: NSView?, _ v: NSView) {
            let row = grid.addRow(with: [l ?? NSGridCell.emptyContentView, v])
            rows[key] = row
        }
        add("name", label("Name"), nameField)
        add("path", label("Path"), pathRow)
        add("worktree", nil, worktreeBox)
        add("branch", label("Branch"), branchField)
        add("preview", label("Worktree"), worktreePreview)
        add("agent", label("Agent"), agentControl)
        add("args", argsLabel, argsField)
        add("mode", label("Session"), modeRow)
        add("claude-skip", nil, claudeSkip)
        add("claude-rc", nil, claudeRC)
        add("codex-yolo", nil, codexYolo)
        add("kimi-yolo", nil, kimiYolo)
        add("opencode-auto", nil, ocAuto)
        add("qwen-yolo", nil, qwenYolo)
        saveDefaultsBox.target = self
        saveDefaultsBox.action = #selector(saveDefaultsToggled)
        add("save-defaults", nil, saveDefaultsBox)
        rows["save-defaults"]?.topPadding = 6
        argsLabel.alignment = .right
        argsLabel.setContentHuggingPriority(.required, for: .horizontal)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        rows["agent"]?.topPadding = 4
        for k in ["path", "mode"] {
            rows[k]?.rowAlignment = .none
            rows[k]?.yPlacement = .center
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.preferredMaxLayoutWidth = NewSessionFormView.width - 2 * NewSessionFormView.margin
        addSubview(errorLabel)

        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        submitButton.bezelStyle = .push
        submitButton.keyEquivalent = "\r"
        submitButton.title = model.isModify || model.isSectionDefaults ? "Save" : "Create"
        submitButton.target = self
        submitButton.action = #selector(submit)
        addSubview(cancelButton)
        addSubview(submitButton)
        // Over the rows below the Path field while it's open.
        suggestions.onChoose = { [weak self] e in self?.setPath(e.path) }
        addSubview(suggestions)

        let m = NewSessionFormView.margin
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: m + 34),
            grid.widthAnchor.constraint(equalToConstant: NewSessionFormView.width - 2 * m),
        ])
        nameField.stringValue = model.name
        pathField.stringValue = model.path
        argsField.stringValue = model.args
        branchField.stringValue = model.branch
    }

    private func agentLabel(_ a: String) -> String {
        switch a {
        case "opencode": "OpenCode"
        case "terminal": "Terminal"
        default: a.prefix(1).uppercased() + a.dropFirst()
        }
    }

    // MARK: Model -> view

    /// Re-render whenever the model changes (from the controls, "From Recent", or a test).
    private func observe() {
        withObservationTracking {
            _ = (model.name, model.path, model.worktree, model.branch, model.agent, model.args, model.options, model.error, model.saveAsDefaults)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh(); self?.observe() } }
        }
    }

    private var sessionMode: SessionMode {
        switch model.agent {
        case "claude": model.options.claude.sessionMode
        case "codex": model.options.codex.sessionMode
        case "kimi": model.options.kimi.sessionMode
        case "opencode": model.options.opencode.sessionMode
        case "qwen": model.options.qwen.sessionMode
        default: .new
        }
    }

    func refresh() {
        func set(_ f: NSTextField, _ v: String) { if f.stringValue != v { f.stringValue = v } }
        set(nameField, model.name)
        set(pathField, model.path)
        set(branchField, model.branch)
        set(argsField, model.args)
        pathField.isEnabled = !model.isAddTab
        chooseButton.isEnabled = !model.isAddTab
        worktreeBox.state = model.worktree ? .on : .off
        let slug = Slug.make(model.name)
        branchField.placeholderString = slug.isEmpty ? "branch" : slug
        worktreePreview.stringValue = model.worktreePreview
        agentControl.selectedSegment = agentNames.firstIndex(of: model.agent) ?? 0
        let terminal = model.agent == "terminal"
        argsLabel.stringValue = terminal ? "Command" : "Arguments"
        argsField.placeholderString = terminal ? "optional command to run" : "optional, e.g. --model opus"
        let mode = sessionMode
        for (m, b) in modeRadios {
            b.state = m == mode ? .on : .off
            // OpenCode's CLI has no session picker, so Resume isn't offered.
            b.isHidden = model.agent == "opencode" && m == .resume
        }
        for c in checkboxes { c.button.state = model.options[keyPath: c.key] ? .on : .off }
        errorLabel.stringValue = model.error ?? ""
        errorLabel.isHidden = model.error == nil

        saveDefaultsBox.state = model.saveAsDefaults ? .on : .off
        let canWorktree = !model.isModify && !model.isAddTab && !model.isSectionDefaults
        var hidden: [String: Bool] = [
            "name": model.isSectionDefaults,
            "worktree": !canWorktree, "branch": !(canWorktree && model.worktree), "preview": !(canWorktree && model.worktree),
            "mode": terminal, "save-defaults": !model.offersSaveAsDefaults,
        ]
        for key in ["claude-skip", "claude-rc", "codex-yolo", "kimi-yolo", "opencode-auto", "qwen-yolo"] {
            hidden[key] = !key.hasPrefix(model.agent + "-")
        }
        for (k, h) in hidden { rows[k]?.isHidden = h }
        updateKeyViewLoop()
        if hidden != lastHidden {
            lastHidden = hidden
            needsLayout = true
            onHeightChange?()
        }
    }

    /// Tab's order, as in the TUI's form: the fields shown, top to bottom, wrapping round; the Session row is its
    /// chosen mode's button, and Left and Right change it.
    private func updateKeyViewLoop() {
        var order: [NSView] = []
        func add(_ key: String, _ v: NSView?) {
            if rows[key]?.isHidden == false, let v { order.append(v) }
        }
        add("name", nameField)
        if !model.isAddTab { add("path", pathField) }
        add("worktree", worktreeBox)
        add("branch", branchField)
        add("agent", agentControl)
        add("args", argsField)
        add("mode", modeRadios[sessionMode])
        for key in ["claude-skip", "claude-rc", "codex-yolo", "kimi-yolo", "opencode-auto", "qwen-yolo"] {
            add(key, rows[key]?.cell(at: 1).contentView)
        }
        add("save-defaults", saveDefaultsBox)
        for (i, v) in order.enumerated() { v.nextKeyView = order[(i + 1) % order.count] }
    }

    /// The field or control with the keyboard, by its row ("mode" rows add the mode), for the focus test.
    var focusedField: String? {
        var r = window?.firstResponder
        if let t = r as? NSTextView, t.isFieldEditor { r = t.delegate as? NSResponder }
        guard let v = r as? NSView else { return nil }
        if let m = modeRadios.first(where: { $0.value === v })?.key { return "mode:\(m.rawValue)" }
        let named: [(String, NSView)] = [("name", nameField), ("path", pathField), ("worktree", worktreeBox), ("branch", branchField),
                                         ("agent", agentControl), ("args", argsField), ("save-defaults", saveDefaultsBox)]
        if let n = named.first(where: { $0.1 === v })?.0 { return n }
        return rows.first { $0.value.isHidden == false && $0.value.cell(at: 1).contentView === v }?.key
    }

    // MARK: Layout

    /// The height the form needs at its fixed width.
    var fittingHeight: CGFloat {
        grid.layoutSubtreeIfNeeded()
        let m = NewSessionFormView.margin
        var h = m + 34 + grid.fittingSize.height
        if !errorLabel.isHidden { h += 10 + errorLabel.intrinsicContentSize.height }
        return ceil(h + 20 + 28 + m)
    }

    override func layout() {
        super.layout()
        let m = NewSessionFormView.margin
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: m, y: m - 2)
        recentButton.sizeToFit()
        let rw = min(recentButton.frame.width, bounds.width / 2 - m)
        recentButton.frame = NSRect(x: bounds.width - m - rw + 6, y: m - 4, width: rw, height: recentButton.frame.height)
        titleLabel.frame.size.width = min(titleLabel.frame.width, recentButton.frame.minX - m - 8)
        grid.layoutSubtreeIfNeeded()
        var y = grid.frame.maxY
        if !errorLabel.isHidden {
            let s = errorLabel.intrinsicContentSize
            errorLabel.frame = NSRect(x: m, y: y + 10, width: bounds.width - 2 * m, height: s.height)
            y = errorLabel.frame.maxY
        }
        submitButton.sizeToFit()
        cancelButton.sizeToFit()
        let bw = max(submitButton.frame.width, 80)
        let by = bounds.height - m - 28
        submitButton.frame = NSRect(x: bounds.width - m - bw, y: by, width: bw, height: 28)
        let cw = max(cancelButton.frame.width, 80)
        cancelButton.frame = NSRect(x: submitButton.frame.minX - 12 - cw, y: by, width: cw, height: 28)
        if !suggestions.isHidden {
            // Under the Path field, as wide as it and its Choose… button, with as many rows as fit above the sheet's foot.
            let f = pathField.convert(pathField.bounds, to: self)
            let right = chooseButton.convert(chooseButton.bounds, to: self).maxX
            let top = f.maxY + 4
            let fit = Int((bounds.height - top - 8 - 2 * PathSuggestionList.inset) / PathSuggestionList.rowHeight)
            let n = max(1, min(suggestions.entries.count, PathSuggestionList.maxRows, fit))
            suggestions.frame = NSRect(x: f.minX, y: top, width: right - f.minX, height: PathSuggestionList.height(rows: n))
        }
    }

    // MARK: Path suggestions

    /// List the folders the typed path could go on to; with none, the list closes.
    private func updateSuggestions() {
        suggestions.show(PathCompletion.folders(matching: pathField.stringValue, home: NSHomeDirectory()))
        needsLayout = true
    }

    /// Put `p` in the Path field with the cursor at its end, and list the folders in it.
    private func setPath(_ p: String) {
        pathField.stringValue = p
        model.path = p
        pathField.currentEditor()?.selectedRange = NSRange(location: (p as NSString).length, length: 0)
        updateSuggestions()
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        switch f {
        case nameField: model.name = f.stringValue
        case pathField:
            model.path = f.stringValue
            updateSuggestions()
        case branchField: model.branch = f.stringValue
        case argsField: model.args = f.stringValue
        default: break
        }
    }

    /// Esc in a field comes up the responder chain as cancelOperation; Return as insertNewline.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === pathField { suggestions.hide() }
    }

    /// In the Path field, as in the TUI's: Down opens the list of folders and walks it, Up walks back, Return or Right
    /// takes the highlighted folder (Right at the end of the text, with none highlighted, completes as far as the
    /// matches agree) and Esc closes the list. Tab always goes on to the next field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let listOpen = control === pathField && !suggestions.isHidden
        switch sel {
        case #selector(NSResponder.moveDown(_:)) where control === pathField:
            if suggestions.isHidden { updateSuggestions() }
            suggestions.move(1)
            return true
        case #selector(NSResponder.moveUp(_:)) where listOpen:
            suggestions.move(-1)
            return true
        case #selector(NSResponder.moveRight(_:)) where control === pathField:
            let r = textView.selectedRange()
            guard r.length == 0, r.location == (textView.string as NSString).length else { return false }
            if listOpen, let i = suggestions.highlighted {
                setPath(suggestions.entries[i].path)
                return true
            }
            let typed = pathField.stringValue
            guard let c = PathCompletion.completion(of: typed, entries: PathCompletion.folders(matching: typed, home: NSHomeDirectory(), limit: .max))
            else { return false }
            setPath(c)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if listOpen, let i = suggestions.highlighted {
                setPath(suggestions.entries[i].path)
                return true
            }
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if listOpen {
                suggestions.hide()
                return true
            }
            onCancel?()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            suggestions.hide()
            return false
        default: return false
        }
    }

    @objc private func worktreeToggled() { model.worktree = worktreeBox.state == .on }

    @objc private func saveDefaultsToggled() { model.saveAsDefaults = saveDefaultsBox.state == .on }

    @objc private func agentChanged() {
        let i = agentControl.selectedSegment
        if i >= 0, i < agentNames.count { model.agent = agentNames[i] }
    }

    @objc private func modeChanged(_ sender: NSButton) {
        guard let mode = modeRadios.first(where: { $0.value === sender })?.key else { return }
        setMode(mode)
    }

    /// Left and Right on the Session row: the mode before or after, wrapping, keeping the keyboard on the row.
    private func stepMode(_ d: Int) {
        let modes = SessionMode.allCases.filter { modeRadios[$0]?.isHidden == false }
        guard let i = modes.firstIndex(of: sessionMode) else { return }
        let m = modes[((i + d) % modes.count + modes.count) % modes.count]
        setMode(m)
        refresh()
        window?.makeFirstResponder(modeRadios[m])
    }

    private func setMode(_ mode: SessionMode) {
        switch model.agent {
        case "claude": model.options.claude.sessionMode = mode
        case "codex": model.options.codex.sessionMode = mode
        case "kimi": model.options.kimi.sessionMode = mode
        case "opencode": model.options.opencode.sessionMode = mode
        case "qwen": model.options.qwen.sessionMode = mode
        default: break
        }
    }

    @objc private func optionToggled(_ sender: NSButton) {
        guard let c = checkboxes.first(where: { $0.button === sender }) else { return }
        model.options[keyPath: c.key] = sender.state == .on
    }

    @objc private func recentChosen(_ sender: NSMenuItem) {
        let recents = Array(model.recents.prefix(20))
        guard sender.tag < recents.count else { return }
        model.fill(from: recents[sender.tag])
    }

    @objc private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (model.path as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc private func cancel() { onCancel?() }

    @objc private func submit() {
        // A field still being edited has its latest text in the model already (controlTextDidChange).
        if let spec = model.buildSpec() { onSubmit?(spec) }
    }
}
