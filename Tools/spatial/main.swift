import Foundation
import AVFoundation
import simd

// Offline checks for spatial mode. The whole point of this harness is that the
// spatial path is a *second* master chain — per-bus EQ, a wet tail extracted by
// subtraction, and one limiter shared across seventeen outputs — and none of
// that is audible as "wrong" until it is very wrong.
//
//   swiftc -O -o /tmp/thrumspatial \
//     Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Spatial,AudioRoute}.swift \
//     Tools/spatial/*.swift
//   /tmp/thrumspatial

let sr = 48000.0
let block = 512
let buses = DroneEngine.spatialBusCount

var fails = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { fails += 1 }
}

func fbuf(_ n: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
    p.initialize(repeating: 0, count: n)
    return p
}

/// Render `seconds` of spatial output. Returns per-bus RMS, wet RMS, the peak of
/// the summed field, and whether everything stayed finite.
struct Spatial {
    var busRMS: [Double]
    var wetRMS: Double
    var sumPeak: Float
    var finite: Bool
    /// Largest second difference in the summed field, relative to its peak.
    ///
    /// This is the crackle detector. The drone is bandlimited and smooth, so
    /// |x[n] − 2x[n−1] + x[n−2]| stays small — but a gain that changes
    /// *discontinuously* from one sample to the next puts a kink in the
    /// waveform, and a kink is a broadband click. An earlier limiter here
    /// enforced its ceiling with min(gain, ceiling/|x|), which switches once per
    /// peak and crackled audibly on loud material; this number is how that shows
    /// up in a test rather than in somebody's ears.
    var roughness: Double
}

func runSpatial(_ e: DroneEngine, seconds: Double) -> Spatial {
    let bus = fbuf(block), l = fbuf(block), r = fbuf(block)
    defer { bus.deallocate(); l.deallocate(); r.deallocate() }
    var acc = [Double](repeating: 0, count: buses)
    var wetAcc = 0.0
    var count = 0
    var peak: Float = 0
    var finite = true
    var t = 0.0
    var rough = 0.0
    var warm = 0
    var prev1: Float = 0, prev2: Float = 0
    while t < seconds {
        e.renderSpatial(frameCount: block)
        var frameSum = [Float](repeating: 0, count: block)
        for b in 0..<buses {
            e.copyBus(b, block, into: bus)
            for i in 0..<block {
                if !bus[i].isFinite { finite = false }
                acc[b] += Double(bus[i]) * Double(bus[i])
                frameSum[i] += bus[i]
            }
        }
        e.copyWet(block, l, r)
        for i in 0..<block {
            if !l[i].isFinite || !r[i].isFinite { finite = false }
            wetAcc += Double(l[i]) * Double(l[i])
            frameSum[i] += l[i] + r[i]
            peak = max(peak, abs(frameSum[i]))
        }
        // Second difference of the summed field, carried across block edges.
        // The first two samples of the very first block have no history, and
        // scoring them against zero invents a full-scale step that swamps
        // everything real — warm the history up instead of measuring it.
        for i in 0..<block {
            let x = frameSum[i]
            if warm >= 2 { rough = max(rough, Double(abs(x - 2 * prev1 + prev2))) }
            warm += 1
            prev2 = prev1; prev1 = x
        }
        count += block
        t += Double(block) / sr
    }
    let d = Double(max(1, count))
    return Spatial(busRMS: acc.map { ($0 / d).squareRoot() },
                   wetRMS: (wetAcc / d).squareRoot(), sumPeak: peak, finite: finite,
                   roughness: rough / Double(max(1e-9, peak)))
}

func makeEngine(reverb: Float = 0) -> DroneEngine {
    let e = DroneEngine()
    e.setSampleRate(sr)
    e.spatialEnabled = true
    e.reverbMix = reverb
    e.swellSeconds = 0.3
    for p in 0..<DroneEngine.voiceCount {
        e.retune(pad: p, frequency: 110 * pow(2, Double(p % 12) / 12))
    }
    return e
}

