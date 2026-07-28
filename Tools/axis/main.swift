import AVFoundation

// Determines AVAudioEnvironmentNode's actual sign conventions by measuring which
// ear a single source lands in. Everything about head tracking depends on this,
// none of it is written down unambiguously, and deriving it by hand gets it
// wrong — the first version of Thrum's head tracking passed CoreMotion's angles
// straight through on the strength of a right-hand-rule argument that turned out
// to be inverted, which made the field swing the wrong way.
//
//   swiftc -O -o /tmp/thrumaxis Tools/axis/main.swift && /tmp/thrumaxis
//
// Measured on macOS 26: positions are -z ahead, +x right, +y up. Listener
// yaw/roll are the other handedness from CoreMotion — positive turns the
// listener clockwise (to their right), where positive CoreMotion attitude is
// counterclockwise. Hence the negation in ThrumHost.

let sr = 48000.0, block = 512

/// Renders one mono source at `pos` with the listener at `orientation`, and
/// returns (left energy, right energy).
func ears(pos: AVAudio3DPoint, yaw: Float = 0, pitch: Float = 0, roll: Float = 0) -> (Double, Double) {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return (0,0) }
    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    var phase = 0.0
    let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
        let list = UnsafeMutableAudioBufferListPointer(abl)
        guard let d = list.first?.mData else { return noErr }
        let p = d.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(frameCount) {
            p[i] = Float(sin(phase) * 0.5)
            phase += 2 * Double.pi * 440 / sr
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        return noErr
    }
    audio.attach(node)
    audio.connect(node, to: env, format: mono)
    node.renderingAlgorithm = .HRTF
    node.position = pos
    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: yaw, pitch: pitch, roll: roll)

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(block))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(block)) else { return (0,0) }
    var l = 0.0, r = 0.0, frames = 0
    while frames < Int(sr) {                        // one second
        guard let st = try? audio.renderOffline(AVAudioFrameCount(block), to: out), st == .success else { break }
        let n = Int(out.frameLength)
        if frames > block * 4 {                      // let the HRTF settle
            if let a = out.floatChannelData?[0] { for i in 0..<n { l += Double(a[i]) * Double(a[i]) } }
            if let b = out.floatChannelData?[1] { for i in 0..<n { r += Double(b[i]) * Double(b[i]) } }
        }
        frames += n
    }
    audio.stop()
    return (l, r)
}

func side(_ l: Double, _ r: Double) -> String {
    let total = l + r
    guard total > 1e-12 else { return "silent" }
    let bias = (r - l) / total
    if abs(bias) < 0.04 { return "centred" }
    return bias > 0 ? String(format: "RIGHT (%.0f%%)", bias * 100) : String(format: "LEFT (%.0f%%)", -bias * 100)
}

let r = 1.6
print("\n— position axes (listener facing default) —")
let ahead  = ears(pos: AVAudio3DPoint(x: 0, y: 0, z: Float(-r)))
print("  source at -z (my 'ahead'): \(side(ahead.0, ahead.1))")
let right  = ears(pos: AVAudio3DPoint(x: Float(r), y: 0, z: 0))
print("  source at +x              : \(side(right.0, right.1))")
let left   = ears(pos: AVAudio3DPoint(x: Float(-r), y: 0, z: 0))
print("  source at -x              : \(side(left.0, left.1))")

print("\n— listener yaw sign —")
for y in [Float(90), Float(-90)] {
    let e = ears(pos: AVAudio3DPoint(x: 0, y: 0, z: Float(-r)), yaw: y)
    print(String(format: "  source ahead, listener yaw %+.0f°: %@", y, side(e.0, e.1)))
}
print("\n— listener roll sign (source directly overhead) —")
let above = ears(pos: AVAudio3DPoint(x: 0, y: Float(r), z: 0))
print("  source at +y, no roll     : \(side(above.0, above.1))")
for rr in [Float(90), Float(-90)] {
    let e = ears(pos: AVAudio3DPoint(x: 0, y: Float(r), z: 0), roll: rr)
    print(String(format: "  source overhead, roll %+.0f°: %@", rr, side(e.0, e.1)))
}

print("""

  Read it like this: if yaw +90 puts an source that was ahead into the RIGHT ear,
  then positive yaw turned the listener to their LEFT. Head tracking wants the
  listener to turn the same way the head does, so a physical left turn must
  produce that same sign.
""")
