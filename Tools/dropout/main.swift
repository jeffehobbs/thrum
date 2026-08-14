import Foundation
import AVFoundation
import Accelerate

// Does a drone voice ever just stop?
//
// The listener's question, and the one nobody had asked: "can't we look at the
// synth drone tone volume/amplitude signal and look for sudden drops to zero?"
//
// Everything before this looked *downstream* of the engine — the sixteen HRTFs, the
// environment node, the pull pattern, the head-tracking transport, the audio session
// — on the reasoning that the engine cannot be at fault because it never sees the
// head, so it cannot produce a head-correlated symptom. That reasoning is sound and
// it is also not a measurement. The engine's own output had never been examined for
// the thing actually being reported.
//
// And there is a specific reason to look here rather than to keep looking at
// geometry. The 08-13 flight log says the audio left the app intact for forty-two
// minutes: `gaps 0` and `overruns 0` on all 84 heartbeats. That does not mean the
// audio was *correct* — `gaps` counts output cycles the app failed to fill, and a
// cycle filled perfectly on time with a voice missing from it is not a gap. A voice
// that stops is exactly the fault that a clean flight log cannot see.
//
// Two signals, because they answer different halves:
//
//  1. **Per-bus RMS**, block by block. This is the true instantaneous amplitude of
//     what the engine hands the HRTFs — the literal "drone tone volume signal". A
//     sudden drop to zero here is the symptom, in the place the symptom is claimed
//     to be, with no head, no Bluetooth and no Apple code anywhere near it.
//  2. **Per-voice meters**, which say *which* voice. `meters` is a peak-with-slow-
//     release updated once per 64-sample control chunk and falling at 0.015 a chunk,
//     so it cannot drop faster than ~89 ms — that is a floor on how abrupt a fall can
//     look here, not a claim about how abrupt the real one is. Its value is
//     attribution: the bus says something went quiet, the meter says who.
//
// Flow is deterministic and the engine renders far faster than realtime, so this can
// simply run for hours of simulated walking and look.
//
//   swiftc -O -o /tmp/thrumdropout \
//     Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Spatial,AudioRoute,Flow,Taste,Pulse,ThrumModel}.swift \
//     Tools/dropout/*.swift
//   /tmp/thrumdropout [hours]

let sr = 48000.0
let block = 512
let buses = DroneEngine.spatialBusCount
let voices = DroneEngine.voiceCount
/// Seconds per rendered block — also how far Flow's clock is advanced each time, so
/// the music and the audio stay on the same clock.
let step = Double(block) / sr

func fbuf(_ n: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
    p.initialize(repeating: 0, count: n)
    return p
}

/// One bus going quiet and coming back.
struct Dropout {
    var bus: Int
    var at: Double          // seconds into the run
    var duration: Double
    var from: Float         // dB before
    var to: Float           // dB at the bottom
    var voices: [Int]       // which voices were sounding on that bus beforehand
}

@MainActor
func run(hours: Double) {
    let engine = DroneEngine()
    engine.setSampleRate(sr)
    let model = ThrumModel(engine: engine)
    model.spatialEnabled = true
    engine.spatialEnabled = true
    model.flow.picksKeyOnStart = true
    model.flow.start()

    let scratch = fbuf(block)
    defer { scratch.deallocate() }

    let blocks = Int(hours * 3600 / step)
    // Per-bus level history, in dB, one sample per block (10.7 ms).
    var level = [[Float]](repeating: [], count: buses)
    var meterAt = [[Float]](repeating: [], count: buses)   // loudest voice meter on that bus
    var busVoices = [[Int]](repeating: [], count: buses)
    for v in 0..<voices { busVoices[DroneEngine.bus(pad: v)].append(v) }

    for i in 0..<blocks {
        model.flow.advance(by: step)
        engine.renderSpatial(frameCount: block)
        for b in 0..<buses {
            engine.copyBus(b, block, into: scratch)
            var rms: Float = 0
            vDSP_measqv(scratch, 1, &rms, vDSP_Length(block))
            level[b].append(10 * log10(max(rms, 1e-12)))
            meterAt[b].append(busVoices[b].map { engine.meters[$0] }.max() ?? 0)
        }
        if i % (blocks / 10) == 0 {
            print("  … \(i * 100 / blocks)%", terminator: "\r")
            fflush(stdout)
        }
    }

    report(level: level, meters: meterAt, busVoices: busVoices, hours: hours)
}