print("\n— bus routing —")

// 1. A pad must land on exactly one bus, and it must be the documented one.
do {
    var wrong = 0
    for pad in [0, 7, 8, 15, 16, 23, 24, 31] {
        let e = makeEngine()
        e.setLevel(pad: pad, level: 0.8)
        e.gate(pad: pad, on: true)
        let s = runSpatial(e, seconds: 1.0)
        let want = DroneEngine.bus(pad: pad)
        let loud = s.busRMS.enumerated().filter { $0.element > 1e-5 }.map { $0.offset }
        if loud != [want] { wrong += 1; print("      pad \(pad) → \(loud), wanted [\(want)]") }
    }
    check(wrong == 0, "each pad sounds on exactly its own bus", "\(wrong) misrouted")

    // Column sets azimuth, octave sets tier: rows 0–1 low, rows 2–3 high.
    check(DroneEngine.bus(pad: 0) == 0 && DroneEngine.bus(pad: 7) == 7,
          "bottom octave maps to the low tier")
    check(DroneEngine.bus(pad: 16) == 8 && DroneEngine.bus(pad: 31) == 15,
          "top octaves map to the high tier")
    check(DroneEngine.bus(pad: 0) == DroneEngine.bus(pad: 8),
          "same column, same compass point")
}

print("\n— the wet bed —")

// 2. Wet is extracted by subtracting the send back off, so Wet=0 must be silent
//    and the dry must not care what Wet is doing.
do {
    func trial(_ mix: Float) -> Spatial {
        let e = makeEngine(reverb: mix)
        for p in [0, 4, 18] { e.setLevel(pad: p, level: 0.6); e.gate(pad: p, on: true) }
        _ = runSpatial(e, seconds: 1.5)          // settle the swell
        return runSpatial(e, seconds: 1.5)
    }
    let dry = trial(0)
    let wet = trial(0.9)
    check(dry.wetRMS < 1e-4, "Wet at zero leaves no tail", String(format: "%.7f", dry.wetRMS))
    check(wet.wetRMS > 1e-3, "Wet at 90% produces one", String(format: "%.4f", wet.wetRMS))

    let dryTotal = dry.busRMS.reduce(0, +)
    let wetTotal = wet.busRMS.reduce(0, +)
    check(abs(dryTotal - wetTotal) < dryTotal * 0.05,
          "the dry buses are unchanged by the reverb setting",
          String(format: "%.4f vs %.4f", dryTotal, wetTotal))
}

print("\n— the shared limiter —")

// 3. One limiter across seventeen outputs. It has to hold the field down without
//    moving it: the ratio between two buses must survive limiting.
do {
    // The same field twice: once quiet enough that the limiter never engages,
    // once loud enough that it is working hard. Uniform limiting means the
    // *ratio* between two buses is the same in both — which is the property that
    // matters, and is testable without predicting the absolute number.
    func trial(_ volume: Float) -> Spatial {
        let e = makeEngine()
        e.masterVolume = volume
        for p in 0..<8 { e.setLevel(pad: p, level: 1.0); e.gate(pad: p, on: true) }
        e.setLevel(pad: 4, level: 0.25)
        _ = runSpatial(e, seconds: 2.0)
        return runSpatial(e, seconds: 2.0)
    }
    let quiet = trial(0.05)
    let loud = trial(1.0)

    check(loud.finite && quiet.finite, "no non-finite samples anywhere")
    check(loud.sumPeak <= 1.0, "summed field stays under the ceiling",
          String(format: "peak %.3f", loud.sumPeak))
    check(loud.sumPeak > quiet.sumPeak, "the loud trial really is louder",
          String(format: "%.3f vs %.3f", loud.sumPeak, quiet.sumPeak))

    func ratio(_ s: Spatial) -> Double {
        s.busRMS[DroneEngine.bus(pad: 4)] / max(1e-12, s.busRMS[DroneEngine.bus(pad: 0)])
    }
    let rq = ratio(quiet), rl = ratio(loud)
    // A per-bus limiter would squash the loud bus and drag this towards 1.
    check(abs(rl - rq) < rq * 0.08,
          "limiting is uniform — bus ratio survives it",
          String(format: "%.4f unlimited vs %.4f limited", rq, rl))
}

