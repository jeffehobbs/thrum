import AVFoundation
import Accelerate

// Why tilting your head up and down warbles, when turning it left and right
// doesn't — asked of the render path, and answered "it isn't us".
//
// Written for a listener report on 2026-08-10: a warble, intermittent, on the head
// tilt axis, worst on the higher voices. The code treats all three axes identically
// — same smoother, same dead band, same rate cap — so the asymmetry seemed bound to
// live inside AVAudioEnvironmentNode's HRTF rather than in ours, and that is
// measurable without a head.
//
// Three tests, three refutations, and they are the reason this file is worth
// keeping: each one is a plausible cause that no longer needs re-investigating.
//
//  1. `staircase` — hold the listener at static angles, 1° apart, and ask how far
//     the rendered spectrum moved. The node snaps to a filter grid on *every* axis,
//     and snaps hardest in azimuth. Elevation is the smooth one.
//  2. `handoverReport` — render continuously while rotating, and compare the
//     waveform at each block boundary (where the app hands over a new orientation,
//     twelve times a second) against the middle of the same block. Ratio 1.00 at
//     110 Hz, 440 Hz, 1760 Hz and 5 kHz, on all three axes. The node crossfades;
//     the hand-over is not a discontinuity.
//  3. `modulationReport` — a realistic ±15° nod, measuring how much each band's
//     level wobbles block to block. A nod adds 0.18 dB to a still listener's own
//     2.81 dB of high-band wobble, and damping pitch recovers exactly that 0.18.
//     Head movement is not what makes this drone's high end restless — sixteen
//     detuned voices beating against each other is.
//
// So the render path is exonerated and the suspect is the *stream of angles* we
// hand it, which comes from a sensor no offline harness can fake. That is now
// instrumented on the device instead: `HeadSmoother` in Shared/Spatial.swift reports
// peak input rate per axis and how often its slew limit fired, and the flight
// recorder logs both every thirty seconds. See `Tools/spatial` for its checks.
//
//   swiftc -O -o /tmp/thrumwarble Tools/warble/*.swift && /tmp/thrumwarble

let sr = 48000.0
/// The device's real IO buffer, near enough: ThrumFlow runs an ~85 ms buffer, so
/// the graph reads a new listener orientation about twelve times a second and no
/// faster. Anything this harness discovers at per-block granularity is what the
/// ear actually gets.
let block = 4096

/// One second of a sustained multi-tone drone through the HRTF, at a fixed
/// listener orientation. Returns the magnitude spectrum of the left ear.
///
/// A drone rather than a sine on purpose: elevation cues are spectral notches in
/// the 5–10 kHz region, and a single low sine has no energy there to notch. This
/// is the harmonic series of a 110 Hz root, which is what Thrum actually sounds.
///
/// `positions` is a whole field, because the number of sources is the thing under
/// test: one source per position, each a different partial of the same drone so
/// they are decorrelated the way real voices are.
func spectrum(yaw: Float = 0, pitch: Float = 0, roll: Float = 0,
              positions: [AVAudio3DPoint]) -> [Float] {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    else { return [] }
    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    var nodes: [AVAudioSourceNode] = []
    for (index, position) in positions.enumerated() {
        var phases = [Double](repeating: 0, count: 24)
        // A different root per source, so the field is sixteen distinct voices
        // rather than sixteen copies of one — which is what decides whether their
        // HRTF steps can cancel or must add.
        let root = 110.0 * pow(2.0, Double(index % 4) / 4.0) * (index < 8 ? 1 : 2)
        let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
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
                p[i] = Float(s * 0.12)
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
    env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: yaw, pitch: pitch, roll: roll)

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(block))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(block))
    else { return [] }

    var tail = [Float]()
    var frames = 0
    while frames < Int(sr) {
        guard let st = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              st == .success else { break }
        let n = Int(out.frameLength)
        // Keep only the last block, so the HRTF and the reverb-free direct path
        // have long since settled.
        if let a = out.floatChannelData?[0] {
            tail = Array(UnsafeBufferPointer(start: a, count: n))
        }
        frames += n
    }
    audio.stop()
    return magnitudes(tail)
}

/// Magnitude spectrum in dB, one bin per 2 samples, Hann-windowed.
func magnitudes(_ x: [Float]) -> [Float] {
    guard x.count >= 2048 else { return [] }
    let n = 2048
    var win = [Float](repeating: 0, count: n)
    vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var frame = Array(x.suffix(n))
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
            vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
        }
    }
    return mags.map { 20 * log10(max($0, 1e-7)) }
}

