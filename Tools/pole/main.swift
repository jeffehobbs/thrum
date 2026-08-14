import Foundation
import AVFoundation
import Accelerate
import simd

// Why looking down at your feet makes one drone tone cut out, and turning your
// head doesn't — asked of the render path, and answered "it still isn't us".
//
// **Conclusion first, because this harness is a refutation and its value is that
// nobody need investigate the pole again.** Four measurements, four negatives:
//
//  1. `RATE` — a source crossing the listener's pole dips no more than 2.6 dB and
//     steps no more than 1.8 dB between hand-overs, at every gesture speed from
//     25°/s to the smoother's own 400°/s slew limit, and is indistinguishable from
//     control buses that never come within 68° of a pole. The environment node
//     interpolates through the singularity cleanly.
//  2. `PULL PATTERN` — all seventeen source nodes are pulled exactly once per cycle
//     on one timestamp with uniform frame counts, at both buffer sizes the flight
//     recorder has seen on the device, still and rotating. `SpatialPump`'s unchecked
//     assumption holds, so no bus can be copying out of a clobbered or stale block.
//  3. The vector round-trip (see the commit that added this file) — setting
//     `listenerVectorOrientation` and reading it back is exact to 0.000000 straight
//     through pitch 90°, and `listenerAngularOrientation` reads 95°, 100°, 105°
//     without wrapping. The node stores the orientation as vectors; it is not
//     decomposing our quaternion into Euler angles behind the boundary, so the
//     1.4.1 fix did not merely move the singularity onto Apple's side of it.
//  4. `TILT`/`YAW` — the first pass, kept because its flaws are instructive. See the
//     two method notes below.
//
// So the render path is exonerated for the third time (`Tools/warble` was the
// first, on the same symptom's predecessor). What is left is the stream of
// orientations, which comes from a sensor no offline harness can fake — and the
// device-side instrumentation added alongside this file (`HeadTracker.peakTilt` and
// `.stalls`, reported in the heartbeat) is aimed at the one hypothesis that fits an
// angle-correlated fault with no mathematics in it: the motion stream is a
// *separate* Bluetooth stream from the audio, and looking all the way down puts a
// chin, a chest and a torso between AirPods and a phone in a trouser pocket.
//
// ---- what was originally suspected, and how it was tested ----
//
// Written for a listener report on 2026-08-13, after the 1.4.1 quaternion fix had
// removed the Euler singularity from our own smoother and the symptom survived it:
//
//   "It honestly sounds like one of the drone tones has a bad connection, like a
//    loose audio cable... I can most reliably reproduce this by looking all the way
//    down towards my feet, this often makes a tone cut out."
//
// One tone, not the field. That rules out everything the flight recorder was built
// to catch — a gap in the audio, a route flap, a stalled render block — all of
// which take the whole mix with them. A single source misbehaving at a single head
// angle is a statement about *that source's* geometry.
//
// And the geometry says something very specific. The field is two rings at
// elevation ±22°, so tilting the listener's head down by 68° puts
//
//   - bus 4  (behind · low)  exactly on the listener's DOWN pole
//   - bus 8  (ahead · high)  exactly on the listener's UP pole
//
// where azimuth is not merely ill-conditioned but undefined: every azimuth names
// the same point. `Tools/warble` already measured what this node does with azimuth
// — "snaps to a filter grid on *every* axis, and snaps hardest in azimuth" — so a
// source crossing a pole is a source whose azimuth slews through the entire grid
// while its true position barely moves. That is the mechanism this harness is here
// to confirm or refute, and 68° down from a roughly level reference is exactly
// "all the way down towards my feet".
//
// Sixteen sources, sixteen distinct bin-centred sine frequencies, one per bus, so
// each bus's rendered level is separable from the mix by a single FFT bin. Sweep
// the listener the way a head actually moves and watch the levels.
//
// **Two flaws in that first pass, both of which had to be fixed before the null
// result meant anything, and both of which are the reason `rate.swift` exists.**
// One sine per bus measures the HRTF magnitude at one frequency, so its "dip" is a
// pinna notch sliding past that frequency rather than a source losing energy — and
// the tell is right there in the output: rotating the tone assignment by eight moved
// the dips onto different buses, so they were following the *tone*, not the
// geometry. And sweeping at 16.7°/s moves the listener 1.4° per hand-over, which is
// far slower than the gesture being reported; near a pole it is the azimuth crossed
// *per hand-over* that matters, and that is set by speed. `rate.swift` fixes both:
// one source at a time with broadband content, at gesture speeds up to 400°/s.
//
//   swiftc -O -o /tmp/thrumpole Shared/Spatial.swift Tools/pole/*.swift
//   /tmp/thrumpole