print("\n— what actually leaves the machine —")

// Build the app's real graph offline and read the post-HRTF samples. This is the
// only measurement that can answer "does it clip", because the engine's limiter
// only ever sees the mono sum of its buses.
do {
    for (label, volume) in [("output 40%", Float(0.4)), ("output 100%", Float(1.0))] {
        let e = makeEngine(reverb: 0.42)
        e.masterVolume = volume
        for p in 0..<DroneEngine.voiceCount where p % 2 == 0 {
            e.setLevel(pad: p, level: 0.9); e.gate(pad: p, on: true)
        }
        _ = runSpatial(e, seconds: 2.0)          // settle the swell
        guard let r = Binaural.measure(e, sampleRate: sr, seconds: 4.0) else {
            print("      skipped — no manual rendering"); break
        }
        print(String(format: "       %@: binaural peak %.3f, rms %.3f, %d samples at full scale",
                     label, r.peak, r.rms, r.overs))
        check(r.peak < 1.0, "\(label) — binaural output stays inside full scale",
              String(format: "peak %.3f", r.peak))
        check(r.overs == 0, "\(label) — nothing clips", "\(r.overs) samples")
    }
}

print("\n— crackle —")

// A detector needs material where a kink cannot hide. A full drone has fourteen
// partials reaching 9 kHz, and its own second difference is ~0.5 of peak, which
// swamps anything the limiter does — measured on that, a known-bad limiter and a
// good one score the same, so the test is worthless. One low voice with the
// filter shut down, no drive and no reverb is nearly a sine: its natural second
// difference is tiny, and a gain that steps stands out against it.
do {
    func trial(_ volume: Float) -> Spatial {
        let e = DroneEngine()
        e.setSampleRate(sr)
        e.spatialEnabled = true
        e.reverbMix = 0
        e.drive = 0
        e.brightness = 0.18         // low, so almost no HF of its own
        e.beating = 0
        e.motion = 0
        e.drift = 0
        e.swellSeconds = 0.2
        e.masterVolume = volume
        // Eight voices so the sum genuinely reaches the ceiling; each is still
        // nearly a sine, so the material stays smooth enough to see kinks in.
        for p in 0..<DroneEngine.voiceCount {
            e.retune(pad: p, frequency: 80 * Double(p % 8 + 1))
            e.setLevel(pad: p, level: 1.0)
            e.gate(pad: p, on: true)
        }
        _ = runSpatial(e, seconds: 1.5)
        return runSpatial(e, seconds: 2.0)
    }
    let quiet = trial(0.03)         // never limits
    let loud = trial(1.0)           // limits hard
    print(String(format: "       peaks: %.3f unlimited, %.3f limited hard  (ceiling engages above ~0.72)",
                 quiet.sumPeak, loud.sumPeak))
    print(String(format: "       roughness on a near-sine: %.5f unlimited, %.5f limited hard",
                 quiet.roughness, loud.roughness))
    if loud.sumPeak < 0.7 {
        print("       INCONCLUSIVE — the limiter never engaged, so this proves nothing")
        fails += 1
    }
    check(loud.roughness < quiet.roughness * 3 + 0.002,
          "hard limiting adds no kinks to a smooth waveform",
          String(format: "%.5f vs %.5f", loud.roughness, quiet.roughness))
}

print("\n— parity with the stereo path —")

