import Foundation
import AVFoundation

// What does Flow actually cost, and how much of it can a human hear?
//
//   swiftc -O -o /tmp/thrumbudget \
//     Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Pulse,Spatial,ThrumModel,Flow}.swift \
//     Tools/budget/main.swift
//   /tmp/thrumbudget [minutes]
//
// This exists because the iOS build has to decide what to cut, and cutting by
// guesswork is how a drone instrument ends up thinner for no measured reason.
// Flow drives itself, so its load is a fact to be measured rather than a design
// parameter — and the interesting number is not how many voices are *active* but
// how many are loud enough to be heard alongside the others.
//
// Renders real audio (Flow's envelopes only move in the render loop) and advances
// the director in step with rendered time, so an hour of drone compresses into
// under a minute of wall clock.

let minutes = Double(CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 20 : 20)
let sr = 48000.0
let block = 512

@MainActor
func run() {
    let engine = DroneEngine()
    engine.setSampleRate(sr)
    let model = ThrumModel(engine: engine)

    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { bufL.deallocate(); bufR.deallocate(); free(abl.unsafeMutablePointer) }
    abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: bufL)
    abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: bufR)

    // Spatial is the one feature whose cost is worth knowing separately: it adds
    // 16 HRTF instances and a second master chain, and on a phone that is a
    // battery decision rather than a taste one.
    let spatial = CommandLine.arguments.contains("spatial")
    if spatial { model.spatialEnabled = true }

    model.flow.start()

    let blockSeconds = Double(block) / sr
    let blocks = Int(minutes * 60 / blockSeconds)

    var activeHist = [Int](repeating: 0, count: DroneEngine.voiceCount + 1)
    // Audible = within N dB of the loudest sounding voice. Anything quieter is
    // sitting under the others in a spectrum they already share.
    var audibleHist40 = [Int](repeating: 0, count: DroneEngine.voiceCount + 1)
    var audibleHist30 = [Int](repeating: 0, count: DroneEngine.voiceCount + 1)
    var audibleHist20 = [Int](repeating: 0, count: DroneEngine.voiceCount + 1)
    var samples = 0
    var peakActive = 0

    let startWall = Date()
    for b in 0..<blocks {
        if spatial {
            // Mirrors what the 17 source-node callbacks do in the live graph.
            engine.renderSpatial(frameCount: block)
            for bus in 0..<DroneEngine.spatialBusCount { engine.copyBus(bus, block, into: bufL) }
            engine.copyWet(block, bufL, bufR)
        } else {
            engine.render(frameCount: block, out: abl.unsafeMutablePointer)
        }
        model.flow.advance(by: blockSeconds)

        // Sample a few times a second; no need for every block.
        if b % 20 == 0 {
            let active = Int(engine.activeVoices)
            activeHist[min(active, DroneEngine.voiceCount)] += 1
            peakActive = max(peakActive, active)

            var loudest: Float = 0
            for v in 0..<DroneEngine.voiceCount { loudest = max(loudest, engine.meters[v]) }
            if loudest > 0 {
                for (i, dB) in [40.0, 30.0, 20.0].enumerated() {
                    let floorLevel = loudest * Float(pow(10.0, -dB / 20.0))
                    var n = 0
                    for v in 0..<DroneEngine.voiceCount where engine.meters[v] > floorLevel { n += 1 }
                    switch i {
                    case 0: audibleHist40[n] += 1
                    case 1: audibleHist30[n] += 1
                    default: audibleHist20[n] += 1
                    }
                }
            }
            samples += 1
        }
    }
    let wall = Date().timeIntervalSince(startWall)

    func report(_ name: String, _ hist: [Int]) {
        var total = 0, weighted = 0, p50 = -1, p95 = -1
        for (n, c) in hist.enumerated() { total += c; weighted += n * c }
        var run = 0
        for (n, c) in hist.enumerated() {
            run += c
            if p50 < 0 && Double(run) >= Double(total) * 0.5 { p50 = n }
            if p95 < 0 && Double(run) >= Double(total) * 0.95 { p95 = n }
        }
        let maxN = hist.enumerated().last { $0.element > 0 }?.offset ?? 0
        print(String(format: "  %-22s mean %5.1f   median %2d   p95 %2d   max %2d",
                     (name as NSString).utf8String!, Double(weighted) / Double(max(1, total)), p50, p95, maxN))
    }

    print("Flow over \(Int(minutes)) min of drone (rendered in \(String(format: "%.1f", wall))s, \(String(format: "%.0f", minutes * 60 / wall))× realtime)\n")
    print("Voices:")
    report("active", activeHist)
    report("audible (-40 dB)", audibleHist40)
    report("audible (-30 dB)", audibleHist30)
    report("audible (-20 dB)", audibleHist20)

    // Partials above the honest limit of adult hearing are being computed and
    // then contributing nothing. This counts them at the pitches Flow uses.
    print("\nPartials per voice above audibility limits (at Flow's registers):")
    let timbres = TimbreCatalog.all
    for limit in [16000.0, 14000.0] {
        var wasted = 0, total = 0
        for t in timbres {
            for octave in 2...6 {
                let f0 = 440.0 * pow(2.0, Double(octave - 4))   // rough register spread
                for p in t.partials {
                    total += 1
                    if f0 * p.h > limit { wasted += 1 }
                }
            }
        }
        print(String(format: "  above %5.0f Hz: %d of %d partial slots (%.0f%%)",
                     limit, wasted, total, 100.0 * Double(wasted) / Double(total)))
    }
}

MainActor.assumeIsolated { run() }
