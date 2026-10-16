import AppKit
// usage: make <src.png> <out.png> <canvas> <body>
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!
var rect = CGRect(origin: .zero, size: src.size)
let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
// Crop to the artwork's opaque bounds.
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 16 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
let crop = cg.cropping(to: CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1))!
print("art bounds", minX, minY, maxX, maxY)
let canvas = Int(a[3])!, body = Double(a[4])!
let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let off = (Double(canvas) - body) / 2
// A soft drop shadow like Apple's template icons.
out.setShadow(offset: CGSize(width: 0, height: -body * 0.012), blur: body * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
let aspect = Double(crop.height) / Double(crop.width)
let bh = body * aspect
out.draw(crop, in: CGRect(x: off, y: (Double(canvas) - bh) / 2, width: body, height: bh))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