// 4. Spatial mode must not lose or duplicate voices. Compare the mono sum of the
//    whole field against the ordinary stereo render's mono sum, with Width at
//    unity so mid/side is an identity and the two are actually comparable.
do {
    func stereoMonoRMS(seconds: Double) -> Double {
        let e = DroneEngine()
        e.setSampleRate(sr)
        e.reverbMix = 0
        e.width = 1.0
        e.swellSeconds = 0.3
        for p in 0..<DroneEngine.voiceCount {
            e.retune(pad: p, frequency: 110 * pow(2, Double(p % 12) / 12))
        }
        for p in [0, 4, 18] { e.setLevel(pad: p, level: 0.6); e.gate(pad: p, on: true) }
        let abl = AudioBufferListHolder(block)
        var acc = 0.0, count = 0, t = 0.0
        while t < seconds {
            e.render(frameCount: block, out: abl.ptr)
            if t > 1.5 {
                for i in 0..<block {
                    let m = Double(abl.l[i] + abl.r[i]) * 0.5
                    acc += m * m; count += 1
                }
            }
            t += Double(block) / sr
        }
        return (acc / Double(max(1, count))).squareRoot()
    }
    let e = makeEngine()
    e.width = 1.0
    for p in [0, 4, 18] { e.setLevel(pad: p, level: 0.6); e.gate(pad: p, on: true) }
    _ = runSpatial(e, seconds: 1.5)
    let field = runSpatial(e, seconds: 1.5)
    // Each voice is mono-summed into its bus at (L+R)/2, which is the same
    // quantity, so the totals should be in the same ballpark.
    let spatialMono = field.busRMS.reduce(0) { $0 + $1 * $1 }.squareRoot()
    let stereoMono = stereoMonoRMS(seconds: 3.0)
    let ratio = spatialMono / max(1e-9, stereoMono)
    check(ratio > 0.7 && ratio < 1.4, "field carries the same energy as the stereo mix",
          String(format: "%.3f× (%.4f vs %.4f)", ratio, spatialMono, stereoMono))
}

print("\n— what the HRTF stage really costs —")

do {
    let cases: [(String, AVAudio3DMixingRenderingAlgorithm, Int)] = [
        ("16 buses, HRTFHQ      ", .HRTFHQ, 16),
        ("16 buses, HRTF        ", .HRTF, 16),
        ("16 buses, sphericalHead", .sphericalHead, 16),
        ("16 buses, equalPower   ", .equalPowerPanning, 16),
        (" 8 buses, HRTF        ", .HRTF, 8),
    ]
    for (label, algo, n) in cases {
        let e = makeEngine(reverb: 0.42)
        for p in 0..<DroneEngine.voiceCount {
            e.setLevel(pad: p, level: 0.8); e.gate(pad: p, on: true); e.setSitar(pad: p, depth: 0.5)
        }
        _ = runSpatial(e, seconds: 1.0)
        guard let r = Binaural.measure(e, sampleRate: sr, seconds: 4.0, algorithm: algo, buses: n)
        else { print("      \(label): unavailable"); continue }
        let times = 4.0 / r.seconds
        print(String(format: "       %@ %5.1f× realtime  (%4.1f%% of one core)",
                     label, times, 100.0 / times))
    }
    print("       for reference, DroneEngine alone in spatial mode is about 18× / 5.6%")
}

print("\n— cost —")

// 5. Sixteen buses of EQ and a full grid is the worst case the host will ask for.
do {
    let e = makeEngine(reverb: 0.42)
    for p in 0..<DroneEngine.voiceCount {
        e.setLevel(pad: p, level: 0.7); e.gate(pad: p, on: true); e.setSitar(pad: p, depth: 0.6)
    }
    _ = runSpatial(e, seconds: 1.0)
    let start = Date()
    _ = runSpatial(e, seconds: 5.0)
    let wall = Date().timeIntervalSince(start)
    let times = 5.0 / wall
    print(String(format: "       full grid, jawari on, spatial: %.1f× realtime (%.1f%% of one core)",
                 times, 100.0 / times))
    check(times > 3.0, "spatial worst case has headroom before the deadline",
          String(format: "%.1f×", times))
}

print("\n— the head-tracking transport —")

