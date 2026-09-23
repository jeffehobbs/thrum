import AVFoundation
import Accelerate

// What a head turn does to a sustained drone *inside* AVAudioEnvironmentNode, as a
// function of the three things the host controls: how long a render cycle is, how
// often the orientation is handed over, and which HRTF algorithm renders it.
//
// Written for the head-tracking rewrite of 2026-09-21, which moved the transport
// onto the render clock (one orientation per cycle — see `HeadTransport`). That
// made "how often" a settled question and left "how long" and "which" open, and
// both turned out to matter more than any smoothing constant.
//
// **MEASURED, and the conclusion first.** On a realistic look-around (yaw ±40° at
// 0.25 Hz, pitch ±15° at 0.4 Hz, peak 63°/s), sixteen harmonic-series drones in
// Thrum's field, left ear, 4–12 kHz level wobble per 10 ms in dB:
//
//                 480     1024    2048    4096 frames per cycle
//     HRTF       0.245   0.193   0.130   0.066
//     HRTFHQ     0.040   0.055   0.093   0.094
//     still      0.003   (the drone's own beating — the floor)
//
//  1. Plain HRTF gets *worse* the more often it is handed an orientation. It snaps
//     to a filter grid (`Tools/warble` found the cliffs) and crossfades at every
//     hand-over, and a crossfade between two grid filters with different interaural
//     delays is a partial cancellation up where the partials are. Every hand-over
//     is a small dip in the high band; more hand-overs, more dips. Under the old
//     sensor-driven transport, with its 45 ms rate cap on an 85 ms buffer, this was
//     the mechanism behind "the high voices flicker when I move".
//  2. HRTFHQ interpolates between grid points, so it goes the other way: the finer
//     the steps, the smaller each change. At 1024-frame cycles it is under plain
//     HRTF's *best* figure at any cycle length, and within a hair of its own best.
//  3. Pitch. A 1760 Hz partial at 45° right, phase-vocoder instantaneous frequency,
//     worst deviation during the same look-around: HRTF 5–7¢ at short cycles, 3¢ at
//     4096; HRTFHQ 2.0¢ at 480 and 1024, 5¢ at 4096. Two cents is about the physical
//     Doppler of an ear moving through the field at 63°/s — the ITD of a source 45°
//     off-axis changes at ~0.8 ms/s, which is 1.3¢ — so HRTFHQ at short cycles is
//     rendering the turn about as truthfully as a turn can be rendered.
//  4. Cost, sixteen sources, sources a table copy: HRTFHQ equals HRTF on a still
//     head and roughly doubles it while moving, from a base under 1% of one core.
//
// So ThrumFlow renders with `.HRTFHQ` and asks for a 1024-frame buffer while
// tracking — `FlowHost.buildGraph` and `FlowHost.trackingBuffer`. The checks at the
// end pin the four findings so a future change to either is a failing harness
// rather than a listener's report.
//
//   swiftc -O -o /tmp/thrumhandover Tools/handover/main.swift && /tmp/thrumhandover

let sr = 48000.0
var fails = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { fails += 1 }
}

/// A realistic look-around: yaw ±40° at 0.25 Hz (peak 63°/s), pitch ±15° at 0.4 Hz.
func lookAround(_ t: Double) -> AVAudio3DAngularOrientation {
    AVAudio3DAngularOrientation(yaw: Float(40 * sin(2 * .pi * 0.25 * t)),
                                pitch: Float(15 * sin(2 * .pi * 0.4 * t)), roll: 0)
}

/// Thrum's real field: eight azimuths on each of two elevation tiers.
func field() -> [AVAudio3DPoint] {
    let r = 1.6, lift = 22.0 * Double.pi / 180
    var out: [AVAudio3DPoint] = []
    for tier in 0..<2 {
        for col in 0..<8 {
            let az = Double(col) / 8 * 2 * Double.pi
            let el = tier == 0 ? -lift : lift
            out.append(AVAudio3DPoint(x: Float(r * cos(el) * sin(az)),
                                      y: Float(r * sin(el)),
                                      z: Float(-r * cos(el) * cos(az))))
        }
    }
    return out
}

