import Foundation
import AVFoundation

// Offline checks for the arpeggiator. Renders the engine faster than realtime
// and asserts on what actually comes out of it.
//
//   swiftc -O -o /tmp/thrumpulse \
//     Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Pulse}.swift \
//     Tools/pulse/main.swift
//   /tmp/thrumpulse
//
// Build it -O like the app. The engine is ~40× slower at -Onone and the
// realtime section of this harness assumes it can keep up.
//
// One trap worth knowing: the drone's own tremolo and filter run on prime
// periods, so its level is never still. Asking "did the accent disturb the
// drone" only means anything against a control run of the identical timeline
// with no accent in it, which is what the second test does.

let sr = 48000.0
let block = 512

func makeABL(_ n: Int) -> (UnsafeMutablePointer<AudioBufferList>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) {
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: n)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: n)
    l.initialize(repeating: 0, count: n)
    r.initialize(repeating: 0, count: n)
    abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(l))
    abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(r))
    return (abl.unsafeMutablePointer, l, r)
}

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

/// Render `seconds` and return (peak, rms) plus a per-block peak trace.
func run(_ engine: DroneEngine, seconds: Double,
         at: [(Double, () -> Void)] = []) -> (peak: Float, rms: Float, trace: [Float]) {
    let (abl, l, r) = makeABL(block)
    defer { l.deallocate(); r.deallocate() }
    var t = 0.0
    var peak: Float = 0
    var sum: Double = 0
    var count = 0
    var trace: [Float] = []
    var pending = at
    while t < seconds {
        while let first = pending.first, first.0 <= t {
            first.1()
            pending.removeFirst()
        }
        engine.render(frameCount: block, out: abl)
        var bp: Float = 0
        for i in 0..<block {
            let m = max(abs(l[i]), abs(r[i]))
            if m > bp { bp = m }
            sum += Double(l[i]) * Double(l[i])
            count += 1
        }
        trace.append(bp)
        if bp > peak { peak = bp }
        t += Double(block) / sr
    }
    return (peak, Float((sum / Double(max(1, count))).squareRoot()), trace)
}

print("\n— accent envelope —")

// 1. A pluck on a voice that is not being held should sound, then go silent.
do {
    let e = DroneEngine()
    e.setSampleRate(sr)
    e.reverbMix = 0            // dry, so "silent" means silent
    e.pluckAttack = 0.02
    e.pluckDecay = 0.5
    e.retune(pad: 0, frequency: 220)
    let out = run(e, seconds: 3.0, at: [(0.2, { e.pluck(pad: 0, velocity: 0.9) })])
    check(out.peak > 0.05, "ungated pluck makes sound", String(format: "peak %.3f", out.peak))
    let tail = out.trace.suffix(20).max() ?? 0
    check(tail < 1e-3, "and falls back to silence", String(format: "tail %.6f", tail))
    check(e.activeVoices == 0, "voice released itself", "active \(e.activeVoices)")
}

// 2. A pluck on a HELD voice must ride on top of the drone, not replace it and
//    not cut it off. This is the whole point of the feature.
do {
    // The drone's own tremolo and filter sweep move its level around on
    // prime-numbered periods, so "did the pluck disturb it" has to be asked
    // against a control run of the identical timeline with no pluck in it.
    func trial(pluck: Bool) -> (settled: Float, struck: Float, active: Int32) {
        let e = DroneEngine()
        e.setSampleRate(sr)
        e.reverbMix = 0
        e.swellSeconds = 0.5
        e.pluckAttack = 0.02
        e.pluckDecay = 0.4
        e.retune(pad: 0, frequency: 220)
        e.setLevel(pad: 0, level: 0.5)
        e.gate(pad: 0, on: true)
        _ = run(e, seconds: 2.0)
        let hit = run(e, seconds: 0.5, at: pluck ? [(0.02, { e.pluck(pad: 0, velocity: 0.8) })] : [])
        let after = run(e, seconds: 1.5)
        return (after.trace.suffix(5).min()!, hit.peak, e.activeVoices)
    }
    let control = trial(pluck: false)
    let plucked = trial(pluck: true)

    check(plucked.struck > control.struck * 1.3, "accent rises above the held drone",
          String(format: "drone %.3f → struck %.3f", control.struck, plucked.struck))
    check(abs(plucked.settled - control.settled) < control.settled * 0.02,
          "and the drone underneath is untouched once it has rung out",
          String(format: "%.4f with vs %.4f without", plucked.settled, control.settled))
    check(plucked.active == 1, "voice still gated", "active \(plucked.active)")
}