// 6. `HeadSmoother` is the whole of what stands between a CoreMotion sample and
// sixteen HRTFs being re-pointed, and until it was pulled out of `HeadTracker` none
// of it could be tested at all: it was reachable only through a `CMAttitude`, which
// has no public initialiser. These drive it with a synthetic head instead.
//
// The reason to care is a listener report — "warble when I tilt my head up and
// down, worst on the higher voices" — that survived three offline measurements of
// the render path. `Tools/warble` established that AVAudioEnvironmentNode is not at
// fault: it crossfades its filter hand-overs (boundary roughness 1.00× interior at
// every frequency tried) and snaps no harder in elevation than azimuth. So the
// suspect is what we hand it, and a discontinuity in an Euler angle is the one thing
// on this path that is intermittent, axis-specific, and loudest in the high band —
// because a large step re-points every source at once and elevation is encoded in
// pinna notches at 5–10 kHz.
do {
    /// Feed a trajectory in and report what came out.
    func run(_ samples: [(Double, Double, Double)], dt: Double = 0.04)
    -> (out: [AVAudio3DVectorOrientation], clamped: Int, peak: Double) {
        var s = HeadSmoother()
        var out: [AVAudio3DVectorOrientation] = []
        var clamped = 0, peak = 0.0
        for (y, p, r) in samples {
            let step = s.step(yaw: y, pitch: p, roll: r, dt: dt)
            out.append(step.head.orientation)
            if step.clamped { clamped += 1 }
            peak = max(peak, step.rate)
        }
        return (out, clamped, peak)
    }

    /// How far the field actually turned between two frames, in degrees.
    ///
    /// Measured on the vectors the node is driven with rather than on Euler angles,
    /// and that is the point: the whole bug was an Euler angle moving 168° while the
    /// rotation it described moved a fraction of a degree. A test that measured the
    /// angles would have reported the artifact as a real movement — and, run against
    /// the fix, would report the fix as broken.
    func fieldStep(_ a: AVAudio3DVectorOrientation, _ b: AVAudio3DVectorOrientation) -> Double {
        func ang(_ u: AVAudio3DVector, _ v: AVAudio3DVector) -> Double {
            let d = Double(u.x * v.x + u.y * v.y + u.z * v.z)
            return acos(max(-1, min(1, d))) * 180 / .pi
        }
        return max(ang(a.forward, b.forward), ang(a.up, b.up))
    }
    /// The largest single-frame movement in the output, which is what the HRTF sees.
    func biggestStep(_ v: [AVAudio3DVectorOrientation]) -> Double {
        var worst = 0.0
        for i in 1..<v.count { worst = max(worst, fieldStep(v[i - 1], v[i])) }
        return worst
    }

    // An ordinary nod: ±20° at 0.4 Hz, which is looking down at the phone and back.
    // Nothing here should ever engage the limit — if it did, the limit would be a
    // tone control rather than a guard.
    let nod = (0..<200).map { i -> (Double, Double, Double) in
        (0, 20 * sin(2 * .pi * 0.4 * Double(i) * 0.04), 0)
    }
    let nodded = run(nod)
    check(nodded.clamped == 0, "an ordinary nod is never rate-limited",
          "peak input \(Int(nodded.peak))°/s")
    // The rate the recorder reports has to be the head's, not the smoother's lag —
    // it is the one number that says whether a stream is physically possible, and it
    // is useless if ordinary movement already reads as impossible. A ±20° nod at
    // 0.4 Hz peaks at 2π·0.4·20 ≈ 50°/s.
    check(nodded.peak > 40 && nodded.peak < 60,
          "and the rate it reports is the head's own, not the tracking error",
          String(format: "%.0f°/s for a nod that peaks at 50", nodded.peak))
    check(biggestStep(nodded.out) < 2, "and moves the field in small steps",
          String(format: "largest %.2f° per frame", biggestStep(nodded.out)))

    // A fast deliberate turn — 300°/s, faster than anyone looks around — still must
    // not be limited, or the field lags the head exactly when it is most obvious.
    let fast = (0..<40).map { i -> (Double, Double, Double) in (300 * Double(i) * 0.04, 0, 0) }
    check(run(fast).clamped == 0, "so is a 300°/s turn of the head")

    // The bug this fixes. Roll used to get neither the wrap nor the shortest way
    // round, so a head tilted far enough to take CoreMotion's roll from +179° to
    // −179° handed the one-pole a 358° error and it set off the long way, sweeping
    // the whole field through every azimuth on its way to a destination 2° away.
    var held = HeadSmoother()
    for _ in 0..<80 { _ = held.step(yaw: 0, pitch: 0, roll: 179, dt: 0.04) }
    check(abs(held.roll - 179) < 1, "roll settles where it was told to",
          String(format: "%.1f°", held.roll))
    var travelled = 0.0
    var previous = held.orientation
    for _ in 0..<40 {
        let s = held.step(yaw: 0, pitch: 0, roll: -179, dt: 0.04)
        travelled += fieldStep(previous, s.head.orientation)
        previous = s.head.orientation
    }
    check(travelled < 10, "and crossing ±180° takes the short way, not 358° of field",
          String(format: "travelled %.1f°", travelled))

    // Any discontinuity at all — a re-seated reference, a resumed Bluetooth batch —
    // is spread over several frames instead of arriving as one event.
    var jumped = HeadSmoother()
    for _ in 0..<60 { _ = jumped.step(yaw: 0, pitch: 0, roll: 0, dt: 0.04) }
    var worst = 0.0, previousFacing = jumped.orientation
    for _ in 0..<40 {
        let s = jumped.step(yaw: 0, pitch: 90, roll: 0, dt: 0.04)
        worst = max(worst, fieldStep(previousFacing, s.head.orientation))
        previousFacing = s.head.orientation
    }
    check(worst <= HeadSmoother.maxDegreesPerSecond * 0.04 + 0.001,
          "a 90° step is delivered as a glide, not a lurch",
          String(format: "largest %.1f° per frame, was %.1f before the limit",
                 worst, 90 * HeadSmoother.coefficient(for: 0.04)))
    check(abs(jumped.pitch - 90) < 5, "and still arrives",
          String(format: "%.1f°", jumped.pitch))

    // The smoothing has to be a *time*, not a per-sample coefficient.
    //
    // This is the check that would have caught the real bug. The old smoother
    // multiplied the error by a bare 0.28 every sample, which is only the intended
    // ~120 ms if the sensor delivers 25 Hz — and ThrumFlow's flight recorder says
    // AirPods Pro 2 deliver 50 Hz (`motion 1500/30s`, every session). So on the
    // device the field settled in half the time it was tuned for, i.e. head movement
    // reached sixteen HRTFs twice as twitchy as designed.
    //
    // Same head, same wall-clock, two sensor rates: the field must arrive in the same
    // place at the same time. Half a second into a 30° turn a 120 ms one-pole is
    // ~98% there, and the two rates must agree to well inside what an ear could tell.
    func settle(after seconds: Double, dt: Double) -> Double {
        var s = HeadSmoother()
        for _ in 0..<Int(seconds / dt) { _ = s.step(yaw: 30, pitch: 0, roll: 0, dt: dt) }
        return s.yaw
    }
    let at25 = settle(after: 0.5, dt: 0.04)
    let at50 = settle(after: 0.5, dt: 0.02)
    check(abs(at25 - at50) < 0.5,
          "smoothing is a time constant, so the sensor's rate can't change the feel",
          String(format: "%.2f° at 25 Hz vs %.2f° at 50 Hz", at25, at50))
    // And it is still the time constant the original coefficient encoded, so this is
    // a fix to the 50 Hz case rather than a retuning of the 25 Hz one.
    check(abs(HeadSmoother.coefficient(for: 0.04) - 0.28) < 0.005,
          "and 25 Hz still gets exactly the coefficient it was tuned with",
          String(format: "%.3f", HeadSmoother.coefficient(for: 0.04)))

    // 6a. The hike bug: relative pitch crossing vertical.
    //
    // A smooth physical rotation carrying the head through pitch = 90° — which is
    // what an ordinary nod does once the reference was captured while looking down at
    // the phone. The rotation never moves faster than a slow turn, but CMAttitude's
    // Z-X-Y decomposition of it has pitch as the middle axis, so yaw and roll flip by
    // ~180° on the way through.
    //
    // The A/B matters more than the assertion here. This project has learned twice
    // that a detector can pass for the wrong reason, so the test first proves the
    // *input* is genuinely poisoned — if the raw Euler stream were smooth, everything
    // below would pass on a trajectory that never contained the bug.
    let crossing: [simd_quatd] = (0..<120).map { i in
        let t = Double(i) / 119
        let tilt = (60 + 60 * t) * .pi / 180        // 60° → 120° about the ear axis
        return simd_quatd(angle: 20 * .pi / 180, axis: simd_double3(0, 0, 1))
             * simd_quatd(angle: tilt, axis: simd_double3(1, 0, 0))
    }
    // Physically this is a 60° tilt over ~5 s: nothing, about 12°/s.
    var trueTravel = 0.0
    for i in 1..<crossing.count { trueTravel += HeadSmoother.angle(crossing[i - 1], crossing[i]) }
    let eulers = crossing.map { HeadSmoother.euler($0) }
    var rawJump = 0.0
    for i in 1..<eulers.count {
        rawJump = max(rawJump, abs(HeadSmoother.wrap(eulers[i].yaw - eulers[i - 1].yaw)))
        rawJump = max(rawJump, abs(HeadSmoother.wrap(eulers[i].roll - eulers[i - 1].roll)))
    }
    check(trueTravel < 70 && rawJump > 100,
          "the trajectory really does contain the bug (so the checks below mean something)",
          String(format: "head turns %.0f° in total, its Euler angles jump %.0f° in one sample",
                 trueTravel, rawJump))

    // Now the fix. Both entry points have to survive it: the quaternion one the app
    // uses, and the Euler convenience one — because recomposing CMAttitude's angles in
    // its own Z-X-Y order *cancels* the degenerate split rather than inheriting it,
    // and that is the load-bearing claim of this rewrite.
    for (name, feed) in [("quaternion", true), ("Euler round-trip", false)] {
        var s = HeadSmoother()
        var out: [AVAudio3DVectorOrientation] = []
        var clamped = 0, peakRate = 0.0
        // Settle on the starting attitude first. Without this the measurement is
        // dominated by the smoother gliding in from identity to a head already tilted
        // 60°, which is a legitimate rate-limited arrival and not what is under test.
        for _ in 0..<80 { _ = s.step(rotation: crossing[0], dt: 0.04) }
        for (i, q) in crossing.enumerated() {
            let step: HeadStep
            if feed {
                step = s.step(rotation: q, dt: 0.04)
            } else {
                let e = eulers[i]
                step = s.step(yaw: e.yaw, pitch: e.pitch, roll: e.roll, dt: 0.04)
            }
            out.append(step.head.orientation)
            if step.clamped { clamped += 1 }
            peakRate = max(peakRate, step.rate)
        }
        check(clamped == 0 && peakRate < 200,
              "crossing vertical is not a discontinuity — \(name)",
              String(format: "%d frames limited, peak rate %.0f°/s (was 8352 on the hike)",
                     clamped, peakRate))
        check(biggestStep(out) < 3,
              "and the field turns in small steps through it — \(name)",
              String(format: "largest %.2f° per frame", biggestStep(out)))
    }

    // 6b. The rewrite must not have moved the field.
    //
    // The reason this is safe to ship into a notarized Mac app whose spatial image was
    // tuned by ear: driving `listenerVectorOrientation` from a conjugated quaternion has
    // to be *identical* to the `(-yaw, -pitch, -roll)` angular path it replaces. Rather
    // than argue that from Apple's documentation, ask the node — setting an angular
    // orientation and reading the vector one back makes it state its own mapping.
    let env = AVAudioEnvironmentNode()
    var worstVector = 0.0
    var seed = 12345.0
    func rnd() -> Double {
        seed = (seed * 1103515245 + 12345).truncatingRemainder(dividingBy: 2147483648)
        return seed / 2147483648
    }
    for _ in 0..<400 {
        // Away from ±90° pitch, where the path being replaced was meaningful at all.
        let y = (rnd() * 2 - 1) * 170, p = (rnd() * 2 - 1) * 60, r = (rnd() * 2 - 1) * 170
        env.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: Float(-y), pitch: Float(-p), roll: Float(-r))
        let shipped = env.listenerVectorOrientation
        let ours = HeadSmoother.listener(HeadSmoother.rotation(yaw: y, pitch: p, roll: r))
        // Compared component by component, not as an angle: `acos` of a dot product
        // near 1 amplifies Float32 rounding into a spurious ~0.03°, and the node stores
        // these as Float, so an angular comparison here measures the storage rather
        // than the mapping.
        worstVector = max(worstVector, max(
            max(abs(Double(shipped.forward.x - ours.forward.x)),
                max(abs(Double(shipped.forward.y - ours.forward.y)),
                    abs(Double(shipped.forward.z - ours.forward.z)))),
            max(abs(Double(shipped.up.x - ours.up.x)),
                max(abs(Double(shipped.up.y - ours.up.y)),
                    abs(Double(shipped.up.z - ours.up.z))))))
    }
    check(worstVector < 1e-5,
          "and it points the listener exactly where the angular path did",
          String(format: "worst disagreement %.2e over 400 random rotations, on unit vectors",
                 worstVector))
}

