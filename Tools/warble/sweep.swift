import AVFoundation

// The other half of the warble measurement: what a *moving* listener does to a
// sounding drone, as opposed to what two held positions differ by.
//
// `staircase` in main.swift compares steady states, and it refuted the obvious
// story — AVAudioEnvironmentNode's HRTF snaps to a grid on every axis, and yaw
// snaps harder than pitch. So whatever is heard on the up-down axis is not "pitch
// has a coarser filter set". That leaves the transition itself: the app hands the
// node a new orientation about twelve times a second (an ~85 ms IO buffer), and if
// the node switches filters without crossfading, every hand-over is a small
// discontinuity in a sustained tone.
//
// A discontinuity is a click, and a click repeating twelve times a second is a
// warble. It also explains the listener's clue that the high voices suffer most:
// the size of a phase break scales with frequency, so the same angular step lands
// as a fraction of a cycle on a 110 Hz fundamental and as several cycles on a
// partial at 5 kHz.
//
// This renders continuously while rotating the listener, and measures how much
// excess high-frequency energy appears *at the block boundaries* — where a
// hand-over happens — against the interior of the same blocks, which is the same
// signal with no hand-over in it.

/// Render `blocks` blocks while stepping the listener by `degreesPerSecond` on one
/// axis, updating the orientation once per block exactly as the app does.
/// Returns (boundary roughness, interior roughness).
func sweepRender(axis: String, degreesPerSecond: Double, hz: Double,
                 positions: [AVAudio3DPoint], blocks: Int = 120) -> (Double, Double) {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    else { return (0, 0) }
    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    var nodes: [AVAudioSourceNode] = []
    for position in positions {
        var phase = 0.0
        // A single partial, so the metric is about one frequency at a time — the
        // whole question is how the artefact scales with pitch.
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
    else { return (0, 0) }

    let perBlock = degreesPerSecond * Double(block) / sr
    var angle = 0.0
    var stitched = [Float]()
    for _ in 0..<blocks {
        let a = Float(angle)
        switch axis {
        case "pitch": env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: a, roll: 0)
        case "yaw":   env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: a, pitch: 0, roll: 0)
        case "roll":  env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: a)
        default:      break            // "still" — never moves
        }
        angle += perBlock
        guard let st = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              st == .success else { break }
        if let a = out.floatChannelData?[0] {
            stitched.append(contentsOf: UnsafeBufferPointer(start: a, count: Int(out.frameLength)))
        }
    }
    audio.stop()

    // Roughness = mean |second difference|, which is flat for a clean sine and
    // spikes at a discontinuity. Measured in an 8-sample window either side of
    // each block boundary, against the interior of the same render.
    guard stitched.count > block * 4 else { return (0, 0) }
    func roughness(_ range: [Int]) -> Double {
        var sum = 0.0
        for n in range where n >= 2 && n < stitched.count {
            sum += abs(Double(stitched[n]) - 2 * Double(stitched[n - 1]) + Double(stitched[n - 2]))
        }
        return range.isEmpty ? 0 : sum / Double(range.count)
    }
    var boundary: [Int] = [], interior: [Int] = []
    // Skip the first few blocks: the HRTF and the node's own ramp-in settle there.
    for b in 4..<(stitched.count / block) {
        let edge = b * block
        boundary.append(contentsOf: (edge - 8)..<(edge + 8))
        interior.append(contentsOf: (edge + block / 2 - 8)..<(edge + block / 2 + 8))
    }
    return (roughness(boundary), roughness(interior))
}

/// Called from main.swift — only one file in a Swift executable may have
/// top-level code.
func handoverReport() {
    print("""

    — what a hand-over sounds like, per axis and per frequency —

      The app writes a new listener orientation about twelve times a second. If the
      node crossfades, the waveform at a block boundary looks like the waveform in
      the middle of a block and the ratio below is 1. If it switches filters
      outright, the boundary carries a step the middle does not, and the ratio
      climbs.

      ratio = roughness at the hand-over ÷ roughness in the same block's interior
      (1.0 = indistinguishable; higher = an audible step every 85 ms)
    """)
    let sweepField = field()
    print("\n            source        still     yaw 20°/s   pitch 20°/s   roll 20°/s")
    for hz in [110.0, 440.0, 1760.0, 5000.0] {
        var line = String(format: "  %8.0f Hz partial ", hz)
        for axis in ["still", "yaw", "pitch", "roll"] {
            let (edge, mid) = sweepRender(axis: axis, degreesPerSecond: 20, hz: hz,
                                          positions: sweepField)
            line += String(format: "  %10.2f", mid > 0 ? edge / mid : 0)
        }
        print(line)
    }

    print("""

      Read it against the listener's own clue: if the ratio grows with frequency,
      the hand-over is a phase break rather than a level change, and the fix is to
      hand over less often or not at all on the axis that buys the least — not to
      smooth harder, because a smoother still has to deliver its output through the
      same twelve-times-a-second hand-over.
    """)
}
