import Foundation
import simd

// Can anything that happens on the yaw axis reach the field's elevation — asked of
// the 08-21 transport, where elevation is gravity-anchored and only the heading is
// referenced.
//
// This harness exists because mark #1 of the 08-21 walk caught the old transport
// pointing sixteen HRTFs at +69…+76° of elevation for two full seconds while the raw
// head sat at +22…27°, then snapping 67° in half a second — with overruns, gaps,
// stalls and clamped all zero, because nothing was *wrong* anywhere downstream: the
// full-attitude reference plus leak had simply converted a yaw-side error into
// elevation. Per the house rule, the first test proves the trajectory used here
// reproduces that bug on the old composition; the rest assert the new one is immune,
// axis by axis.
//
// Run:
//   swiftc -O -o /tmp/thrumheading Shared/Spatial.swift Tools/heading/main.swift && /tmp/thrumheading

let dt = 0.02                       // AirPods Pro 2, per `motion 1500/30s`
var failures = 0

func check(_ ok: Bool, _ label: String, _ detail: String) {
    print("  \(ok ? "PASS" : "FAIL")  \(label) — \(detail)")
    if !ok { failures += 1 }
}

/// Head attitude in the world frame, CoreMotion axes (x right, y forward, z up).
func head(yaw: Double, pitch: Double) -> simd_quatd {
    HeadSmoother.rotation(yaw: yaw, pitch: pitch, roll: 0)
}

/// Gaze elevation of an orientation, off the forward vector — the same measurement
/// `HeadTracker.tilt` makes, well-conditioned everywhere on the sphere.
func tilt(_ q: simd_quatd) -> Double {
    let f = HeadSmoother.listener(q).forward
    return asin(max(-1, min(1, Double(f.y)))) * 180 / .pi
}

let worldUp = simd_double3(0, 0, 1)

/// A walk with a sensor yaw re-seat in it: yaw scanning ±20°, gait bob, and at
/// t = 100 s the sensor re-seats its own drifting yaw frame by +120° in the world —
/// which is invisible in raw tilt, and is what the old transport turned into a
/// phantom elevation event.
func walk(_ t: Double) -> simd_quatd {
    let yaw = 20 * sin(2 * .pi * t / 9)
    let pitch = 25 + 8 * sin(2 * .pi * t / 6.5)
    let reseat = t >= 100 ? 120.0 : 0.0
    return HeadSmoother.rotation(yaw: reseat, pitch: 0, roll: 0) * head(yaw: yaw, pitch: pitch)
}

print("CONTAINS THE BUG — the same trajectory through the old composition")
// The pre-08-21 transport, reconstructed: a full-attitude reference captured while
// looking down at the phone, and the leak chasing the whole referenced orientation.
do {
    let ref = head(yaw: 0, pitch: -50)
    let upInReference = ref.conjugate.act(worldUp)
    var leak = HeadSmoother.identity
    var worst = 0.0
    var t = 0.0
    while t < 130 {
        let att = walk(t)
        let rel = ref.conjugate * att
        let corrected = leak.conjugate * rel
        leak = HeadSmoother.leaked(leak, toward: rel, up: upInReference, dt: dt,
                                   elevation: 30, yaw: 120)
        worst = max(worst, abs(tilt(corrected) - tilt(att)))
        t += dt
    }
    check(worst > 20, "old transport",
          String(format: "a +120° yaw re-seat put %.0f° of phantom elevation on the field", worst))
}

/// The 08-21 transport, exactly as `HeadTracker.ingest` composes it.
struct Heading {
    var leak = HeadSmoother.identity
    var seeded = false
    mutating func step(_ att: simd_quatd) -> simd_quatd {
        if !seeded { leak = HeadSmoother.twist(att, about: worldUp); seeded = true }
        let corrected = leak.conjugate * att
        leak = HeadSmoother.leaked(leak, toward: att, up: worldUp, dt: dt,
                                   elevation: .infinity, yaw: 120)
        return corrected
    }
}

