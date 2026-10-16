import Foundation

/// A navigation shortcut from the TUI's `[keybindings]` table ("Shift+Up", "Ctrl+v", "Alt+Left", "F5").
/// Parsing follows `src/keybindings.rs` so a string valid for the TUI means the same thing here.
public struct KeyChord: Equatable, Hashable, Sendable {
    public struct Mods: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Mods(rawValue: 1)
        public static let option = Mods(rawValue: 2)
        public static let shift = Mods(rawValue: 4)
    }

    public enum Key: Equatable, Hashable, Sendable {
        case left, right, up, down
        case function(Int)
        case letter(Character)
    }

    public var key: Key
    public var mods: Mods

    public init(key: Key, mods: Mods) {
        self.key = key
        self.mods = mods
    }

    public enum ParseError: Error, Equatable {
        case unknownModifier(String)
        case unsupportedKey(String)
        case invalid(String)
    }

    /// nil for an empty string or "none" (the binding is off).
    public static func parse(_ value: String) throws -> KeyChord? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty || v.lowercased() == "none" { return nil }
        let parts = v.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var mods: Mods = []
        for p in parts.dropLast() {
            switch p.lowercased() {
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default: throw ParseError.unknownModifier(p)
            }
        }
        let k = (parts.last ?? "").lowercased()
        let key: Key
        switch k {
        case "left": key = .left
        case "right": key = .right
        case "up": key = .up
        case "down": key = .down
        default:
            if k.hasPrefix("f"), let n = Int(k.dropFirst()) {
                guard (1...12).contains(n) else { throw ParseError.invalid("only F1 through F12 are supported") }
                key = .function(n)
            } else if k.count == 1, let c = k.first, c.isASCII, c.isLetter {
                if mods.isDisjoint(with: [.control, .option]) || mods.contains(.shift) {
                    throw ParseError.invalid("letter shortcuts require Ctrl or Alt, without Shift")
                }
                if mods.contains(.control), "hijm".contains(c) {
                    throw ParseError.invalid("Ctrl+H/I/J/M are terminal aliases for Backspace, Tab, or Enter")
                }
                key = .letter(c)
            } else {
                throw ParseError.unsupportedKey(value)
            }
        }
        return KeyChord(key: key, mods: mods)
    }

    /// macOS virtual key codes (kVK_*) for the non-letter keys.
    static let functionKeyCodes: [Int: UInt16] = [
        1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100, 9: 101, 10: 109, 11: 103, 12: 111,
    ]

    /// Whether a key press matches. `keyCode` is the macOS virtual key code, `charactersIgnoringModifiers`
    /// the event's (layout-aware letter), `mods` the pressed control/option/shift; `command` must be off.
    public func matches(keyCode: UInt16, charactersIgnoringModifiers: String?, mods pressed: Mods, command: Bool) -> Bool {
        guard !command, pressed == mods else { return false }
        switch key {
        case .left: return keyCode == 123
        case .right: return keyCode == 124
        case .down: return keyCode == 125
        case .up: return keyCode == 126
        case .function(let n): return KeyChord.functionKeyCodes[n] == keyCode
        case .letter(let c):
            guard let chars = charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return false }
            return chars.first == c
        }
    }

    public var label: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        switch key {
        case .left: s += "←"
        case .right: s += "→"
        case .up: s += "↑"
        case .down: s += "↓"
        case .function(let n): s += "F\(n)"
        case .letter(let c): s += String(c).uppercased()
        }
        return s
    }
}

public enum NavAction: String, CaseIterable, Sendable {
    case previousTab, nextTab, previousSession, nextSession, sendNextKey

    public var defaultChord: String {
        switch self {
        case .previousTab: "Shift+Left"
        case .nextTab: "Shift+Right"
        case .previousSession: "Shift+Up"
        case .nextSession: "Shift+Down"
        case .sendNextKey: "Ctrl+v"
        }
    }
}

/// The resolved navigation bindings: defaults where the daemon sends nothing, off where it sends null.
public struct NavBindings: Equatable, Sendable {
    public private(set) var chords: [NavAction: KeyChord] = [:]
    public private(set) var errors: [String] = []

    public init(_ wire: KeyBindingsWire?) {
        let w = wire ?? KeyBindingsWire()
        for action in NavAction.allCases {
            let value: KeyBindingsWire.Value
            switch action {
            case .previousTab: value = w.previousTab
            case .nextTab: value = w.nextTab
            case .previousSession: value = w.previousSession
            case .nextSession: value = w.nextSession
            case .sendNextKey: value = w.sendNextKey
            }
            let text: String
            switch value {
            case .unset: text = action.defaultChord
            case .disabled: continue
            case .chord(let s): text = s
            }
            do {
                if let c = try KeyChord.parse(text) {
                    if chords.values.contains(c) {
                        errors.append("\(text) is assigned more than once")
                        continue
                    }
                    chords[action] = c
                }
            } catch {
                errors.append("\(action.rawValue): \(text): \(error)")
            }
        }
    }

    public func action(keyCode: UInt16, charactersIgnoringModifiers: String?, mods: KeyChord.Mods, command: Bool) -> NavAction? {
        for (a, c) in chords where c.matches(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers, mods: mods, command: command) {
            return a
        }
        return nil
    }
}
