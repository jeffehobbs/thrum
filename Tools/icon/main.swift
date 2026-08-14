import AppKit
import CoreGraphics

// Draws Thrum's icon: concentric rings radiating from a warm core, each one
// slightly off-centre from the last, so the whole thing reads as a standing
// wave that never quite closes — which is the sound.
//
//   swiftc -O -o /tmp/thrumicon Tools/icon/main.swift
//   /tmp/thrumicon out.png          macOS: inset tile, rounded corners, alpha
//   /tmp/thrumicon out.png --ios    iOS:   full-bleed square, fully opaque
//
// The two platforms want opposite things and getting it wrong is a rejection
// rather than a taste question. macOS icons carry their own rounded corners and
// a transparent margin, so the tile floats. iOS masks the corners itself and
// **refuses any alpha channel at all** (ITMS-90717), so the artwork has to run
// edge to edge and be flattened. Re-rendering is cleaner than compositing the
// Mac icon onto a background: no resampling, no halo where the old corners were.

let iOS = CommandLine.arguments.contains("--ios")
let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/thrum-icon.png"

let cs = CGColorSpaceCreateDeviceRGB()
// `noneSkipLast` on the iOS path: no alpha channel in the output at all, which
// is the requirement — not merely "alpha set to 1 everywhere".
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: (iOS ? CGImageAlphaInfo.noneSkipLast
                                           : CGImageAlphaInfo.premultipliedLast).rawValue) else {
    fatalError("no context")
}

let s = CGFloat(size)
let inset = iOS ? 0 : s * 0.055
let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
// Full-bleed and square on iOS; the system rounds it.
let radius = iOS ? 0 : rect.width * 0.225

// Rounded-rect background, deep plum with a lift toward the top.
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.105, green: 0.075, blue: 0.115, alpha: 1),
    CGColor(red: 0.030, green: 0.022, blue: 0.042, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

let center = CGPoint(x: s * 0.5, y: s * 0.5)

// The rings. Radius steps are irrational-ish and each centre drifts a little,
// the same trick the engine uses to keep the sound from locking up.
let ringCount = 11
for i in 0..<ringCount {
    let t = CGFloat(i) / CGFloat(ringCount - 1)
    // Stays inside the tile: centre-to-edge is 0.445s, the widest ring is 0.40s.
    let r = s * (0.078 + 0.322 * pow(t, 1.05))
    let wobble = s * 0.010 * sin(CGFloat(i) * 1.61803)
    let c = CGPoint(x: center.x + wobble, y: center.y - wobble * 0.6)
    let alpha = 0.95 - 0.66 * t
    // Amber core cooling to rose at the edge.
    let color = CGColor(red: 0.99 - 0.16 * t, green: 0.72 - 0.30 * t, blue: 0.34 + 0.18 * t, alpha: alpha)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(s * (0.019 - 0.011 * t))
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

// Warm core glow.
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1.0, green: 0.88, blue: 0.66, alpha: 1.0),
    CGColor(red: 0.99, green: 0.70, blue: 0.32, alpha: 0.55),
    CGColor(red: 0.99, green: 0.60, blue: 0.28, alpha: 0.0),
] as CFArray, locations: [0, 0.32, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                       endCenter: center, endRadius: s * 0.135, options: [])

// A quiet nod to the grid: eight ticks around the outer ring.
ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.30))
ctx.setLineWidth(s * 0.007)
for i in 0..<8 {
    let a = CGFloat(i) / 8.0 * 2 * .pi - .pi / 2
    let r0 = s * 0.418, r1 = s * 0.443
    ctx.move(to: CGPoint(x: center.x + cos(a) * r0, y: center.y + sin(a) * r0))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * r1, y: center.y + sin(a) * r1))
}
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
