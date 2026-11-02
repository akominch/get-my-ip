// Renders the GetMyIP app icon: swift scripts/make-icon.swift <output.png> [size]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon.png"
let size = args.count > 2 ? Int(args[2])! : 1024
let s = CGFloat(size) / 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: s, y: s)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Apple macOS icon grid: 824 pt body centred in 1024, ~185 pt corner radius, soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35).cgColor)
rgb(0x111827).setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()
NSGradient(colors: [rgb(0x2B3A67), rgb(0x141B33), rgb(0x0B1022)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: body, angle: -60)
NSGradient(colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
ctx.restoreGState()

let center = NSPoint(x: 470, y: 440)
let r: CGFloat = 220
let globe = NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
ctx.saveGState()
NSBezierPath(ovalIn: globe).addClip()
NSGradient(colors: [rgb(0x60A5FA, 0.20), rgb(0x60A5FA, 0.04)])!.draw(in: globe, angle: -90)
ctx.restoreGState()

let line = rgb(0xFFFFFF, 0.92)
line.setStroke()
func stroke(_ p: NSBezierPath, _ w: CGFloat) { p.lineWidth = w; p.lineCapStyle = .round; p.stroke() }
ctx.saveGState()
NSBezierPath(ovalIn: globe).addClip()
stroke(NSBezierPath(ovalIn: globe.insetBy(dx: r * 0.5, dy: -20)), 13)
for dy in [0, r * 0.5, -r * 0.5] {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: center.x - r - 20, y: center.y + dy))
    p.line(to: NSPoint(x: center.x + r + 20, y: center.y + dy))
    stroke(p, 13)
}
ctx.restoreGState()
stroke(NSBezierPath(ovalIn: globe), 20)

let base = NSPoint(x: center.x + r * 0.7071, y: center.y + r * 0.7071)
let top = NSPoint(x: base.x, y: base.y + 230)
let pole = NSBezierPath(); pole.move(to: base); pole.line(to: top)
rgb(0xFFFFFF).setStroke()
stroke(pole, 20)

let flag = NSBezierPath()
let fw: CGFloat = 160, fh: CGFloat = 106
flag.move(to: NSPoint(x: top.x, y: top.y))
flag.curve(to: NSPoint(x: top.x + fw, y: top.y - 6),
           controlPoint1: NSPoint(x: top.x + fw * 0.35, y: top.y + 30),
           controlPoint2: NSPoint(x: top.x + fw * 0.65, y: top.y - 36))
flag.line(to: NSPoint(x: top.x + fw, y: top.y - fh - 6))
flag.curve(to: NSPoint(x: top.x, y: top.y - fh),
           controlPoint1: NSPoint(x: top.x + fw * 0.65, y: top.y - fh - 36),
           controlPoint2: NSPoint(x: top.x + fw * 0.35, y: top.y - fh + 30))
flag.close()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: rgb(0x000000, 0.35).cgColor)
NSGradient(colors: [rgb(0xFF8A5B), rgb(0xFF3D71)])!.draw(in: flag, angle: -30)
ctx.restoreGState()
let knob = NSBezierPath(ovalIn: NSRect(x: top.x - 16, y: top.y - 4, width: 32, height: 32))
rgb(0xFFFFFF).setFill()
knob.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
