import UIKit
import simd

/// Draws the field as a still image, for Now Playing artwork.
///
/// This is how the visualizer reaches a car. CarPlay renders only Apple's
/// templates and permits no custom drawing at all — but artwork is just an image,
/// so the one surface it *will* show us is a square of our own pixels. Refreshing
/// it as Flow moves means the car, the lock screen and Control Centre all show
/// what is actually sounding rather than a fixed logo.
///
/// Core Graphics rather than Metal on purpose. This runs a couple of times a
/// minute, not twenty times a second, so a GPU pass would mean keeping a Metal
/// pipeline alive and reading a texture back to the CPU — more moving parts and
/// more power than simply drawing it. The blooms are radial gradients either way.
///
/// Deliberately the same geometry as `Shaders.metal`: angle is scale degree with
/// the tonic straight up, radius is octave. The car and the phone are then showing
/// the same picture of the same chord, which is the point.
enum FieldArtwork {
    /// Smaller than the 1024 the App Store wants for an icon. Now Playing artwork
    /// is displayed a few hundred points wide at most, on a dashboard or a lock
    /// screen, and soft blooms have nothing to gain from more pixels.
    static let size: CGFloat = 768

    static func render(voices: [ShaderVoice], count: Int, master: Float) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)

        return renderer.image { context in
            let cg = context.cgContext
            let s = size
            let centre = CGPoint(x: s / 2, y: s / 2)

            // Background: the app's near-black, lifted very slightly toward the
            // middle so the square doesn't read as a hole on a bright dashboard.
            cg.setFillColor(UIColor(red: 0.043, green: 0.039, blue: 0.058, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: s, height: s))

            let cs = CGColorSpaceCreateDeviceRGB()
            if let wash = CGGradient(colorsSpace: cs, colors: [
                UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 0.55 * CGFloat(0.35 + master)).cgColor,
                UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 0).cgColor,
            ] as CFArray, locations: [0, 1]) {
                cg.drawRadialGradient(wash, startCenter: centre, startRadius: 0,
                                      endCenter: centre, endRadius: s * 0.62, options: [])
            }

            // Blooms, additively, so overlapping voices pile up into light the way
            // they do in the shader.
            cg.setBlendMode(.plusLighter)
            for i in 0..<min(count, voices.count) {
                let v = voices[i]
                guard v.level > 0.0009 else { continue }

                // Shader space is −1…1 with y up; UIKit's y grows down.
                let p = CGPoint(x: centre.x + CGFloat(v.position.x) * s * 0.5,
                                y: centre.y - CGFloat(v.position.y) * s * 0.5)
                let tint = UIColor(hue: CGFloat(v.hue), saturation: 0.42, brightness: 1.0, alpha: 1)

                // Two lobes, matching the shader: a tight core and a wide halo.
                // The halo is what makes a drone read as continuous rather than as
                // a scatter of dots.
                for (radius, alpha) in [(s * 0.055, 0.95), (s * 0.30, 0.34)] {
                    guard let bloom = CGGradient(colorsSpace: cs, colors: [
                        tint.withAlphaComponent(CGFloat(alpha) * CGFloat(v.level)).cgColor,
                        tint.withAlphaComponent(0).cgColor,
                    ] as CFArray, locations: [0, 1]) else { continue }
                    cg.drawRadialGradient(bloom, startCenter: p, startRadius: 0,
                                          endCenter: p, endRadius: radius, options: [])
                }
            }
            cg.setBlendMode(.normal)

            // Vignette, so it sits as an image rather than a screenshot.
            if let vignette = CGGradient(colorsSpace: cs, colors: [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(0.55).cgColor,
            ] as CFArray, locations: [0.55, 1]) {
                cg.drawRadialGradient(vignette, startCenter: centre, startRadius: 0,
                                      endCenter: centre, endRadius: s * 0.78, options: [])
            }
        }
    }
}