// MARK: - The gaze histogram
//
// Checked rather than trusted, because this is the instrument the 08-13 anomaly is
// now resting on: a referenced gaze that spanned 179° in a twelve-minute walk, which
// is more elevation than a neck has. If the histogram that reports it is wrong, the
// anomaly is an artifact — and two harness bugs have already been found this week by
// asking exactly that question one step too late.
print("\n— the gaze histogram —")
do {
    var h = HeadTracker.TiltHistogram()
    for v in [-80.0, -40, 0, 0, 0, 40, 80] { h.add(v) }
    check(abs(h.lowest - -80) < 0.001, "keeps the lowest gaze it saw",
          String(format: "%.1f", h.lowest))
    check(abs(h.highest - 80) < 0.001, "and the highest",
          String(format: "%.1f", h.highest))
    check(abs(h.median) <= 2.5, "and finds the middle of a symmetric spread",
          String(format: "median %.1f", h.median))

    // The distinction the whole thing exists to draw: a head that sat craned upward
    // must not read the same as one that was level and glanced up once.
    var craned = HeadTracker.TiltHistogram()
    for _ in 0..<100 { craned.add(78) }
    craned.add(-5)
    var level = HeadTracker.TiltHistogram()
    for _ in 0..<100 { level.add(2) }
    level.add(78)
    check(craned.median > 70, "a head held craned reads as craned",
          String(format: "median %.0f", craned.median))
    check(abs(level.median) < 10, "a level head that glanced up once does not",
          String(format: "median %.0f, high %.0f", level.median, level.highest))
    check(abs(craned.highest - level.highest) < 0.001,
          "though both report the same extreme — which is why the peak alone could not tell them apart")

    // Saturation, since real gaze reaches the ends.
    var ends = HeadTracker.TiltHistogram()
    ends.add(-90); ends.add(90)
    check(ends.lowest == -90 && ends.highest == 90, "the poles land in range, not out of bounds")

    var empty = HeadTracker.TiltHistogram()
    check(empty.isEmpty && empty.median == 0, "an empty window reports nothing rather than a spurious zero")
    empty.add(30)
    empty.reset()
    check(empty.isEmpty, "and a drained one is genuinely empty")
}

print(fails == 0 ? "\nAll checks passed.\n" : "\n\(fails) FAILED\n")
exit(fails == 0 ? 0 : 1)
