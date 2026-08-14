import AVFoundation
import Accelerate

// The measurement that matches the complaint.
//
// Two hypotheses died on the way here, both of them things the code could
// plausibly have been doing wrong:
//
//  1. "Elevation has a coarser HRTF grid than azimuth."  Refuted — held-position
//     spectra show AVAudioEnvironmentNode snapping to a grid on *every* axis, and
//     yaw snaps harder than pitch (15 cliffs across 45° against 9).
//  2. "The twelve-times-a-second orientation hand-over is a discontinuity."
//     Refuted — roughness at a block boundary is 1.00× the roughness in the middle
//     of the same block, at every frequency from 110 Hz to 5 kHz. The node
//     crossfades.
//
// What is left is not a defect in the hand-over but the shape of the cliffs
// themselves, and *what the ear does with them*. A warble is a level or timbre
// fluctuation over time, so measure exactly that: render a realistic head
// movement, take the high-band level block by block, and report how much it
// wobbles. Then do it again with pitch damped, which is the candidate fix, and see
// whether the wobble goes with it.
//
// The point of splitting bands is the listener's clue. Below ~1.5 kHz a rotation
// is interaural time and level — that band *is* the localisation payload, the
// reason head tracking exists. Above ~4 kHz it is pinna notches, which carry
// almost no localisation for a drone and are where a filter switch shows up as
// timbre. A fix worth making is one that keeps the first and loses the second.

/// One realistic head movement, rendered continuously, reported as how much each
/// band's level fluctuates from block to block.
///
/// `motion` returns (yaw, pitch, roll) in degrees at a given time — so this takes
/// a real trajectory rather than a linear ramp. A nod is not a ramp; it is a
/// there-and-back, which is what makes its artefacts recur rather than pass.
func modulation(_ motion: (Double) -> (Double, Double, Double),
                positions: [AVAudio3DPoint], seconds: Double = 8) -> (low: Double, high: Double) {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    else { return (0, 0) }
    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    var nodes: [AVAudioSourceNode] = []
    for (index, position) in positions.enumerated() {
        var phases = [Double](repeating: 0, count: 16)
        // Thrum's real registers: the low tier is octaves 1–2 of the drone, the
        // high tier 3–4. Each source is a full harmonic series, because the notches
        // that elevation moves are up where the *partials* are, not the roots.
        let root = 55.0 * pow(2.0, Double(index / 8 * 2)) * pow(2.0, Double(index % 8) / 12)
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
                p[i] = Float(s * 0.08)
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
    else { return (0, 0) }

    var lowLevels: [Double] = [], highLevels: [Double] = []
    let total = Int(seconds * sr) / block
    for b in 0..<total {
        let t = Double(b) * Double(block) / sr
        let (y, p, r) = motion(t)
        env.listenerAngularOrientation =
            AVAudio3DAngularOrientation(yaw: Float(y), pitch: Float(p), roll: Float(r))
        guard let st = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              st == .success else { break }
        guard b > 3, let a = out.floatChannelData?[0] else { continue }
        let frame = Array(UnsafeBufferPointer(start: a, count: Int(out.frameLength)))
        let mags = magnitudes(frame)
        guard !mags.isEmpty else { continue }
        lowLevels.append(bandLevel(mags, from: 100, to: 1500))
        highLevels.append(bandLevel(mags, from: 4000, to: 12000))
    }
    audio.stop()
    // The wobble is the block-to-block change, not the overall drift: a level that
    // slides smoothly from one value to another as you turn is the field working,
    // and a level that jitters up and down between neighbouring blocks is the
    // warble. Mean absolute first difference separates the two.
    func wobble(_ v: [Double]) -> Double {
        guard v.count > 2 else { return 0 }
        var sum = 0.0
        for i in 1..<v.count { sum += abs(v[i] - v[i - 1]) }
        return sum / Double(v.count - 1)
    }
    return (wobble(lowLevels), wobble(highLevels))
}

/// Mean level in dB across one band.
func bandLevel(_ mags: [Float], from: Double, to: Double) -> Double {
    let hz = sr / 2048
    let lo = max(1, Int(from / hz)), hi = min(mags.count, Int(to / hz))
    guard hi > lo else { return 0 }
    var sum = 0.0
    for i in lo..<hi { sum += Double(mags[i]) }
    return sum / Double(hi - lo)
}

func modulationReport() {
    let all = field()
    print("""

    — the wobble itself, over a realistic head movement —

      A there-and-back head movement of ±15° at 0.4 Hz, which is what looking
      around while a drone plays actually is. The number is the mean block-to-block
      change in band level: a smooth pan gives a small number, a filter flicking
      between neighbours gives a large one. dB per 85 ms block.
    """)
    let amp = 15.0, rate = 0.4
    func nod(_ t: Double) -> (Double, Double, Double) {
        (0, amp * sin(2 * .pi * rate * t), 0)
    }
    func turn(_ t: Double) -> (Double, Double, Double) {
        (amp * sin(2 * .pi * rate * t), 0, 0)
    }
    func damped(_ gain: Double) -> (Double) -> (Double, Double, Double) {
        { t in (0, gain * amp * sin(2 * .pi * rate * t), 0) }
    }

    print("\n    movement                       low band      high band")
    let cases: [(String, (Double) -> (Double, Double, Double))] = [
        ("still", { _ in (0, 0, 0) }),
        ("turn (yaw) ±15°", turn),
        ("nod (pitch) ±15°", nod),
        ("nod, pitch damped to 50%", damped(0.5)),
        ("nod, pitch damped to 25%", damped(0.25)),
        ("nod, pitch ignored", { _ in (0, 0, 0) }),
    ]
    for (label, motion) in cases {
        let (low, high) = modulation(motion, positions: all)
        print(String(format: "    %@ %8.3f dB    %8.3f dB",
                     label.padding(toLength: 26, withPad: " ", startingAt: 0), low, high))
    }

    print("""

      What decides the fix: how the high-band wobble on a nod compares with the
      same wobble on a turn, and how much of it damping takes away. Turning is not
      optional — it is the entire reason the field is head-tracked — so a nod that
      wobbles no worse than a turn is not a bug to chase. A nod that wobbles
      several times worse, while contributing far less to the low band that carries
      the localisation, is a bad trade, and damping is the cheap way out of it.
    """)
}
