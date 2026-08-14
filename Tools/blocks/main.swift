import AVFoundation
import Accelerate

// Does the hand-over break at the block size the device actually runs?
//
// `Tools/warble` exonerated AVAudioEnvironmentNode's HRTF hand-over — boundary
// roughness 1.00× interior at every frequency, on every axis. That measurement is
// sound, and it was made at `block = 4096`, because the app asks for an ~85 ms IO
// buffer and 4096 frames is what 85 ms is.
//
// The device does not get 85 ms. Pulled from ThrumFlow's own flight recorder, every
// AirPods session in the log reads:
//
//     48 kHz · 480 frames · 10 ms
//
// and only the built-in-speaker sessions read 4080 frames. iOS treats
// `setPreferredIOBufferDuration` as a hint and grants 10 ms on a Bluetooth route —
// so the entire spatial path runs at 480 frames, 8.5× smaller than every offline
// measurement this project has made, and the render thread reads the listener
// orientation ~100 times a second rather than twelve.
//
// That inverts the relationship the rate cap was designed around. At 4096 frames a
// 45 ms cap writes about once per block: every block gets a fresh orientation and
// the node crossfades each one. At 480 frames the same cap writes once every ~4.5
// blocks: the orientation is *held* for four blocks and then steps. Whether that
// step is crossfaded over 480 frames or over 4096 is not something the earlier
// harness could see, because it never held an orientation across a boundary.
//
// Two questions, then, neither of which has been asked at 480 frames:
//
//  1. `handoverAtBlock` — the warble test, re-run across block sizes, with the
//     rate cap modelled honestly (hold, then step) instead of one write per block.
//  2. `dropoutReport` — the listener's actual symptom rather than a proxy. A
//     sustained high partial, a realistically moving head, and the short-window RMS
//     envelope of the result: "notes cutting out" is a level collapse, and roughness
//     at a boundary is not the same measurement as a hole in the envelope.
//
//   swiftc -O -o /tmp/thrumblocks Tools/blocks/main.swift && /tmp/thrumblocks

let sr = 48000.0

/// Thrum's real field geometry, from `SpatialField`.
let radius = 1.6
let liftRad = 22.0 * Double.pi / 180

func field(tiers: Range<Int> = 0..<2) -> [AVAudio3DPoint] {
    var out: [AVAudio3DPoint] = []
    for tier in tiers {
        for col in 0..<8 {
            let az = Double(col) / 8 * 2 * Double.pi
            let el = tier == 0 ? -liftRad : liftRad
            out.append(AVAudio3DPoint(x: Float(radius * cos(el) * sin(az)),
                                      y: Float(radius * sin(el)),
                                      z: Float(-radius * cos(el) * cos(az))))
        }
    }
    return out
}

/// One render of the real graph: N mono HRTF sources into an environment node,
/// with the listener re-pointed on the app's own schedule.
///
/// `writeInterval` is the rate cap in seconds — the orientation is held between
/// writes and steps at them, which is what the device does and what the earlier
/// harness did not model. Returns the stitched left ear plus the sample offsets at
/// which a hand-over actually occurred.
func render(axis: String, degreesPerSecond: Double, hz: Double,
            positions: [AVAudio3DPoint], block: Int,
            writeInterval: Double = 0.045, seconds: Double = 3.0)
-> (samples: [Float], writes: [Int], wall: Double) {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    else { return ([], [], 0) }
    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    var nodes: [AVAudioSourceNode] = []
    for position in positions {
        var phase = 0.0
        let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let d = list.first?.mData else { return noErr }
            let p = d.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frameCount) {
                p[i] = Float(sin(phase) * 0.3)
                phase += 2 * Double.pi * hz / sr
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            return noErr
        }
        audio.attach(node)
        audio.connect(node, to: env, format: mono)
        node.renderingAlgorithm = .HRTF
        node.position = position
        nodes.append(node)
    }
    defer { _ = nodes }
    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(block))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(block))
    else { return ([], [], 0) }

    let blocks = Int(seconds * sr / Double(block))
    var stitched = [Float]()
    stitched.reserveCapacity(blocks * block)
    var writes: [Int] = []
    var lastWrite = -Double.infinity
    var wall = 0.0

    for b in 0..<blocks {
        let now = Double(b * block) / sr
        // The app's rate cap: hold the orientation, then step it. The angle written
        // is where the head has actually got to by now, so the step size grows with
        // the interval — exactly as it does on the device.
        if now - lastWrite >= writeInterval {
            lastWrite = now
            let a = Float(degreesPerSecond * now)
            switch axis {
            case "pitch": env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: a, roll: 0)
            case "yaw":   env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: a, pitch: 0, roll: 0)
            case "roll":  env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: a)
            default:      break            // "still"
            }
            writes.append(b * block)
        }
        let t0 = mach_absolute_time()
        guard let st = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              st == .success else { break }
        wall += Double(mach_absolute_time() - t0)
        if let a = out.floatChannelData?[0] {
            stitched.append(contentsOf: UnsafeBufferPointer(start: a, count: Int(out.frameLength)))
        }
    }
    audio.stop()

    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let seconds = wall * Double(tb.numer) / Double(tb.denom) / 1e9
    return (stitched, writes, seconds)
}

/// Mean |second difference| over a set of sample indices. Flat for a clean sine,
/// spikes at a discontinuity.
func roughness(_ x: [Float], _ indices: [Int]) -> Double {
    var sum = 0.0
    var n = 0
    for i in indices where i >= 2 && i < x.count {
        sum += abs(Double(x[i]) - 2 * Double(x[i - 1]) + Double(x[i - 2]))
        n += 1
    }
    return n == 0 ? 0 : sum / Double(n)
}