let sr = 48000.0
/// The device's real IO buffer: ~85 ms, so the graph reads a new orientation about
/// twelve times a second and no faster. One block here is one hand-over there.
let block = 4096
let buses = 16
let radius = 1.6

// MARK: - Per-bus tone assignment

/// Bin-centred, so a Hann-windowed block reads each tone with no scalloping loss
/// and three bins of mainlobe. 25 bins apart is ~293 Hz — two orders of magnitude
/// more than the leakage floor, so a bus's level is its own.
func frequency(bus: Int, rotated: Bool) -> Double {
    let index = rotated ? (bus + 8) % buses : bus
    return Double(26 + index * 25) * sr / Double(block)
}

// MARK: - Rendering

/// One continuous render while something moves the listener, sampled per block.
///
/// Returns per-bus level in dB, one row per block. Continuous rather than the
/// static staircase `Tools/warble` used, because the report is about a transition:
/// a tone that cuts out *and comes back* cannot be seen in two static renders.
func sweep(frames: Int,
           rotatedTones: Bool = false,
           orient: @escaping (Int) -> AVAudio3DVectorOrientation,
           place: ((Int) -> [AVAudio3DPoint])? = nil) -> [[Float]] {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    else { return [] }

    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    let field = SpatialField(radius: radius, lift: 22)
    var nodes: [AVAudioSourceNode] = []
    for bus in 0..<buses {
        let w = 2 * Double.pi * frequency(bus: bus, rotated: rotatedTones) / sr
        var phase = 0.0
        let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let d = list.first?.mData else { return noErr }
            let p = d.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frameCount) {
                p[i] = Float(sin(phase) * 0.2)
                phase += w
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            return noErr
        }
        audio.attach(node)
        audio.connect(node, to: env, format: mono)
        node.renderingAlgorithm = .HRTF
        node.position = field.position(bus: bus)
        nodes.append(node)
    }
    defer { _ = nodes }
    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(block))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(block))
    else { return [] }

    var rows: [[Float]] = []
    var done = 0
    var step = 0
    while done < frames {
        // Exactly what the app does between two render cycles, and nothing else.
        env.listenerVectorOrientation = orient(step)
        if let place {
            let positions = place(step)
            for (bus, node) in nodes.enumerated() { node.position = positions[bus] }
        }
        guard let status = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              status == .success, let l = out.floatChannelData?[0],
              let r = out.floatChannelData?[1] else { break }
        let n = Int(out.frameLength)
        rows.append(levels(Array(UnsafeBufferPointer(start: l, count: n)),
                           Array(UnsafeBufferPointer(start: r, count: n)),
                           rotated: rotatedTones))
        done += n
        step += 1
    }
    audio.stop()
    return rows
}

// MARK: - Analysis

/// Per-bus level in dB: both ears summed in power, since a tone that has merely
/// moved from one ear to the other has not cut out.
func levels(_ left: [Float], _ right: [Float], rotated: Bool) -> [Float] {
    let a = power(left), b = power(right)
    guard !a.isEmpty, !b.isEmpty else { return [Float](repeating: -120, count: buses) }
    return (0..<buses).map { bus in
        let k = 26 + (rotated ? (bus + 8) % buses : bus) * 25
        // ±2 bins, which is the Hann mainlobe.
        var sum: Float = 0
        for i in max(0, k - 2)...min(a.count - 1, k + 2) { sum += a[i] + b[i] }
        return 10 * log10(max(sum, 1e-12))
    }
}

/// Hann-windowed power spectrum of one block.
func power(_ x: [Float]) -> [Float] {
    guard x.count >= block else { return [] }
    let n = block
    var win = [Float](repeating: 0, count: n)
    vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var frame = Array(x.prefix(n))
    vDSP_vmul(frame, 1, win, 1, &frame, 1, vDSP_Length(n))

    let log2n = vDSP_Length(log2(Double(n)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }
    var real = [Float](repeating: 0, count: n / 2)
    var imag = [Float](repeating: 0, count: n / 2)
    var mags = [Float](repeating: 0, count: n / 2)
    real.withUnsafeMutableBufferPointer { rp in
        imag.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            frame.withUnsafeBytes {
                vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                          &split, 1, vDSP_Length(n / 2))
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
        }
    }
    return mags
}