/// How different two rendered spectra are, in dB averaged over one band.
///
/// Split by band because the two halves of an HRTF do different jobs: below
/// ~1.5 kHz a head turn is interaural time and level, which is smooth and is
/// where a drone's fundamentals sit; above ~4 kHz it is pinna notches, which is
/// where elevation is encoded and where a switch between measured filters shows
/// up. The listener's clue — that it is the higher voices that warble — is a
/// statement about which of these two is moving.
func distance(_ a: [Float], _ b: [Float], from: Double, to: Double) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    let hz = sr / 2048
    let lo = max(1, Int(from / hz)), hi = min(a.count, Int(to / hz))
    guard hi > lo else { return 0 }
    var sum: Float = 0
    for i in lo..<hi { sum += abs(a[i] - b[i]) }
    return sum / Float(hi - lo)
}

let r = 1.6
let lift = 22.0 * Double.pi / 180

/// Thrum's real field: eight azimuths on each of two elevation tiers.
func field(tiers: Range<Int> = 0..<2) -> [AVAudio3DPoint] {
    var out: [AVAudio3DPoint] = []
    for tier in tiers {
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

/// One source, dead ahead, on the low tier.
let one = [field(tiers: 0..<1)[0]]

print("""

— how much the render changes per degree of listener rotation —

  Each row sweeps the listener 1° at a time and reports how far the rendered
  spectrum moved per step, split into the band where interaural cues live and the
  band where HRTF pinna notches live. A smoothly interpolated axis gives a small
  even number; an axis that snaps to the nearest measured HRTF gives zeros with
  occasional cliffs — and a cliff on a sustained drone is a click.
""")

func staircase(_ label: String, _ render: (Float) -> [Float], range: [Float]) {
    var previous: [Float] = []
    var low: [Float] = [], high: [Float] = []
    var line = ""
    for angle in range {
        let s = render(angle)
        if !previous.isEmpty {
            let dl = distance(previous, s, from: 100, to: 1500)
            let dh = distance(previous, s, from: 4000, to: 12000)
            low.append(dl); high.append(dh)
            line += dh < 0.01 ? "." : (dh < 0.5 ? "-" : (dh < 2 ? "+" : "#"))
        }
        previous = s
    }
    func stats(_ v: [Float]) -> String {
        String(format: "mean %.2f peak %5.2f", v.reduce(0, +) / Float(v.count), v.max() ?? 0)
    }
    print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0))"
          + "low \(stats(low))   high \(stats(high))   cliffs \(high.filter { $0 > 2 }.count)")
    print("    \(line)")
}

let sweep = (0...45).map { Float($0) }

print("\n  one source, low tier, dead ahead")
staircase("pitch 0…45°", { spectrum(pitch: $0, positions: one) }, range: sweep)
staircase("yaw 0…45°", { spectrum(yaw: $0, positions: one) }, range: sweep)

print("\n  the whole field — 16 sources, 8 azimuths × 2 elevations")
let all = field()
staircase("pitch 0…45°", { spectrum(pitch: $0, positions: all) }, range: sweep)
staircase("yaw 0…45°", { spectrum(yaw: $0, positions: all) }, range: sweep)

print("\n  high tier alone (the high octaves — 8 sources at +22°)")
let top = field(tiers: 1..<2)
staircase("pitch 0…45°", { spectrum(pitch: $0, positions: top) }, range: sweep)
staircase("yaw 0…45°", { spectrum(yaw: $0, positions: top) }, range: sweep)

print("""

  Legend on the high band: '.' no change, '-' <0.5 dB, '+' <2 dB, '#' a cliff.

  MEASURED, and it refutes the hypothesis this test was written for. The guess was
  that a nod would be worse than a turn because the field has eight distinct
  azimuths and only two elevations — so a nod walks eight sources over the same
  elevation edge at the same instant, where a turn staggers them across eight
  different azimuth edges. Correlated steps add; staggered ones average away.

  It is the other way round. Pitch is the *smoother* axis at every scale: 3 cliffs
  across 45° against yaw's 9 for a single source, 9 against 15 for the whole field.
  The grid is coarse on all three axes and coarsest in azimuth. So "elevation has a
  worse filter set" is not the explanation for anything, and neither is source
  correlation — whatever is heard on the up-down axis is not this.

  What the numbers do establish, and it is worth keeping: the high band moves
  1.8–3.8 dB per degree on every axis while the low band moves 0.1–0.2 dB. The
  localisation payload is all in the low band and the flicker is all in the high
  one, at a ratio of roughly twenty to one. Any future attempt to make head
  tracking quieter should be spending that ratio, not chasing one axis.
""")

handoverReport()

modulationReport()
