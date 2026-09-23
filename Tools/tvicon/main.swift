// Thrum's icon for the television, one layer at a time.
//
//   swiftc -O -o /tmp/thrumtvicon Tools/tvicon/main.swift
//   /tmp/thrumtvicon out.png 800 480 background   opaque plum gradient (back layer)
//   /tmp/thrumtvicon out.png 800 480 rings        rings + glow + ticks on transparent (front layer)
//   /tmp/thrumtvicon out.png 3840 1440 flat       both, opaque — the top-shelf image
//
// tvOS icons are a parallax stack of layers rather than one image, and the
// composition is Tools/icon's: concentric rings radiating from a warm core, each
// slightly off-centre from the last. Here the rings are sized to the shorter
// side so the same code draws a 400×240 icon and a 2320×720 shelf. The back
// layer must be opaque, the front layers transparent. Tools/tvicons.py drives
// this and writes the asset catalog.

import Foundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 5, let width = Int(args[2]), let height = Int(args[3]) else {
    print("usage: tvicon out.png WIDTH HEIGHT background|rings|flat"); exit(1)
}
let out = args[1]
let mode = args[4]
let opaque = mode != "rings"

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast
                                              : CGImageAlphaInfo.premultipliedLast).rawValue) else {
    fatalError("no context")
}
let w = CGFloat(width), h = CGFloat(height)
let s = min(w, h)
let center = CGPoint(x: w * 0.5, y: h * 0.5)

if mode == "background" || mode == "flat" {
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.105, green: 0.075, blue: 0.115, alpha: 1),
        CGColor(red: 0.030, green: 0.022, blue: 0.042, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
}

if mode == "rings" || mode == "flat" {
    let ringCount = 11
    for i in 0..<ringCount {
        let t = CGFloat(i) / CGFloat(ringCount - 1)
        let r = s * (0.078 + 0.322 * pow(t, 1.05))
        let wobble = s * 0.010 * sin(CGFloat(i) * 1.61803)
        let c = CGPoint(x: center.x + wobble, y: center.y - wobble * 0.6)
        let alpha = 0.95 - 0.66 * t
        let color = CGColor(red: 0.99 - 0.16 * t, green: 0.72 - 0.30 * t, blue: 0.34 + 0.18 * t, alpha: alpha)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(s * (0.019 - 0.011 * t))
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    let glow = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1.0, green: 0.88, blue: 0.66, alpha: 1.0),
        CGColor(red: 0.99, green: 0.70, blue: 0.32, alpha: 0.55),
        CGColor(red: 0.99, green: 0.60, blue: 0.28, alpha: 0.0),
    ] as CFArray, locations: [0, 0.32, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: s * 0.135, options: [])
    ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.30))
    ctx.setLineWidth(s * 0.007)
    for i in 0..<8 {
        let a = CGFloat(i) / 8.0 * 2 * .pi - .pi / 2
        let r0 = s * 0.418, r1 = s * 0.443
        ctx.move(to: CGPoint(x: center.x + cos(a) * r0, y: center.y + sin(a) * r0))
        ctx.addLine(to: CGPoint(x: center.x + cos(a) * r1, y: center.y + sin(a) * r1))
    }
    ctx.strokePath()
}

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