/// A dropout is a bus that was clearly sounding, fell close to silence, and came
/// back — as distinct from Flow letting a voice go, which falls and stays down.
///
/// Thresholds chosen to be uncontroversial rather than tuned: "clearly sounding" is
/// within 25 dB of that bus's own median while it is active, "silent" is 40 dB below
/// it, and "came back" is within ten seconds. A gesture Flow performs deliberately
/// takes its nine-second breath and does not return to the same level immediately.
func report(level: [[Float]], meters: [[Float]], busVoices: [[Int]], hours: Double) {
    print("\nDROPOUTS — \(String(format: "%.1f", hours)) simulated hours of Flow, "
          + "\(level[0].count) blocks at \(String(format: "%.1f", step * 1000)) ms\n")

    var found: [Dropout] = []
    var busiest = 0
    for b in 0..<buses {
        let track = level[b]
        let active = track.filter { $0 > -80 }
        guard active.count > 100 else { continue }
        busiest += 1
        let median = active.sorted()[active.count / 2]
        let loud = median - 25, silent = median - 40

        var i = 0
        while i < track.count {
            guard track[i] > loud else { i += 1; continue }
            // Find a fall to silence within the next ten seconds.
            var j = i + 1
            let limit = min(track.count, i + Int(10 / step))
            var bottom: Float = track[i]
            var bottomAt = i
            while j < limit, track[j] < track[i] {
                if track[j] < bottom { bottom = track[j]; bottomAt = j }
                j += 1
            }
            if bottom < silent, j < limit, track[j] > loud {
                found.append(Dropout(bus: b, at: Double(i) * step,
                                     duration: Double(j - i) * step,
                                     from: track[i], to: bottom,
                                     voices: busVoices[b]))
                i = j
            } else {
                i += 1
            }
        }
    }

    print("  \(busiest) of \(buses) buses carried audio")
    if found.isEmpty {
        print("  ok    no bus fell 40 dB and recovered — the engine's own output "
              + "never drops a tone")
    } else {
        print("  FOUND \(found.count) drop-and-recover events:")
        for d in found.sorted(by: { $0.at < $1.at }).prefix(20) {
            print(String(format: "    %6.1f s  bus %2d %-16@  %.0f → %.0f dB over %.2f s  (voices %@)",
                         d.at, d.bus, SpatialField.label(bus: d.bus) as NSString,
                         d.from, d.to, d.duration,
                         d.voices.map(String.init).joined(separator: ",") as NSString))
        }
        if found.count > 20 { print("    …and \(found.count - 20) more") }
    }

    // The blunter question, asked separately so a threshold cannot hide it: does any
    // bus ever go from audible to *digital silence* in a single block?
    var hardZeros = 0
    for b in 0..<buses {
        let t = level[b]
        for i in 1..<t.count where t[i - 1] > -60 && t[i] < -100 { hardZeros += 1 }
    }
    print(hardZeros == 0
          ? "  ok    no bus ever went from audible to silence in one block"
          : "  FOUND \(hardZeros) single-block falls from audible to silence")

    // MARK: How *sudden* is the fastest fall?
    //
    // The events above are almost certainly Flow doing its job: they last two to ten
    // seconds, which is its nine-second breath, and they start from levels already
    // 25 dB down. "Like a loose audio cable" is not that shape. What distinguishes a
    // fault from a fade is not depth but *rate*, so measure the rate directly and let
    // the distribution speak rather than a threshold.
    print("\n  fastest falls per bus (dB lost, measured over three window lengths)")
    var worstShort: (bus: Int, at: Double, db: Float) = (0, 0, 0)
    for b in 0..<buses {
        let t = level[b]
        guard t.count > 20 else { continue }
        var w = [Float](repeating: 0, count: 3)
        var at: Float = 0
        for (k, span) in [1, 3, 19].enumerated() {   // ~11 ms, ~32 ms, ~200 ms
            for i in span..<t.count where t[i - span] > -70 {
                let fall = t[i - span] - t[i]
                if fall > w[k] {
                    w[k] = fall
                    if k == 1 { at = Float(i) * Float(step) }
                }
            }
        }
        if w[1] > worstShort.db { worstShort = (b, Double(at), w[1]) }
        print(String(format: "    bus %2d %-16@  11 ms %5.1f   32 ms %5.1f   200 ms %5.1f",
                     b, SpatialField.label(bus: b) as NSString, w[0], w[1], w[2]))
    }
    print(String(format: "\n  worst 32 ms fall anywhere: %.1f dB, bus %d at %.1f s",
                 worstShort.db, worstShort.bus, worstShort.at))
    // A drone whose voices are gated and released with a multi-second envelope has no
    // business losing tens of dB in a couple of buffers. If nothing here exceeds a few
    // dB, the engine's output is smooth and the "loose cable" is not being generated
    // in this file.
    print(worstShort.db < 12
          ? "  ok    nothing in the engine's output falls abruptly — the fastest change "
            + "anywhere is a fade, not a cut"
          : "  FOUND an abrupt fall in the engine's own output — this is the symptom, "
            + "upstream of every HRTF")
}

let hours = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 2 : 2
MainActor.assumeIsolated {
    run(hours: hours)
    // And the same engine through the real spatial stage, with a head on it — see
    // tracked.swift. Shorter, because it renders sixteen HRTFs per block rather than
    // reading a buffer.
    runTracked(minutes: 10)
}