enum Source {
    /// Sixteen harmonic-series drones in Thrum's registers, computed per sample.
    case drones
    /// One 1760 Hz partial at 45° right, for the pitch measurement.
    case partial
    /// Sixteen drones from precomputed tables, so the source costs nothing and the
    /// render time is the node's.
    case tables
}

/// Render `seconds` of the field while the listener moves along `orient`, handing
/// the node a new orientation at most every `handover` seconds (0 = every cycle).
/// Returns the left ear and the wall time the render took.
func render(block: Int, algorithm: AVAudio3DMixingRenderingAlgorithm, handover: Double,
            seconds: Double, source: Source,
            orient: @escaping (Double) -> AVAudio3DAngularOrientation) -> (left: [Float], cpu: Double) {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return ([], 0) }
    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    let positions: [AVAudio3DPoint]
    switch source {
    case .partial: positions = [AVAudio3DPoint(x: Float(1.6 * sin(Double.pi / 4)), y: 0,
                                               z: Float(-1.6 * cos(Double.pi / 4)))]
    default:       positions = field()
    }
    var nodes: [AVAudioSourceNode] = []
    for (index, position) in positions.enumerated() {
        let root = source == .partial ? 1760.0
            : 55.0 * pow(2.0, Double(index / 8 * 2)) * pow(2.0, Double(index % 8) / 12)
        let partials = source == .partial ? 1 : 12
        let gain = source == .partial ? 0.3 : 0.08
        let node: AVAudioSourceNode
        if source == .tables {
            // One second of the drone, looped. The loop point is a click, but it is
            // the same click for both algorithms and this render is timed, not heard.
            var table = [Float](repeating: 0, count: Int(sr))
            for i in 0..<table.count {
                var s = 0.0
                for h in 0..<partials { s += sin(2 * .pi * root * Double(h + 1) * Double(i) / sr) / Double(h + 1) }
                table[i] = Float(s * gain)
            }
            var pos = 0
            node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let d = list.first?.mData else { return noErr }
                let p = d.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(frameCount) { p[i] = table[pos]; pos += 1; if pos == table.count { pos = 0 } }
                return noErr
            }
        } else {
            var phases = [Double](repeating: 0, count: partials)
            node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let d = list.first?.mData else { return noErr }
                let p = d.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(frameCount) {
                    var s = 0.0
                    for h in 0..<phases.count {
                        s += sin(phases[h]) / Double(h + 1)
                        phases[h] += 2 * Double.pi * root * Double(h + 1) / sr
                        if phases[h] > 2 * Double.pi { phases[h] -= 2 * Double.pi }
                    }
                    p[i] = Float(s * gain)
                }
                return noErr
            }
        }
        audio.attach(node)
        audio.connect(node, to: env, format: mono)
        node.renderingAlgorithm = algorithm
        node.position = position
        nodes.append(node)
    }
    defer { _ = nodes }
    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(block))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(block)) else { return ([], 0) }

    var left = [Float]()
    left.reserveCapacity(Int(seconds * sr))
    var t = 0.0, lastWrite = -1.0
    let start = CFAbsoluteTimeGetCurrent()
    while t < seconds {
        if lastWrite < 0 || t - lastWrite >= handover - 1e-9 {
            env.listenerAngularOrientation = orient(t)
            lastWrite = t
        }
        guard let st = try? audio.renderOffline(AVAudioFrameCount(block), to: out), st == .success else { break }
        if let a = out.floatChannelData?[0] {
            left.append(contentsOf: UnsafeBufferPointer(start: a, count: Int(out.frameLength)))
        }
        t += Double(block) / sr
    }
    let cpu = CFAbsoluteTimeGetCurrent() - start
    audio.stop()
    return (left, cpu)
}

