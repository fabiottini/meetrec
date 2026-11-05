// Draws the MeetRec app icon (1024x1024 PNG).
// Usage: swift assets/make-icon.swift <out.png>
// The glyph is the same as the menu bar one: a speech bubble with a waveform + a "rec" dot.

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// macOS icon grid: 824x824 rounded square centered, radius ~185
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// soft shadow
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = rgb(0, 0, 0, 0.35); sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -12)
sh.set()
rgb(30, 27, 75).setFill(); tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

// background gradient: deep indigo -> teal
NSGradient(colors: [rgb(49, 46, 129), rgb(67, 56, 202), rgb(13, 148, 136)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tilePath, angle: -60)

// subtle top highlight
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [rgb(255, 255, 255, 0.18), rgb(255, 255, 255, 0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// speech bubble
let bubble = NSRect(x: 230, y: 330, width: 564, height: 420)
let bp = NSBezierPath(roundedRect: bubble, xRadius: 120, yRadius: 120)
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 330, y: 360))
tail.line(to: NSPoint(x: 290, y: 235))
tail.curve(to: NSPoint(x: 470, y: 340), controlPoint1: NSPoint(x: 360, y: 260), controlPoint2: NSPoint(x: 420, y: 300))
tail.close()
bp.append(tail)
NSGraphicsContext.saveGraphicsState()
let sh2 = NSShadow()
sh2.shadowColor = rgb(0, 0, 0, 0.25); sh2.shadowBlurRadius = 20; sh2.shadowOffset = NSSize(width: 0, height: -8)
sh2.set()
rgb(255, 255, 255).setFill(); bp.fill()
NSGraphicsContext.restoreGraphicsState()

// waveform bars inside the bubble
let heights: [CGFloat] = [90, 190, 280, 160, 230, 110]
let barW: CGFloat = 40, gap: CGFloat = 34
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = bubble.midX - totalW / 2
let cy = bubble.midY
for (i, h) in heights.enumerated() {
    let r = NSRect(x: x, y: cy - h / 2, width: barW, height: h)
    let t = CGFloat(i) / CGFloat(heights.count - 1)
    rgb(67 - 54 * t, 56 + 92 * t, 202 - 66 * t).setFill()
    NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}

// rec dot, top right
let dot = NSRect(x: 690, y: 660, width: 150, height: 150)
rgb(255, 255, 255).setFill()
NSBezierPath(ovalIn: dot.insetBy(dx: -18, dy: -18)).fill()
NSGradient(colors: [rgb(248, 113, 113), rgb(220, 38, 38)])!.draw(in: NSBezierPath(ovalIn: dot), angle: -90)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
