import Foundation
import AVFoundation

// Offline checks for spatial mode. The whole point of this harness is that the
// spatial path is a *second* master chain — per-bus EQ, a wet tail extracted by
// subtraction, and one limiter shared across seventeen outputs — and none of
// that is audible as "wrong" until it is very wrong.
//
//   swiftc -O -o /tmp/thrumspatial \
//     Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine}.swift \
//     Tools/spatial/main.swift
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

print(fails == 0 ? "\nAll checks passed.\n" : "\n\(fails) FAILED\n")
exit(fails == 0 ? 0 : 1)