// MARK: - Measurements

/// One FFT frame's magnitudes, Hann-windowed, 2048 points.
struct Analyzer {
    let n = 2048
    let setup: FFTSetup
    var win = [Float](repeating: 0, count: 2048)
    var frame = [Float](repeating: 0, count: 2048)
    var real = [Float](repeating: 0, count: 1024), imag = [Float](repeating: 0, count: 1024)
    var mags = [Float](repeating: 0, count: 1024)
    init() {
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }
    /// Magnitudes, and the complex value of one bin.
    mutating func analyze(_ x: [Float], at start: Int, bin: Int) -> (re: Double, im: Double) {
        for i in 0..<n { frame[i] = x[start + i] * win[i] }
        var re = 0.0, im = 0.0
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
                re = Double(rp[bin]); im = Double(ip[bin])
            }
        }
        return (re, im)
    }
    func level(_ from: Double, _ to: Double) -> Double {
        let hz = sr / Double(n)
        var sum = 0.0
        for i in Int(from / hz)..<min(n / 2, Int(to / hz)) { sum += Double(mags[i] * mags[i]) }
        return 10 * log10(max(sum, 1e-12))
    }
}

/// Mean absolute hop-to-hop change of the 4–12 kHz level, in dB — the flicker.
/// Skips the first second, where the HRTF settles.
func highBandWobble(_ x: [Float]) -> Double {
    var a = Analyzer()
    var levels: [Double] = []
    var s = Int(sr)
    while s + a.n <= x.count {
        _ = a.analyze(x, at: s, bin: 0)
        levels.append(a.level(4000, 12000))
        s += 480
    }
    guard levels.count > 1 else { return 0 }
    var f = 0.0
    for i in 1..<levels.count { f += abs(levels[i] - levels[i - 1]) }
    return f / Double(levels.count - 1)
}

/// Worst instantaneous-frequency deviation of a partial from nominal, in cents,
/// by phase vocoder: the phase advance of its bin across a 256-sample hop.
func pitchDeviation(_ x: [Float], nominal: Double) -> Double {
    var a = Analyzer()
    let hop = 256
    let bin = Int((nominal / (sr / Double(a.n))).rounded())
    var previous: Double?
    var worst = 0.0
    var s = Int(sr)
    while s + a.n <= x.count {
        let c = a.analyze(x, at: s, bin: bin)
        let phase = atan2(c.im, c.re)
        if let p = previous {
            var d = phase - p - 2 * .pi * nominal * Double(hop) / sr
            d -= 2 * .pi * (d / (2 * .pi)).rounded()
            let f = nominal + d * sr / (2 * .pi * Double(hop))
            worst = max(worst, abs(1200 * log2(f / nominal)))
        }
        previous = phase
        s += hop
    }
    return worst
}

// MARK: - Reports

let seconds = 9.0
let algorithms: [(AVAudio3DMixingRenderingAlgorithm, String)] = [(.HRTF, "HRTF"), (.HRTFHQ, "HRTFHQ")]
let blocks = [480, 1024, 2048, 4096]

print("""

— high-band flicker during a 63°/s look-around, sixteen drones, left ear —

  Mean |Δ level| of the 4–12 kHz band per 10 ms hop, in dB. The orientation is
  handed over once per cycle, which is what the transport now does.
""")
var wobble: [String: Double] = [:]
print(String(format: "  %-8@ %8@ %8@ %8@ %8@", "", "480", "1024", "2048", "4096"))
for (algorithm, name) in algorithms {
    var line = String(format: "  %-8@", name as NSString)
    for block in blocks {
        let r = render(block: block, algorithm: algorithm, handover: 0, seconds: seconds,
                       source: .drones, orient: lookAround)
        let w = highBandWobble(r.left)
        wobble["\(name)\(block)"] = w
        line += String(format: " %8.3f", w)
    }
    print(line)
}
let stillDrone = render(block: 1024, algorithm: .HRTF, handover: 1e9, seconds: seconds,
                        source: .drones) { _ in AVAudio3DAngularOrientation(yaw: 12, pitch: -8, roll: 0) }