/// The symptom, as a number: the deepest a bus goes below its own median, and the
/// hardest step it takes between two consecutive hand-overs.
///
/// Both matter and they are different failures. A deep dip that arrives smoothly
/// over a second is elevation doing its job; a 20 dB step between two blocks 85 ms
/// apart is the loose-cable sound, whatever caused it.
struct Symptom {
    var bus = 0
    var dip: Float = 0        // dB below own median
    var step: Float = 0       // worst block-to-block change, dB
    var atDip = 0             // block index
    var atStep = 0
}

/// The first blocks of any render are a startup transient — the HRTF filters begin
/// with zeroed state and the first hand-over lands on a graph that has never run.
/// Measured at 6–8 dB on *every* bus including the yaw control, which is what gave
/// it away: it is not a head movement, it is switching the engine on.
let settling = 4

func symptoms(_ rows: [[Float]]) -> [Symptom] {
    guard rows.count > settling else { return [] }
    return (0..<buses).map { bus in
        let track = Array(rows.map { $0[bus] }.dropFirst(settling))
        let median = track.sorted()[track.count / 2]
        var s = Symptom(bus: bus)
        for (i, v) in track.enumerated() where median - v > s.dip {
            s.dip = median - v; s.atDip = i
        }
        for i in 1..<track.count where abs(track[i] - track[i - 1]) > s.step {
            s.step = abs(track[i] - track[i - 1]); s.atStep = i
        }
        return s
    }
}

// MARK: - Head motion

/// The app's own mapping, so this measures the shipped pipeline rather than a
/// plausible reconstruction of it: CoreMotion angles → quaternion → the frame
/// change in `HeadSmoother.toListener` → the vectors the node is driven with.
func orientation(yaw: Double = 0, pitch: Double = 0, roll: Double = 0)
        -> AVAudio3DVectorOrientation {
    HeadSmoother.listener(HeadSmoother.rotation(yaw: yaw, pitch: pitch, roll: roll))
}

/// A head tilt at a realistic rate. 100° over six seconds is ~17°/s, which is a
/// slow deliberate look down at your feet — far below anything the slew limit or
/// the dead band would touch, so nothing in our transport is involved.
func tilt(_ step: Int, degrees: Double, sign: Double) -> Double {
    sign * degrees * Double(step) / Double(sweepBlocks)
}

let sweepSeconds = 6.0
let sweepBlocks = Int(sweepSeconds * sr / Double(block))
let sweepFrames = sweepBlocks * block

// MARK: - Report

func report(_ title: String, _ rows: [[Float]], watching: [Int]) {
    guard !rows.isEmpty else { print("\(title): no render"); return }
    let all = symptoms(rows)
    let worst = all.max { $0.step < $1.step }!
    let degreesPerBlock = 100.0 / Double(sweepBlocks)
    func angle(_ i: Int) -> Double { Double(i + settling) * degreesPerBlock }
    print("\n\(title)")
    print("  worst step: bus \(worst.bus) \(SpatialField.label(bus: worst.bus)) — "
          + String(format: "%.1f dB between hand-overs at %.0f°", worst.step,
                   angle(worst.atStep)))
    for bus in watching {
        let s = all[bus]
        print(String(format: "  bus %2d %-16@ dip %5.1f dB at %3.0f°   worst step %5.1f dB at %3.0f°",
                     bus, SpatialField.label(bus: bus) as NSString,
                     s.dip, angle(s.atDip), s.step, angle(s.atStep)))
    }
    let quiet = all.filter { !watching.contains($0.bus) }.map(\.step).max() ?? 0
    print(String(format: "  every other bus: worst step %.1f dB", quiet))
}

/// The two buses the geometry says cross a pole at 68° of tilt, and two controls
/// that never come near one.
let polar = [4, 8]
let controls = [0, 2]

print("Thrum — pole crossing, \(sweepBlocks) hand-overs over \(sweepSeconds)s "
      + "(\(String(format: "%.1f", 100 / sweepSeconds))°/s)")

// MARK: - Does the sweep reach a pole at all?

