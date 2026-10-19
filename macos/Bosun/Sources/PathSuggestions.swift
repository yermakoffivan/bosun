import AppKit
import BosunCore
import UniformTypeIdentifiers

/// The list under the new-session sheet's Path field while typing: the folders the typed path could go on to, as
/// Finder's Go to Folder shows them. The field keeps the keyboard (the form passes it Up, Down, Return and Right);
/// a click chooses a folder.
@MainActor
final class PathSuggestionList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 24
    static let maxRows = 8
    static let inset: CGFloat = 5

    private(set) var entries: [PathCompletion.Entry] = []
    var onChoose: ((PathCompletion.Entry) -> Void)?
    private let box = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private static let folderIcon: NSImage = {
        let i = NSWorkspace.shared.icon(for: .folder)
        i.size = NSSize(width: 16, height: 16)
        return i
    }()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        // Solid, so the rows it covers don't show through.
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        box.cornerRadius = 8
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.fillColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.19, alpha: 1) : .white
        }
        addSubview(box)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        // The Path field keeps the keyboard; the list only shows and takes clicks.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: Self.inset, left: 0, bottom: Self.inset, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        box.contentView = scroll
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The highlighted folder, which Return or Right chooses; nil until Down is pressed.
    var highlighted: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }

    func show(_ entries: [PathCompletion.Entry]) {
        self.entries = entries
        table.reloadData()
        table.deselectAll(nil)
        isHidden = entries.isEmpty
        table.scrollRowToVisible(0)
    }

    func hide() {
        isHidden = true
        table.deselectAll(nil)
    }

    /// Down (+1) and Up (-1): Up from the first row leaves the list with nothing highlighted.
    func move(_ by: Int) {
        guard !entries.isEmpty else { return }
        let next: Int? = switch highlighted {
        case nil: by > 0 ? 0 : nil
        case let i?: i + by < 0 ? nil : min(i + by, entries.count - 1)
        }
        if let next {
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
        } else {
            table.deselectAll(nil)
        }
    }

    /// The height for `rows` rows of folders.
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * rowHeight + 2 * inset }

    override func layout() {
        super.layout()
        box.frame = bounds
        table.tableColumns.first?.width = scroll.contentSize.width
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
    }

    @objc private func clicked() {
        let r = table.clickedRow
        if r >= 0, r < entries.count { onChoose?(entries[r]) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { HighlightRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("folderCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let icon = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            for v in [icon, text] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(v)
            }
            c.imageView = icon
            c.textField = text
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                text.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -10),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.imageView?.image = Self.folderIcon
        cell.textField?.stringValue = entries[row].name
        return cell
    }
}

/// A row drawn highlighted in the accent colour although the list never has the keyboard.
private final class HighlightRow: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

// MARK: Controls that Tab reaches

/// The sheet's checkboxes and radio buttons: Tab stops at them as it does in the TUI's form, whether or not
/// keyboard navigation is on in System Settings, and Space toggles them. Left and Right go to `onArrow`.
final class FormButton: NSButton {
    var onArrow: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    // The ring shows whether or not keyboard navigation is on.
    override func becomeFirstResponder() -> Bool {
        cell?.showsFirstResponder = true
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if tabbed(event, from: self) { return }
        if let onArrow, let d = arrowDirection(event) { onArrow(d); return }
        if event.charactersIgnoringModifiers == " " { performClick(nil); return }
        super.keyDown(with: event)
    }
}

/// The agent picker: Tab stops at it, and Left and Right choose the agent before or after, wrapping, as in the TUI.
final class FormSegments: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func keyDown(with event: NSEvent) {
        if tabbed(event, from: self) { return }
        guard let d = arrowDirection(event), segmentCount > 0 else { return super.keyDown(with: event) }
        selectedSegment = ((selectedSegment + d) % segmentCount + segmentCount) % segmentCount
        sendAction(action, to: target)
    }

    // One ring round the whole control: the focus is on the picker, not a segment.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill() }
}

/// Tab and Shift+Tab from a button or picker: AppKit only moves on from those itself while keyboard navigation is on.
@MainActor
private func tabbed(_ e: NSEvent, from v: NSView) -> Bool {
    guard e.keyCode == 48, e.modifierFlags.intersection([.command, .option, .control]).isEmpty, let w = v.window else { return false }
    if e.modifierFlags.contains(.shift) { w.selectKeyView(preceding: v) } else { w.selectKeyView(following: v) }
    return true
}

/// -1 for Left, +1 for Right, nil for any other key (or with a modifier other than the arrow keys' own).
private func arrowDirection(_ e: NSEvent) -> Int? {
    guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
    switch e.keyCode {
    case 123: return -1
    case 124: return 1
    default: return nil
    }
}
