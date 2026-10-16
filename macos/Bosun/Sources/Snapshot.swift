import AppKit
import CoreImage
import IOSurface

/// Renders a window (and an attached sheet) to a PNG from inside the app, terminals included.
/// Used by the test modes, which can run while the screen is locked and `screencapture` can't see the window.
@MainActor
enum WindowSnapshot {
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// The terminal's last frame as a CGImage (libghostty's layer contents is an IOSurface).
    static func image(of terminal: TerminalView) -> CGImage? {
        guard let contents = terminal.layer?.contents else { return nil }
        let obj = contents as AnyObject
        guard CFGetTypeID(obj) == IOSurfaceGetTypeID() else {
            if CFGetTypeID(obj) == CGImage.typeID { return (obj as! CGImage) }
            return nil
        }
        let surface = obj as! IOSurface
        let img = CIImage(ioSurface: surface)
        return ci.createCGImage(img, from: img.extent)
    }

    static func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview else { return nil }
        // Swap each visible terminal's IOSurface for a CGImage while drawing, then put it back
        // in the same turn of the run loop (nothing is committed to the screen in between).
        var swapped: [(CALayer, Any?)] = []
        for v in allTerminals(in: frameView) where !v.isHidden {
            guard let layer = v.layer, let img = image(of: v) else { continue }
            swapped.append((layer, layer.contents))
            layer.contents = img
        }
        defer { for (l, c) in swapped { l.contents = c } }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep
    }

    static func allTerminals(in v: NSView) -> [TerminalView] {
        var out: [TerminalView] = []
        for s in v.subviews {
            if let t = s as? TerminalView { out.append(t) }
            out += allTerminals(in: s)
        }
        return out
    }

    /// Write the window to `url`, with an attached sheet drawn where it sits.
    @discardableResult
    static func write(_ window: NSWindow, to url: URL) -> Bool {
        guard let base = capture(window) else { return false }
        var final = base
        if let sheet = window.attachedSheet, let sheetRep = capture(sheet) {
            let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
            let scale = CGFloat(base.pixelsWide) / window.frame.width
            let img = NSImage(size: size)
            img.lockFocus()
            NSImage(cgImage: base.cgImage!, size: size).draw(in: NSRect(origin: .zero, size: size))
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            let sf = sheet.frame
            let x = (sf.minX - window.frame.minX) * scale
            let y = (sf.minY - window.frame.minY) * scale
            NSImage(cgImage: sheetRep.cgImage!, size: NSSize(width: sf.width * scale, height: sf.height * scale))
                .draw(in: NSRect(x: x, y: y, width: sf.width * scale, height: sf.height * scale))
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let r = NSBitmapImageRep(data: tiff) { final = r }
        }
        guard let png = final.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
