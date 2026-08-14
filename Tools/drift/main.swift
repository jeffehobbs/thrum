import Foundation
import simd

// Does the drift leak actually drain the drift the flight recorder measured, and
// does it cost anything a listener would notice — asked of `HeadSmoother.leaked`.
//
// **Conclusion first.** Against the drift rate the 08-14 walk actually recorded,
// the leak settles where the arithmetic says it should and never moves fast enough
// to be an event:
//
//  1. `SETTLE` — a constant 0.13°/s of elevation drift settles to ~4° of residual
//     and a constant yaw drift to ~16°, matching rate × τ to within a tenth of a
//     degree. The 40° the log recorded cannot accumulate.
//  2. `REPLAY` — driven with the measured drift *profile* rather than a constant,
//     the referenced tilt that reached 40° over five minutes stays inside single
//     figures throughout.
//  3. `RATE` — even against a head that never stops moving, the fastest the leak
//     ever rotates the field is 2.1°/s, 192× under `maxDegreesPerSecond` and well
//     below the ~0.5°/s-per-degree slew a listener could pick out of a drone. It
//     cannot trip the limit, so `clamped` staying at 0 remains a clean test of the
//     input rather than of this.
//  4. `GLANCE` — the cost, stated honestly: a deliberate turn held still decays,
//     because a leak cannot tell drift from intent. Yaw — the one people actually
//     hold — keeps 78% of a 60° glance after 30 s. Elevation, which nobody holds,
//     keeps 37%.
//  5. `SPLIT` — a pure yaw drift leaks at the yaw rate and a pure elevation drift at
//     the elevation rate, with under a degree of cross-talk. The axis split is doing
//     what it claims and is not quietly applying one constant to both.
//
// Run:
//   swiftc -O -o /tmp/thrumdrift Shared/Spatial.swift Tools/drift/*.swift && /tmp/thrumdrift
//
// The reference frame here is CoreMotion's, as everywhere else on this path:
// x right, y forward, z up, so `up` is (0, 0, 1) for a listener who was upright when
// the reference was captured. On the device it comes from gravity instead, because
// the reference is captured while the listener looks down at the phone — see
// `HeadTracker.upInReference`.

let up = simd_double3(0, 0, 1)
let elevationTau = 30.0, yawTau = 120.0
let rate = 50.0                       // AirPods Pro 2, per `motion 1500/30s`
let dt = 1 / rate

/// Elevation is a rotation about x (pitch); yaw is about z. Both in the reference
/// frame, both as the transport carries them — quaternions, never Euler angles.
func pitch(_ deg: Double) -> simd_quatd {
    simd_quatd(angle: deg * .pi / 180, axis: simd_double3(1, 0, 0))
}
func yawed(_ deg: Double) -> simd_quatd {
    simd_quatd(angle: deg * .pi / 180, axis: simd_double3(0, 0, 1))
}

/// What the field is left pointing at, in degrees, given a drift and the leak's
/// current state — the same `leak⁻¹ · rel` the host hands the smoother.
func residual(_ leak: simd_quatd, _ rel: simd_quatd) -> Double {
    HeadSmoother.angle(leak.conjugate * rel, HeadSmoother.identity)
}

/// Drive the leak for `seconds`, with the referenced orientation supplied per sample.
/// Returns the final residual and the fastest the correction ever moved, in °/s.
func run(seconds: Double, rel: (Double) -> simd_quatd) -> (residual: Double, peak: Double) {
    var leak = HeadSmoother.identity
    var peak = 0.0
    var t = 0.0
    while t < seconds {
        let r = rel(t)
        let next = HeadSmoother.leaked(leak, toward: r, up: up, dt: dt,
                                       elevation: elevationTau, yaw: yawTau)
        peak = max(peak, HeadSmoother.angle(leak, next) / dt)
        leak = next
        t += dt
    }
    return (residual(leak, rel(t)), peak)
}

print("SETTLE — constant drift, 20 min, against the rate × τ the trade was chosen on")
// 40° over five minutes, straight off the 08-14 log's per-minute medians.
let measured = 40.0 / 300
for (name, tau, make) in [("elevation", elevationTau, pitch), ("yaw", yawTau, yawed)] {
    let r = run(seconds: 1200) { make(measured * $0) }
    let label = name.padding(toLength: 9, withPad: " ", startingAt: 0)
    print(String(format: "  %@ drift %.3f°/s → residual %5.2f°   (rate × τ = %5.2f°)   peak %.4f°/s",
                 label as NSString, measured, r.residual, measured * tau, r.peak))
}

print()
print("REPLAY — the measured drift profile, marks #13–15 (0° → +40° over five minutes)")
// The log's five one-minute medians for that window, interpolated.
let profile: [Double] = [-2, 4, 27, 30, 28, 40]
func sampled(_ t: Double) -> Double {
    let x = max(0, min(4.999, t / 60))
    let i = Int(x)
    return profile[i] + (profile[i + 1] - profile[i]) * (x - Double(i))
}
var leak = HeadSmoother.identity
var worst = 0.0, t = 0.0
while t < 300 {
    let rel = pitch(sampled(t))
    worst = max(worst, residual(leak, rel))
    leak = HeadSmoother.leaked(leak, toward: rel, up: up, dt: dt,
                               elevation: elevationTau, yaw: yawTau)
    t += dt
}
print(String(format: "  uncorrected reached %.0f°   →   corrected never exceeded %.1f°",
             profile.map(abs).max()!, worst))

print()
print("RATE — how fast the leak itself ever rotates the field")
let fast = run(seconds: 600) { pitch(60 * sin($0 / 8)) }      // a head that never rests
print(String(format: "  worst case over ten minutes of continuous movement: %.3f°/s", fast.peak))
print(String(format: "  slew limit is %.0f°/s — headroom ×%.0f",
             HeadSmoother.maxDegreesPerSecond,
             HeadSmoother.maxDegreesPerSecond / max(fast.peak, 1e-9)))

print()
print("GLANCE — the cost: a deliberate turn, held, decays")
for (name, make) in [("elevation", pitch), ("yaw", yawed)] {
    var kept: [String] = []
    for hold in [10.0, 30.0, 60.0] {
        let r = run(seconds: hold) { _ in make(60) }
        kept.append(String(format: "%2.0fs %3.0f%%", hold, 100 * r.residual / 60))
    }
    print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) 60° held → " + kept.joined(separator: "   "))
}

print()
print("SPLIT — each axis leaks at its own rate, without cross-talk")
for (name, make) in [("pure elevation", pitch), ("pure yaw", yawed)] {
    let r = run(seconds: 1200) { make(measured * $0) }
    let expectedElevation = measured * elevationTau, expectedYaw = measured * yawTau
    let target = name.hasPrefix("pure yaw") ? expectedYaw : expectedElevation
    print(String(format: "  %-15@ residual %5.2f°  vs its own constant's %5.2f°  (error %.2f°)",
                 name as NSString, r.residual, target, abs(r.residual - target)))
}