/// A source's elevation *in the listener's frame*, which is the coordinate the node
/// has to form and the one that goes singular. Derived from the vectors the app
/// hands over rather than from the Euler angles that produced them, because that is
/// all the node is given.
func relativeElevation(bus: Int, _ o: AVAudio3DVectorOrientation) -> Double {
    let f = simd_normalize(simd_double3(Double(o.forward.x), Double(o.forward.y), Double(o.forward.z)))
    let u = simd_normalize(simd_double3(Double(o.up.x), Double(o.up.y), Double(o.up.z)))
    let p = SpatialField(radius: radius, lift: 22).position(bus: bus)
    let d = simd_normalize(simd_double3(Double(p.x), Double(p.y), Double(p.z)))
    // Right-handed with x = right, y = up, z = back: right = f × u.
    let right = simd_cross(f, u)
    let horizontal = hypot(simd_dot(d, right), simd_dot(d, -f))
    return atan2(simd_dot(d, u), horizontal) * 180 / .pi
}

/// Print, for each swept gesture, how close each bus gets to a pole. If nothing
/// crosses ±88° then this harness cannot speak to the pole hypothesis at all, and
/// saying so is the point — the alternative is reading a null result as a
/// refutation of something that was never tested.
func poleReach(_ name: String, _ orient: (Int) -> AVAudio3DVectorOrientation) {
    var closest = [Double](repeating: 0, count: buses)
    var at = [Int](repeating: 0, count: buses)
    for step in 0...sweepBlocks {
        let o = orient(step)
        for bus in 0..<buses {
            let el = abs(relativeElevation(bus: bus, o))
            if el > closest[bus] { closest[bus] = el; at[bus] = step }
        }
    }
    let reached = (0..<buses).filter { closest[$0] > 88 }
    let degreesPerBlock = 100.0 / Double(sweepBlocks)
    print("\n  \(name): " + (reached.isEmpty
        ? String(format: "no bus exceeds ±88° (max %.1f°) — no pole in this gesture",
                 closest.max() ?? 0)
        : reached.map {
            String(format: "bus \($0) reaches %.1f° at %.0f°", closest[$0],
                   Double(at[$0]) * degreesPerBlock)
          }.joined(separator: ", ")))
}

print("\nGEOMETRY — how close each gesture brings a source to the listener's pole")
poleReach("tilt down") { orientation(pitch: tilt($0, degrees: 100, sign: -1)) }
poleReach("tilt up") { orientation(pitch: tilt($0, degrees: 100, sign: 1)) }
poleReach("yaw left") { orientation(yaw: tilt($0, degrees: 100, sign: -1)) }

// 1. The reported gesture: look all the way down. Both signs, because which way
//    CoreMotion calls "down" is a fact about the sensor and not worth deriving.
for sign in [-1.0, 1.0] {
    let rows = sweep(frames: sweepFrames) { step in
        orientation(pitch: tilt(step, degrees: 100, sign: sign))
    }
    report("TILT \(sign < 0 ? "down" : "up") 0→100°", rows, watching: polar + controls)
}

// 1b. The pump's unchecked assumption — see Tools/pole/pull.swift. Both buffer
//     sizes the flight recorder has actually seen on the device: 4080 frames on the
//     built-in speaker, 480 on AirPods, which is the route this path exists for.
print("\nPULL PATTERN — does every bus see the same block?")
reportPulls("480 frames (AirPods), listener still", cycleFrames: 480, rotateListener: false)
reportPulls("480 frames (AirPods), listener tilting", cycleFrames: 480, rotateListener: true)
reportPulls("4080 frames (speaker), listener tilting", cycleFrames: 4080, rotateListener: true)

// 2. The control the listener already ran for us: turning your head left and
//    right does not do this. No source can reach a pole under pure yaw — the
//    listener's polar axis is the one thing a yaw rotation leaves alone.
let yawRows = sweep(frames: sweepFrames) { step in
    orientation(yaw: tilt(step, degrees: 100, sign: -1))
}
report("YAW left 0→100° (control)", yawRows, watching: polar + controls)

// 3. Is it the bus or the frequency? Same sweep, tone assignment rotated by eight.
//    If the dropout follows bus 4 and bus 8 rather than their frequencies, it is
//    geometry; if it follows the frequency, this harness is measuring the pinna
//    notches of a particular tone and nothing more.
let rotated = sweep(frames: sweepFrames, rotatedTones: true) { step in
    orientation(pitch: tilt(step, degrees: 100, sign: -1))
}
report("TILT down 0→100°, tones rotated by 8", rotated, watching: polar + controls)

// 4. The rate sweep — see Tools/pole/rate.swift. This is the test the first pass
//    should have been: realistic gesture speeds, one source at a time, broadband.
rateReport()

// 5. Is there a direction that swallows a voice? See Tools/pole/map.swift.
sphereMap()