// MARK: - 1. The warble test, across block sizes

print("""

— the hand-over, re-measured at the block size the device actually runs —

  `Tools/warble` measured this at 4096 frames and found nothing. The device runs
  480. The rate cap is modelled properly here: the orientation is held between
  writes and steps at them, so at 480 frames one write in 4.5 blocks carries a
  step four times larger than at 4096 frames, where every block gets a fresh one.

  ratio = roughness at a hand-over ÷ roughness in the interior of the same render
  (1.0 = the node crossfaded it away; higher = a step in the waveform)
""")

let all = field()
print("\n     block   ms      still    yaw 120°/s   pitch 120°/s   roll 120°/s")
for block in [480, 1024, 2048, 4096] {
    var line = String(format: "  %6d  %4.0f  ", block, Double(block) / sr * 1000)
    for axis in ["still", "yaw", "pitch", "roll"] {
        let r = render(axis: axis, degreesPerSecond: 120, hz: 3000,
                       positions: all, block: block)
        guard !r.samples.isEmpty else { line += "        n/a"; continue }
        // Boundaries at real hand-overs only, skipping the settling blocks.
        var edge: [Int] = [], mid: [Int] = []
        for w in r.writes where w > block * 4 {
            edge.append(contentsOf: (w - 8)..<(w + 8))
            mid.append(contentsOf: (w + block / 2 - 8)..<(w + block / 2 + 8))
        }
        let e = roughness(r.samples, edge), m = roughness(r.samples, mid)
        line += String(format: "  %9.2f", m > 0 ? e / m : 0)
    }
    print(line)
}

// MARK: - 2. The symptom itself

/// Short-window RMS envelope, in dB relative to the median window.
///
/// This is the measurement that matches the report. Roughness catches a step in the
/// waveform; a listener saying "notes cut out" is describing a hole in the
/// *envelope*, which a step need not produce and a badly-handled filter swap does.
func envelopeDips(_ x: [Float], window: Int) -> (median: Double, worst: Double, dips: Int) {
    guard x.count > window * 8 else { return (0, 0, 0) }
    var rms: [Double] = []
    var i = window * 4        // skip settling
    while i + window <= x.count {
        var acc = 0.0
        for k in i..<(i + window) { acc += Double(x[k]) * Double(x[k]) }
        rms.append((acc / Double(window)).squareRoot())
        i += window
    }
    let sorted = rms.sorted()
    let median = sorted[sorted.count / 2]
    guard median > 0 else { return (0, 0, 0) }
    let db = rms.map { 20 * log10(max($0, 1e-9) / median) }
    // A 6 dB hole in a sustained drone partial is plainly audible as the note
    // ducking; 6 dB is a quarter of the power.
    return (median, db.min() ?? 0, db.filter { $0 < -6 }.count)
}

print("""

— the envelope, which is what "cutting out" means —

  A sustained 3 kHz partial on the high tier, sixteen sources, listener moving at a
  head's real speed. The envelope is measured in 5 ms windows against its own
  median. `worst` is the deepest hole; `dips` counts windows more than 6 dB down,
  which is where a held drone note audibly ducks.
""")

let high = field(tiers: 1..<2)
let win = Int(0.005 * sr)
print("\n     block   ms    axis        worst dip    windows >6 dB down")
for block in [480, 4096] {
    for axis in ["still", "pitch", "yaw"] {
        let r = render(axis: axis, degreesPerSecond: 120, hz: 3000,
                       positions: high, block: block)
        let d = envelopeDips(r.samples, window: win)
        print(String(format: "  %6d  %4.0f    %-8s   %7.2f dB   %6d",
                     block, Double(block) / sr * 1000, (axis as NSString).utf8String!,
                     d.worst, d.dips))
    }
}

// MARK: - 3. What the flight recorder cannot see

print("""

— the cost of the HRTF stage itself —

  `Tools/spatial` already measures this stage's throughput — 16 buses on HRTF at
  17.7× realtime against DroneEngine's own 18×, so the HRTF costs almost nothing on
  top. What it does not vary is the block size, and `Tools/budget`'s "16-bus HRTF
  path costs ~9% more than stereo" is not measuring HRTFs at all: it is
  `renderSpatial` plus sixteen `copyBus` memcpys, with no environment node in the
  loop.

  Block size is the open question because a small buffer multiplies whatever is
  *per-block* rather than per-sample. Read the ratio between the rows, not the
  absolute cost — offline on a Mac is not an iPhone 12 mini.

  Note what neither harness can reach: `DroneEngine.renderLoad`, the only load
  number in the flight recorder, brackets `renderSpatial` alone. Everything measured
  here runs downstream of it and is invisible to the log.
""")

print("\n     block   ms    listener    ms of CPU per 10 ms of audio")
for block in [480, 4096] {
    for axis in ["still", "yaw"] {
        let r = render(axis: axis, degreesPerSecond: 120, hz: 3000,
                       positions: all, block: block, seconds: 3.0)
        guard !r.samples.isEmpty else { continue }
        let audioSeconds = Double(r.samples.count) / sr
        let perTenMs = r.wall / audioSeconds * 0.010 * 1000
        print(String(format: "  %6d  %4.0f    %-8s    %6.3f ms   (%.0f× realtime)",
                     block, Double(block) / sr * 1000, (axis as NSString).utf8String!,
                     perTenMs, audioSeconds / r.wall))
    }
}

print("")
