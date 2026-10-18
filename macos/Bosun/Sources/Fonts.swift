import AppKit

/// The interface font (the sidebar, pane headers, title band, placeholders and palette) and the terminal font,
/// from Settings → Fonts. Interface sizes are written for 13 pt and scale with the chosen size.
@MainActor
enum Fonts {
    static let baseInterfaceSize: Double = 13
    static let interfaceSizeRange: ClosedRange<Double> = 11...16
    static let terminalSizeRange: ClosedRange<Double> = 8...32

    static var scale: CGFloat { CGFloat(AppSettings.shared.interfaceFontSize / baseInterfaceSize) }

    /// The interface font at `size` (written for 13 pt, scaled unless `scaled` is false).
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular, scaled: Bool = true) -> NSFont {
        let s = scaled ? (size * scale * 2).rounded() / 2 : size
        if let family = AppSettings.shared.interfaceFontFamily, let f = font(family: family, size: s, weight: weight) { return f }
        return .systemFont(ofSize: s, weight: weight)
    }

    /// The interface font with figures of equal width (counts).
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let s = (size * scale * 2).rounded() / 2
        guard let family = AppSettings.shared.interfaceFontFamily, let f = font(family: family, size: s, weight: weight) else {
            return .monospacedDigitSystemFont(ofSize: s, weight: weight)
        }
        let d = f.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                       NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: s) ?? f
    }

    /// A height written for 13 pt, scaled with the interface size.
    static func height(_ h: CGFloat) -> CGFloat { (h * scale).rounded() }

    /// Fonts already matched, by family, size and weight (rows ask on every status change).
    private static var cache: [String: NSFont?] = [:]

    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let key = "\(family)|\(size)|\(weight.rawValue)"
        if let hit = cache[key] { return hit }
        let d = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        let f = NSFont(descriptor: d, size: size).flatMap { $0.familyName == family ? $0 : nil }
        cache[key] = .some(f)
        return f
    }

    /// Installed font families, for the interface font.
    static var families: [String] { NSFontManager.shared.availableFontFamilies }

    /// Installed families with a fixed-width face, for the terminal font.
    static var fixedPitchFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The Ghostty config lines for the terminal font: none for "from Ghostty config".
    static func terminalConfigLines(family: String?, size: Double) -> [String] {
        var lines: [String] = []
        if let family {
            // An empty value clears the families the Ghostty config listed, so this one is the first choice.
            lines += [#"font-family = """#, "font-family = \"\(family.replacingOccurrences(of: "\"", with: ""))\""]
        }
        if size > 0 { lines.append("font-size = \(size)") }
        return lines
    }
}