// 3. Strike time should follow the Strike parameter.
do {
    for (atk, label) in [(0.005, "5 ms"), (0.2, "200 ms")] {
        let e = DroneEngine()
        e.setSampleRate(sr)
        e.reverbMix = 0
        e.pluckAttack = atk
        e.pluckDecay = 2.0
        e.retune(pad: 3, frequency: 330)
        let out = run(e, seconds: 1.0, at: [(0.0, { e.pluck(pad: 3, velocity: 0.9) })])
        // Blocks are ~10.7 ms; find the first block at 90% of peak.
        let target = out.peak * 0.9
        let idx = out.trace.firstIndex { $0 >= target } ?? out.trace.count
        let rise = Double(idx) * Double(block) / sr
        let expectedMax = atk * 3 + 0.03
        check(rise <= expectedMax, "strike \(label) reaches full in time",
              String(format: "%.0f ms (limit %.0f ms)", rise * 1000, expectedMax * 1000))
    }
}

// 4. Ring time should follow the Ring parameter.
do {
    for (dec, label) in [(0.15, "0.15 s"), (2.0, "2.0 s")] {
        let e = DroneEngine()
        e.setSampleRate(sr)
        e.reverbMix = 0
        e.pluckAttack = 0.01
        e.pluckDecay = dec
        e.retune(pad: 5, frequency: 200)
        let out = run(e, seconds: 6.0, at: [(0.0, { e.pluck(pad: 5, velocity: 0.9) })])
        let floorLevel = out.peak * 0.001
        var last = 0
        for (i, v) in out.trace.enumerated() where v > floorLevel { last = i }
        let ring = Double(last) * Double(block) / sr
        check(abs(ring - dec) < dec * 0.6 + 0.08, "ring \(label) lasts about that long",
              String(format: "%.2f s", ring))
    }
}

print("\n— the clock —")

// 5. Run the real PulseCore against the real engine for two seconds of wall
//    clock and count the notes that actually landed.
do {
    let e = DroneEngine()
    e.setSampleRate(sr)
    e.reverbMix = 0
    e.pluckAttack = 0.01
    e.pluckDecay = 0.12
    for p in 0..<8 { e.retune(pad: p, frequency: 200 * pow(2, Double(p) / 12)) }

    let core = PulseCore(engine: e)
    var lane = PulseCore.PlanLane()
    lane.enabled = true
    lane.pads = [0, 1, 2, 3]
    lane.perBeat = 2          // eighths
    lane.pattern = .up
    lane.level = 1.0
    lane.accentEvery = 1
    core.update(lanes: [lane, PulseCore.PlanLane(), PulseCore.PlanLane(), PulseCore.PlanLane()])
    core.setFeel(swing: 0, humanize: 0, level: 1.0)
    core.setTempo(120)        // 120 bpm × 2 per beat = 4 notes a second
    core.realign()
    core.setRunning(true)

    // Render in realtime-ish so the clock and the audio agree.
    let (abl, l, r) = makeABL(block)
    defer { l.deallocate(); r.deallocate() }
    let startWall = Date()
    var strikes = 0
    var wasQuiet = true
    var rendered = 0.0
    while Date().timeIntervalSince(startWall) < 2.05 {
        let want = Date().timeIntervalSince(startWall)
        while rendered < want {
            e.render(frameCount: block, out: abl)
            var bp: Float = 0
            for i in 0..<block { bp = max(bp, abs(l[i])) }
            if bp > 0.02 && wasQuiet { strikes += 1; wasQuiet = false }
            if bp < 0.005 { wasQuiet = true }
            rendered += Double(block) / sr
        }
        usleep(1000)
    }
    core.stop()
    // 2 s at 4 notes/s ≈ 8, give or take the edges.
    check(strikes >= 6 && strikes <= 10, "clock fired ~8 notes in 2 s at 120 bpm ×2",
          "counted \(strikes)")
    check(abs(core.displayBeat - 4.0) < 0.35, "and advanced ~4 beats",
          String(format: "%.2f", core.displayBeat))
}

print("\n— patterns —")

// 6. Every pattern that claims to cover the set must actually cover it.
do {
    let n = 5
    for p in ArpPattern.allCases where p != .scatter && p != .chord {
        var seen = Set<Int>()
        for s in 0..<(4 * n) { seen.insert(p.index(step: s, count: n, seed: 0)) }
        check(seen == Set(0..<n), "\(p.rawValue) covers all \(n)", "hit \(seen.sorted())")
    }
    // And nothing may ever index out of bounds, at any size.
    var bad = 0
    for p in ArpPattern.allCases {
        for n in 1...32 {
            for s in 0..<200 {
                let i = p.index(step: s, count: n, seed: 3)
                if i < 0 || i >= n { bad += 1 }
            }
        }
    }
    check(bad == 0, "no pattern indexes out of range", "\(bad) violations")
}

print(failures == 0 ? "\nAll checks passed.\n" : "\n\(failures) FAILED\n")
exit(failures == 0 ? 0 : 1)