print("RESEAT — the same re-seat through the new composition")
do {
    var h = Heading()
    var worstTilt = 0.0
    var t = 0.0
    while t < 130 {
        let att = walk(t)
        worstTilt = max(worstTilt, abs(tilt(h.step(att)) - tilt(att)))
        t += dt
    }
    check(worstTilt < 0.01, "field tilt ≡ head tilt",
          String(format: "worst divergence %.4f° across the re-seat", worstTilt))
}

print("NOD — a nod is a pure pitch at any heading")
for heading in [0.0, 90.0, 173.0] {
    var h = Heading()
    // settle the seed, then nod 30° down
    _ = h.step(head(yaw: heading, pitch: 0))
    let corrected = h.step(head(yaw: heading, pitch: -30))
    let e = HeadSmoother.euler(corrected)
    check(abs(e.pitch + 30) < 0.5 && abs(e.yaw) < 0.5 && abs(e.roll) < 0.5,
          String(format: "heading %+4.0f°", heading),
          String(format: "corrected (yaw %+.2f°, pitch %+.2f°, roll %+.2f°)", e.yaw, e.pitch, e.roll))
}

print("GLANCE — elevation is kept absolutely; yaw still drains at its own rate")
do {
    // Seed level and ahead first — the glance is something the session does, not
    // the pose it starts in.
    var h = Heading()
    _ = h.step(head(yaw: 0, pitch: 0))
    let glance = head(yaw: 0, pitch: 60)
    var corrected = HeadSmoother.identity
    var t = 0.0
    while t < 60 { corrected = h.step(glance); t += dt }
    check(abs(tilt(corrected) - tilt(glance)) < 0.1, "60° up-glance held 60 s",
          String(format: "field still at %.1f° of the head's %.1f° (old transport kept 22%% at 60 s)",
                 tilt(corrected), tilt(glance)))

    var h2 = Heading()
    _ = h2.step(head(yaw: 0, pitch: 0))
    var c2 = HeadSmoother.identity
    t = 0
    while t < 30 { c2 = h2.step(head(yaw: 60, pitch: 0)); t += dt }
    let kept = HeadSmoother.euler(c2).yaw / 60
    check(kept > 0.70 && kept < 0.85, "60° yaw glance held 30 s",
          String(format: "keeps %.0f%% (τ = 120 s ⇒ 78%%)", kept * 100))
}

print("POLE — a craned head with a yaw wiggle never folds or whips")
do {
    var h = Heading()
    var worstDiff = 0.0, worstStep = 0.0
    var previous: simd_quatd?
    var t = 0.0
    while t < 30 {
        let att = head(yaw: 20 * sin(2 * .pi * t * 2), pitch: 65 + 5 * sin(2 * .pi * t / 3))
        let corrected = h.step(att)
        worstDiff = max(worstDiff, abs(tilt(corrected) - tilt(att)))
        if let p = previous { worstStep = max(worstStep, HeadSmoother.angle(p, corrected) / dt) }
        previous = corrected
        t += dt
    }
    check(worstDiff < 0.01 && worstStep < 400, "tilt exact, rate physical",
          String(format: "tilt divergence %.4f°, fastest field rotation %.0f°/s", worstDiff, worstStep))
}

print("SEED — a start at an arbitrary pose begins dead ahead at the true tilt")
do {
    var h = Heading()
    let pose = head(yaw: 137, pitch: 40)
    let corrected = h.step(pose)
    let e = HeadSmoother.euler(corrected)
    check(abs(e.yaw) < 0.5 && abs(tilt(corrected) - tilt(pose)) < 0.5, "yaw 137°, pitch +40°",
          String(format: "corrected yaw %+.2f°, tilt %+.1f° of the head's %+.1f°",
                 e.yaw, tilt(corrected), tilt(pose)))
}

if failures > 0 {
    print("\n\(failures) FAILURE\(failures == 1 ? "" : "S")")
    exit(1)
}
print("\nall clear")
