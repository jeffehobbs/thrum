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

// 6. `HeadTransport` is the whole of what stands between a CoreMotion sample and
// sixteen HRTFs being re-pointed, and it has two clocks: the sensor's, which
// deposits targets, and the render cycle's, which advances the field and hands the
// node one orientation per cycle. These drive both with a synthetic head.
//
// The reason to care is a listener report — "warble when I tilt my head up and
// down, worst on the higher voices" — that survived three offline measurements of
// the render path (`Tools/warble`), was traced once to an Euler singularity
// (6a below) and once to a stall the slew limit could not reach, and left a
// structural problem behind: the field used to move on the sensor's schedule and be
// read on the audio's, with a 45 ms rate cap between them, so what the ear got was
// the head's path sampled by the beat between three unrelated timers (6c). Nothing
// here forms an Euler angle except the readout.
do {
    /// A tick rate of 1024 frames at 48 kHz — what ThrumFlow asks for while tracking.
    let tickHz = 48000.0 / 1024

    /// The transport driven by two clocks.
    struct Rig {
        var transport = HeadTransport()
        var t = 0.0
        var nextSample = 0.0, nextTick = 0.0
        let sensorDt: Double, tickDt: Double
        /// Every orientation handed to the node, in order.
        var written: [HeadOrientation] = []
        /// Where the field stood at each tick, whether or not it was written.
        var held: [HeadOrientation] = []

        init(sensorHz: Double = 50, tickHz: Double) {
            sensorDt = 1 / sensorHz; tickDt = 1 / tickHz
        }

        /// What a real sensor reports: gravity in the device frame, for an attitude
        /// whose world is z-up.
        static func gravity(for attitude: simd_quatd) -> simd_double3 {
            attitude.inverse.act(simd_double3(0, 0, -1))
        }

        /// Run for `seconds` with the head at `head(t)`; `sensing: false` is a stall.
        mutating func run(_ seconds: Double, sensing: Bool = true, head: (Double) -> simd_quatd) {
            let until = t + seconds
            while t < until {
                if sensing, nextSample <= nextTick {
                    t = nextSample
                    let att = head(t)
                    transport.ingest(attitude: att, gravity: Self.gravity(for: att), at: t)
                    nextSample += sensorDt
                } else {
                    t = nextTick
                    if !sensing { nextSample = max(nextSample, t + sensorDt) }
                    if let out = transport.advance(to: t) { written.append(out) }
                    held.append(transport.orientation)
                    nextTick += tickDt
                }
            }
        }

        mutating func run(_ seconds: Double, sensing: Bool = true,
                          yaw: Double, pitch: Double = 0, roll: Double = 0) {
            run(seconds, sensing: sensing) { _ in HeadMath.rotation(yaw: yaw, pitch: pitch, roll: roll) }
        }
    }

    /// How far the field turned between two orientations, in degrees, measured on
    /// the vectors the node is driven with rather than on Euler angles — the whole
    /// 6a bug was an Euler angle moving 168° while the rotation moved a fraction of
    /// a degree, and a test that measured angles would have called the fix broken.
    func fieldStep(_ a: HeadOrientation, _ b: HeadOrientation) -> Double { b.separation(from: a) }
    func biggestStep(_ v: [HeadOrientation]) -> Double {
        var worst = 0.0
        for i in 1..<max(1, v.count) { worst = max(worst, fieldStep(v[i - 1], v[i])) }
        return worst
    }

    // An ordinary nod: ±20° at 0.4 Hz, which is looking down at the phone and back.
    // Nothing here should ever engage the limit — if it did, the limit would be a
    // tone control rather than a guard.
    var nod = Rig(tickHz: tickHz)
    nod.run(8) { t in HeadMath.rotation(yaw: 0, pitch: 20 * sin(2 * .pi * 0.4 * t), roll: 0) }
    let nodded = nod.transport.drainDiagnostics()
    check(nodded.clampedTicks == 0, "an ordinary nod is never rate-limited",
          "peak input \(Int(nodded.peakRate))°/s")
    // The rate the recorder reports has to be the head's, not the smoother's lag —
    // it is the one number that says whether a stream is physically possible, and it
    // is useless if ordinary movement already reads as impossible. A ±20° nod at
    // 0.4 Hz peaks at 2π·0.4·20 ≈ 50°/s.
    check(nodded.peakRate > 40 && nodded.peakRate < 60,
          "and the rate it reports is the head's own, not the tracking error",
          String(format: "%.0f°/s for a nod that peaks at 50", nodded.peakRate))
    check(biggestStep(nod.written) < 2, "and moves the field in small steps",
          String(format: "largest %.2f° per cycle", biggestStep(nod.written)))
    check(nodded.writes <= nod.held.count && nodded.writes > nod.held.count / 2,
          "the node is written once per render cycle at most, whatever the sensor does",
          "\(nodded.samples) samples in, \(nodded.writes) writes out of \(nod.held.count) cycles over 8 s")

    // A fast deliberate turn — 300°/s, faster than anyone looks around — still must
    // not be limited, or the field lags the head exactly when it is most obvious.
    var fast = Rig(tickHz: tickHz)
    fast.run(1.6) { t in HeadMath.rotation(yaw: 300 * t, pitch: 0, roll: 0) }
    check(fast.transport.drainDiagnostics().clampedTicks == 0, "so is a 300°/s turn of the head")

    // 6b. A stall in the motion stream, which the 08-15 flight log has 32 of, the
    // worst 2.0 s long — and `clamped 0` on every heartbeat while they happened.
    //
    // The head keeps moving while the stream is quiet, so the first sample back
    // carries the whole movement at once. The old smoother was stepped per sample and
    // both its terms scaled with the interval, which relaxed them precisely when they
    // were needed: at a 1.3 s gap the one-pole's fraction reached 1.000 and the
    // limiter's allowance 520°, so 40° landed on sixteen HRTFs in one frame and the
    // guard correctly reported nothing. Now the smoother is stepped by the render
    // clock, so a stall is just a target that stopped changing and then jumped — the
    // same thing as a fast head, and handled the same way.
    //
    // The control is the point: the same 40° arriving as an ordinary sample-to-sample
    // step, so the two runs differ only in the gap.
    func afterGap(stalled: Bool) -> (step: Double, arrived: Double, stalls: Int) {
        var rig = Rig(tickHz: tickHz)
        rig.run(1, yaw: 0)
        _ = rig.transport.drainDiagnostics()
        let before = rig.written.count
        if stalled { rig.run(2, sensing: false, yaw: 0) }
        rig.run(0.8, yaw: 40)
        let after = Array(rig.written[max(0, before - 1)...])
        return (biggestStep(after), rig.transport.orientation.yaw, rig.transport.drainDiagnostics().stalls)
    }
    let stalled = afterGap(stalled: true), brief = afterGap(stalled: false)
    check(stalled.stalls == 1 && brief.stalls == 0, "a 2 s stall is counted as one",
          "\(stalled.stalls) with the gap, \(brief.stalls) without")
    check(stalled.step <= brief.step * 1.05 + 0.01,
          "and moves the field no harder than the same movement arriving on time",
          String(format: "%.2f° per cycle after the gap, vs %.2f° with no gap", stalled.step, brief.step))
    check(stalled.step <= HeadSmoother.maxDegreesPerSecond / tickHz + 0.001,
          "inside the slew limit, which can now reach it",
          String(format: "%.2f° in one cycle, against 40° of head movement", stalled.step))
    // The field must still get there — easing must not become ignoring.
    check(abs(stalled.arrived - 40) < 2,
          "and the field arrives where the head went, within a second of the stream returning",
          String(format: "%.1f° of 40 after 0.8 s", stalled.arrived))

    // The bug the quaternion fixed first. Roll used to get neither the wrap nor the
    // shortest way round, so a head tilted far enough to take CoreMotion's roll from
    // +179° to −179° handed the one-pole a 358° error and it set off the long way,
    // sweeping the whole field through every azimuth to a destination 2° away.
    var held = Rig(tickHz: tickHz)
    held.run(3, yaw: 0, roll: 179)
    check(abs(held.transport.orientation.roll - 179) < 1, "roll settles where it was told to",
          String(format: "%.1f°", held.transport.orientation.roll))
    let before = held.written.count
    held.run(1.6, yaw: 0, roll: -179)
    var travelled = 0.0
    for i in before..<held.written.count { travelled += fieldStep(held.written[i - 1], held.written[i]) }
    check(travelled < 10, "and crossing ±180° takes the short way, not 358° of field",
          String(format: "travelled %.1f°", travelled))

    // Any discontinuity at all — a re-seated reference, a resumed Bluetooth batch —
    // is spread over several cycles instead of arriving as one event.
    var jumped = Rig(tickHz: tickHz)
    jumped.run(2, yaw: 0)
    let mark = jumped.written.count
    jumped.run(1.6, yaw: 0, pitch: 90)
    let glide = biggestStep(Array(jumped.written[(mark - 1)...]))
    check(glide <= HeadSmoother.maxDegreesPerSecond / tickHz + 0.001,
          "a 90° step is delivered as a glide, not a lurch",
          String(format: "largest %.1f° per cycle, was %.1f before the limit",
                 glide, 90 * HeadSmoother.coefficient(for: 1 / tickHz)))
    check(abs(jumped.transport.orientation.pitch - 90) < 5, "and still arrives",
          String(format: "%.1f°", jumped.transport.orientation.pitch))

    // The smoothing has to be a *time*, not a per-sample coefficient — and now that
    // the render clock steps it, the sensor's rate cannot enter at all. Same head,
    // same wall-clock, two sensor rates: the field must be in the same place.
    func settle(sensorHz: Double) -> Double {
        var rig = Rig(sensorHz: sensorHz, tickHz: tickHz)
        rig.run(0.5, yaw: 30)
        return rig.transport.orientation.yaw
    }
    let at25 = settle(sensorHz: 25), at50 = settle(sensorHz: 50)
    check(abs(at25 - at50) < 0.5,
          "smoothing is a time constant, so the sensor's rate can't change the feel",
          String(format: "%.2f° at 25 Hz vs %.2f° at 50 Hz", at25, at50))
    check(abs(HeadSmoother.coefficient(for: 0.04) - 0.28) < 0.005,
          "and 25 Hz still gets exactly the coefficient it was tuned with",
          String(format: "%.3f", HeadSmoother.coefficient(for: 0.04)))

    // 6c. Two clocks, one field. The reason for the rewrite, measured.
    //
    // The old chain: smooth on every sensor sample, write to the node at most every
    // 45 ms, and let the render cycle pick up whatever was written last. At 50 Hz
    // samples, a 45 ms cap and 21 ms cycles, a head turning steadily at 100°/s
    // reaches the node as a stutter — cycles in which the field does not move at all
    // alternating with cycles in which it jumps three cycles' worth. Per the house
    // rule, that is reconstructed first so the assertion below means something.
    let turn: (Double) -> simd_quatd = { t in HeadMath.rotation(yaw: 100 * t, pitch: 0, roll: 0) }
    var oldSmoother = HeadSmoother()
    var oldWritten = HeadMath.identity
    var oldHeld: [HeadOrientation] = []
    do {
        var t = 0.0, nextSample = 0.0, nextTick = 0.0, lastWrite = -1.0
        while t < 4 {
            if nextSample <= nextTick {
                t = nextSample
                _ = oldSmoother.step(toward: turn(t), dt: 0.02)
                if lastWrite < 0 || t - lastWrite >= 0.045 { oldWritten = oldSmoother.current; lastWrite = t }
                nextSample += 0.02
            } else {
                t = nextTick
                oldHeld.append(HeadMath.orientation(oldWritten))
                nextTick += 1 / tickHz
            }
        }
    }
    var newRig = Rig(tickHz: tickHz)
    newRig.run(4, head: turn)
    /// After the first second, so the one-pole has settled onto the ramp.
    func steps(_ held: [HeadOrientation]) -> [Double] {
        let settled = Array(held.dropFirst(Int(tickHz)))
        return (1..<settled.count).map { fieldStep(settled[$0 - 1], settled[$0]) }
    }
    let oldSteps = steps(oldHeld), newSteps = steps(newRig.held)
    let oldFrozen = Double(oldSteps.filter { $0 < 0.01 }.count) / Double(oldSteps.count)
    let newFrozen = Double(newSteps.filter { $0 < 0.01 }.count) / Double(newSteps.count)
    let ideal = 100 / tickHz
    check(oldFrozen > 0.3 && (oldSteps.max() ?? 0) > ideal * 2,
          "the old chain really did stutter (so the checks below mean something)",
          String(format: "field frozen on %.0f%% of cycles, then jumping %.1f° where a cycle's worth is %.1f°",
                 oldFrozen * 100, oldSteps.max() ?? 0, ideal))
    check(newFrozen == 0 && (newSteps.max() ?? 0) < ideal * 1.3,
          "the field now moves every cycle, by about a cycle's worth",
          String(format: "frozen on %.0f%% of cycles, largest step %.2f° against %.2f° ideal, smallest %.2f°",
                 newFrozen * 100, newSteps.max() ?? 0, ideal, newSteps.min() ?? 0))

    // A still head. AirPods at rest jitter by a few tenths of a degree at 50 Hz, and
    // every one of those used to be a candidate write. The one-pole takes most of it
    // out and the dead band the rest — `Tools/handover` measured what remains as
    // inaudible against a listener who never moves — so a still head should cost
    // the graph a fraction of the writes a moving one does.
    var seed = 99.0
    func noise() -> Double {
        seed = (seed * 1103515245 + 12345).truncatingRemainder(dividingBy: 2147483648)
        let u1 = max(seed / 2147483648, 1e-9)
        seed = (seed * 1103515245 + 12345).truncatingRemainder(dividingBy: 2147483648)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * seed / 2147483648)
    }
    var still = Rig(tickHz: tickHz)
    still.run(1, yaw: 12, pitch: -8)
    _ = still.transport.drainDiagnostics()
    still.run(8) { _ in HeadMath.rotation(yaw: 12 + 0.3 * noise(), pitch: -8 + 0.3 * noise(), roll: 0) }
    let jitter = still.transport.drainDiagnostics()
    let ticks = Int(8 * tickHz)
    check(jitter.writes < ticks / 2,
          "a still head with 0.3° of sensor jitter writes on well under half its cycles",
          "\(jitter.writes) writes in \(ticks) cycles, from \(jitter.samples) samples")

    // Recenter is the one deliberate snap in the transport: the field goes to dead
    // ahead on the very next cycle and glides from there to the head's true tilt,
    // with the heading re-seated so "ahead" is now wherever the head points.
    var centred = Rig(tickHz: tickHz)
    centred.run(2, yaw: 60)                         // seeds the heading at 60°
    centred.run(2, yaw: 90, pitch: 20)              // a held 30° turn, looking up
    check(abs(centred.transport.orientation.yaw - 30) < 2,
          "before recenter the field has followed a held 30° turn",
          String(format: "%.1f°", centred.transport.orientation.yaw))
    centred.transport.recenter()
    let count = centred.written.count
    centred.run(0.05, yaw: 90, pitch: 20)
    let first = centred.written[count]
    check(first.separation(from: .identity) < 0.001, "recenter snaps to dead ahead on the next cycle",
          String(format: "%.4f° from identity", first.separation(from: .identity)))
    centred.run(2, yaw: 90, pitch: 20)
    check(abs(centred.transport.orientation.yaw) < 1 && abs(centred.transport.orientation.pitch - 20) < 1,
          "and settles with the head's heading as forward and its true tilt kept",
          String(format: "yaw %.1f°, pitch %.1f° of the head's 20°",
                 centred.transport.orientation.yaw, centred.transport.orientation.pitch))

    // 6a. The hike bug: relative pitch crossing vertical.
    //
    // A smooth physical rotation carrying the head through pitch = 90° — which is
    // what an ordinary nod did once the reference was captured while looking down at
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
    for i in 1..<crossing.count { trueTravel += HeadMath.angle(crossing[i - 1], crossing[i]) }
    let eulers = crossing.map { HeadMath.euler($0) }
    var rawJump = 0.0
    for i in 1..<eulers.count {
        rawJump = max(rawJump, abs(HeadMath.wrap(eulers[i].yaw - eulers[i - 1].yaw)))
        rawJump = max(rawJump, abs(HeadMath.wrap(eulers[i].roll - eulers[i - 1].roll)))
    }
    check(trueTravel < 70 && rawJump > 100,
          "the trajectory really does contain the bug (so the checks below mean something)",
          String(format: "head turns %.0f° in total, its Euler angles jump %.0f° in one sample",
                 trueTravel, rawJump))

    // Now the fix. Both routes have to survive it: the quaternion the app uses, and
    // CMAttitude's own angles recomposed in its Z-X-Y order — because recomposing
    // *cancels* the degenerate split rather than inheriting it, and that is the
    // load-bearing claim of carrying a rotation.
    //
    // Fed *absolutely* — the whole point of the 08-21 reference is that a head which
    // really does cross vertical is the only way pitch reaches 90° now — through a
    // sensor at 25 Hz, which is what the trajectory was sampled at.
    for (name, viaEuler) in [("quaternion", false), ("Euler round-trip", true)] {
        var rig = Rig(sensorHz: 25, tickHz: tickHz)
        // Settle on the starting attitude first. Without this the measurement is
        // dominated by the smoother gliding in from identity to a head already tilted
        // 60°, which is a legitimate rate-limited arrival and not what is under test.
        rig.run(3) { _ in crossing[0] }
        _ = rig.transport.drainDiagnostics()
        let mark = rig.written.count
        rig.run(Double(crossing.count) * 0.04) { t in
            let i = min(crossing.count - 1, Int((t - 3) / 0.04 + 1e-9))
            if viaEuler {
                let e = eulers[i]
                return HeadMath.rotation(yaw: e.yaw, pitch: e.pitch, roll: e.roll)
            }
            return crossing[i]
        }
        let d = rig.transport.drainDiagnostics()
        check(d.clampedTicks == 0 && d.peakRate < 200,
              "crossing vertical is not a discontinuity — \(name)",
              String(format: "%d cycles limited, peak rate %.0f°/s (was 8352 on the hike)",
                     d.clampedTicks, d.peakRate))
        let steps = biggestStep(Array(rig.written[max(0, mark - 1)...]))
        check(steps < 3, "and the field turns in small steps through it — \(name)",
              String(format: "largest %.2f° per cycle", steps))
    }

    // 6d. The rewrite must not have moved the field.
    //
    // The reason this is safe to ship into a notarized Mac app whose spatial image was
    // tuned by ear: driving `listenerVectorOrientation` from a conjugated quaternion has
    // to be *identical* to the `(-yaw, -pitch, -roll)` angular path it replaces. Rather
    // than argue that from Apple's documentation, ask the node — setting an angular
    // orientation and reading the vector one back makes it state its own mapping.
    let env = AVAudioEnvironmentNode()
    var worstVector = 0.0
    var rseed = 12345.0
    func rnd() -> Double {
        rseed = (rseed * 1103515245 + 12345).truncatingRemainder(dividingBy: 2147483648)
        return rseed / 2147483648
    }
    for _ in 0..<400 {
        // Away from ±90° pitch, where the path being replaced was meaningful at all.
        let y = (rnd() * 2 - 1) * 170, p = (rnd() * 2 - 1) * 60, r = (rnd() * 2 - 1) * 170
        env.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: Float(-y), pitch: Float(-p), roll: Float(-r))
        let shipped = env.listenerVectorOrientation
        let ours = HeadMath.listener(HeadMath.rotation(yaw: y, pitch: p, roll: r))
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
    var h = HeadTransport.TiltHistogram()
    for v in [-80.0, -40, 0, 0, 0, 40, 80] { h.add(v) }
    check(abs(h.lowest - -80) < 0.001, "keeps the lowest gaze it saw",
          String(format: "%.1f", h.lowest))
    check(abs(h.highest - 80) < 0.001, "and the highest",
          String(format: "%.1f", h.highest))
    check(abs(h.median) <= 2.5, "and finds the middle of a symmetric spread",
          String(format: "median %.1f", h.median))

    // The distinction the whole thing exists to draw: a head that sat craned upward
    // must not read the same as one that was level and glanced up once.
    var craned = HeadTransport.TiltHistogram()
    for _ in 0..<100 { craned.add(78) }
    craned.add(-5)
    var level = HeadTransport.TiltHistogram()
    for _ in 0..<100 { level.add(2) }
    level.add(78)
    check(craned.median > 70, "a head held craned reads as craned",
          String(format: "median %.0f", craned.median))
    check(abs(level.median) < 10, "a level head that glanced up once does not",
          String(format: "median %.0f, high %.0f", level.median, level.highest))
    check(abs(craned.highest - level.highest) < 0.001,
          "though both report the same extreme — which is why the peak alone could not tell them apart")

    // Saturation, since real gaze reaches the ends.
    var ends = HeadTransport.TiltHistogram()
    ends.add(-90); ends.add(90)
    check(ends.lowest == -90 && ends.highest == 90, "the poles land in range, not out of bounds")

    var empty = HeadTransport.TiltHistogram()
    check(empty.isEmpty && empty.median == 0, "an empty window reports nothing rather than a spurious zero")
    empty.add(30)
    empty.reset()
    check(empty.isEmpty, "and a drained one is genuinely empty")
}

print(fails == 0 ? "\nAll checks passed.\n" : "\n\(fails) FAILED\n")
exit(fails == 0 ? 0 : 1)
