// Renders Type's app icon (a frosted glass tile with a serif "T" and caret).
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt tile centered in 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
let colors = [NSColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 1).cgColor,
              NSColor(srgbRed: 0.86, green: 0.89, blue: 0.97, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
// Glass sheen
let sheen = [NSColor.white.withAlphaComponent(0.65).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
let sg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1])!
ctx.drawRadialGradient(sg, startCenter: CGPoint(x: 330, y: 820), startRadius: 0, endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])
ctx.restoreGState()

// Rim
ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(6); ctx.strokePath()

// Letter
let serif = NSFont.systemFont(ofSize: 560, weight: .semibold).fontDescriptor.withDesign(.serif)!
let font = NSFont(descriptor: serif, size: 560)!
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.13, green: 0.14, blue: 0.2, alpha: 1), .paragraphStyle: para]
let str = NSAttributedString(string: "T", attributes: attrs)
let b = str.boundingRect(with: NSSize(width: size, height: size))
str.draw(in: CGRect(x: 60, y: (size - b.height) / 2 - 10, width: size - 160, height: b.height))

// Caret
let caret = CGRect(x: 690, y: 330, width: 26, height: 360)
ctx.addPath(CGPath(roundedRect: caret, cornerWidth: 13, cornerHeight: 13, transform: nil))
ctx.setFillColor(NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1).cgColor); ctx.fillPath()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out).appendingPathComponent("icon_1024.png"))