let floor = highBandWobble(stillDrone.left)
print(String(format: "  %-8@ %8.3f   (listener still — the drone's own beating)", "still" as NSString, floor))

print("""

— pitch of a 1760 Hz partial at 45° right, same look-around —

  Worst instantaneous-frequency deviation from nominal, in cents. A turning head
  really does Doppler-shift a source it is turning past — about 1.3¢ here — so the
  floor is not zero and the question is how far above it each rendering sits.
""")
var cents: [String: Double] = [:]
print(String(format: "  %-8@ %8@ %8@ %8@", "", "480", "1024", "4096"))
for (algorithm, name) in algorithms {
    var line = String(format: "  %-8@", name as NSString)
    for block in [480, 1024, 4096] {
        let r = render(block: block, algorithm: algorithm, handover: 0, seconds: seconds,
                       source: .partial, orient: lookAround)
        let c = pitchDeviation(r.left, nominal: 1760)
        cents["\(name)\(block)"] = c
        line += String(format: " %8.2f", c)
    }
    print(line)
}

print("""

— render cost, sixteen sources, sources a table copy — seconds to render 20 s —
""")
var cost: [String: Double] = [:]
for (algorithm, name) in algorithms {
    let still = render(block: 1024, algorithm: algorithm, handover: 0, seconds: 20, source: .tables) { _ in
        AVAudio3DAngularOrientation(yaw: 12, pitch: -8, roll: 0) }
    let moving = render(block: 1024, algorithm: algorithm, handover: 0, seconds: 20, source: .tables, orient: lookAround)
    cost["\(name)still"] = still.cpu; cost["\(name)moving"] = moving.cpu
    print(String(format: "  %-8@ still %5.2f s   moving %5.2f s", name as NSString, still.cpu, moving.cpu))
}

print("\n— the findings, pinned —")
check(wobble["HRTF480"]! > wobble["HRTF4096"]! * 2,
      "plain HRTF flickers more the more often it is handed an orientation",
      String(format: "%.3f dB per hop at 480-frame cycles against %.3f at 4096", wobble["HRTF480"]!, wobble["HRTF4096"]!))
check(wobble["HRTFHQ1024"]! < blocks.map { wobble["HRTF\($0)"]! }.min()!,
      "HRTFHQ handed over every 1024-frame cycle flickers less than plain HRTF at any cycle length",
      String(format: "%.3f against HRTF's best %.3f", wobble["HRTFHQ1024"]!, blocks.map { wobble["HRTF\($0)"]! }.min()!))
check(wobble["HRTFHQ1024"]! < wobble["HRTFHQ480"]! * 1.6,
      "and 1024 frames is close enough to 480 to be worth half the wakeups",
      String(format: "%.3f at 1024 against %.3f at 480", wobble["HRTFHQ1024"]!, wobble["HRTFHQ480"]!))
check(cents["HRTFHQ1024"]! < 3,
      "HRTFHQ at 1024 holds a partial within 3 cents through a 63°/s turn",
      String(format: "worst %.2f¢ (HRTF: %.2f¢)", cents["HRTFHQ1024"]!, cents["HRTF1024"]!))
check(cost["HRTFHQmoving"]! < cost["HRTFmoving"]! * 4 && cost["HRTFHQmoving"]! < 20 * 0.05,
      "and costs under four times plain HRTF while moving, from a base far below one core",
      String(format: "%.2f s against %.2f s to render 20 s", cost["HRTFHQmoving"]!, cost["HRTFmoving"]!))

print(fails == 0 ? "\nAll checks passed.\n" : "\n\(fails) FAILED\n")
exit(fails == 0 ? 0 : 1)
