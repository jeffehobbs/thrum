import Foundation
import AVFoundation
import Accelerate

// The same question as `main.swift`, asked at the speed a head actually moves.
//
// The first pass swept the listener at 16.7°/s and found nothing: the pole-crossing
// buses dipped 2.5–4.2 dB, no worse than the yaw control that never comes near a
// pole. That was a flawed test, and the flaw is worth writing down because it is the
// interesting part.
//
// Near a pole, elevation is well-behaved and *azimuth* is not: a source 1° from the
// listener's up-axis swings through 180° of azimuth if the head tilts 2° past it.
// `Tools/warble` already established that this node "snaps to a filter grid on every
// axis, and snaps hardest in azimuth". So the amount of azimuth a source crosses
// between two hand-overs is the quantity under test — and that is set by how fast
// the head is moving, not merely by where it ends up. At 16.7°/s the listener moves
// 1.4° per hand-over and the polar source's azimuth is stepped gently. Looking all
// the way down at your feet is a 150–250°/s gesture, which is 13–21° per hand-over,
// and near the pole that is most of the azimuth circle in one step.
//
// Two fixes to the method, both of which matter:
//
//  1. **Sweep at realistic rates.** 25 to 400°/s, the last being the smoother's own
//     slew limit and therefore the fastest the field can legally rotate.
//  2. **One source at a time, broadband.** The first pass gave each bus its own sine
//     so sixteen buses could be separated in one render, and that was the wrong
//     trade: a sine measures the HRTF magnitude at one frequency, so its "dip" is a
//     pinna notch sliding past that frequency. It showed up as dips that followed
//     the *tone* rather than the bus when the assignment was rotated, which is the
//     tell. HRTF is linear and per-source, so rendering one source alone with real
//     drone content and measuring total energy is exact — and costs only sixteen
//     short offline renders.

/// A harmonic stack, which is what Thrum actually sounds — energy from 110 Hz up
/// through the 5–10 kHz region where elevation is encoded.
func droneBlock(_ phases: inout [Double], root: Double, frames: Int,
                into p: UnsafeMutablePointer<Float>) {
    for i in 0..<frames {
        var s = 0.0
        for h in 0..<phases.count {
            s += sin(phases[h]) / Double(h + 1)
            phases[h] += 2 * Double.pi * root * Double(h + 1) / sr
            if phases[h] > 2 * Double.pi { phases[h] -= 2 * Double.pi }
        }
        p[i] = Float(s * 0.12)
    }
}

/// Per-block level of ONE source, in dB, while the listener tilts at `rate`.
///
/// Total power across both ears and the whole spectrum: a tone that has moved from
/// one ear to the other, or whose notches have shifted, has not cut out. Only a real
/// loss of energy shows up here.
func trackOne(bus: Int, rate: Double, degrees: Double, yawInstead: Bool = false) -> [Float] {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    else { return [] }

    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    var phases = [Double](repeating: 0, count: 24)
    let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
        let list = UnsafeMutableAudioBufferListPointer(abl)
        guard let d = list.first?.mData else { return noErr }
        droneBlock(&phases, root: 110, frames: Int(frameCount),
                   into: d.assumingMemoryBound(to: Float.self))
        return noErr
    }
    audio.attach(node)
    audio.connect(node, to: env, format: mono)
    node.renderingAlgorithm = .HRTF
    node.position = SpatialField(radius: radius, lift: 22).position(bus: bus)
    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(block))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(block))
    else { return [] }

    // One hand-over per block, as on the device. The listener is placed *before*
    // each render, so block n is rendered at the angle reached by hand-over n —
    // exactly the app's ordering.
    //
    // The settling blocks are rendered at a *fixed* angle before the gesture starts,
    // rather than discarded from the front of the sweep afterwards. That ordering is
    // the whole difference between a measurement and an artifact: a fast gesture is
    // only a handful of hand-overs long — 100° at 400°/s is three — so dropping four
    // blocks from the front of the analysis silently consumed the entire sweep and
    // reported it as a clean 0.0 dB. Which is how a null result gets manufactured.
    let secondsPerBlock = Double(block) / sr
    var track: [Float] = []
    func render(at angle: Double, keep: Bool) {
        env.listenerVectorOrientation = yawInstead ? orientation(yaw: angle)
                                                   : orientation(pitch: angle)
        guard let status = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              status == .success, let l = out.floatChannelData?[0],
              let r = out.floatChannelData?[1] else { return }
        guard keep else { return }
        let n = Int(out.frameLength)
        var lp: Float = 0, rp: Float = 0
        vDSP_measqv(l, 1, &lp, vDSP_Length(n))
        vDSP_measqv(r, 1, &rp, vDSP_Length(n))
        track.append(10 * log10(max(lp + rp, 1e-12)))
    }

    for _ in 0..<settling { render(at: 0, keep: false) }
    let steps = max(2, Int((degrees / rate / secondsPerBlock).rounded()))
    for step in 0...steps { render(at: -degrees * Double(step) / Double(steps), keep: true) }
    return track
}

/// Deepest dip below the track's own median, and worst step between hand-overs.
///
/// The track handed in is already settled and is entirely gesture, so nothing is
/// dropped here.
func worst(_ track: [Float]) -> (dip: Float, step: Float, handovers: Int) {
    guard track.count >= 3 else { return (0, 0, track.count) }
    let median = track.sorted()[track.count / 2]
    var dip: Float = 0, step: Float = 0
    for v in track where median - v > dip { dip = median - v }
    for i in 1..<track.count where abs(track[i] - track[i - 1]) > step {
        step = abs(track[i] - track[i - 1])
    }
    return (dip, step, track.count)
}

/// Tilt 100° at each rate, tracking the two buses that cross a pole on the way and
/// two that never do. The controls are what make the numbers mean anything: HRTF
/// level varies with direction for every source, so the question is never "does the
/// polar bus move" but "does it move more than a bus that isn't near a pole".
func rateReport() {
    let degrees = 100.0
    // Under `orientation(pitch: -x)` the geometry check says buses 0 and 12 are the
    // two that cross a pole. Buses 2 and 6 (right·low, left·low) never exceed 22°.
    let polar = [0, 12], control = [2, 6]

    print("\nRATE — tilt \(Int(degrees))° down, one source at a time, broadband")
    print("       pole crossed at 69° by buses \(polar.map(String.init).joined(separator: " and "))")
    for rate in [25.0, 50.0, 100.0, 200.0, 400.0] {
        let perHandover = rate * Double(block) / sr
        print(String(format: "\n  %.0f°/s  (%.1f° per hand-over)", rate, perHandover))
        for bus in polar + control {
            let w = worst(trackOne(bus: bus, rate: rate, degrees: degrees))
            let tag = polar.contains(bus) ? "POLE " : "ctrl "
            print(String(format: "    %@bus %2d %-16@ dip %5.1f dB   worst step %5.1f dB   (%d hand-overs)",
                         tag, bus, SpatialField.label(bus: bus) as NSString,
                         w.dip, w.step, w.handovers))
        }
    }

    // And the listener's own control, at the fastest rate: turning your head this
    // fast does not do it, and no source reaches a pole under yaw.
    print("\n  400°/s YAW (control — no pole in this gesture)")
    for bus in polar + control {
        let w = worst(trackOne(bus: bus, rate: 400, degrees: degrees, yawInstead: true))
        print(String(format: "    yaw   bus %2d %-16@ dip %5.1f dB   worst step %5.1f dB   (%d hand-overs)",
                     bus, SpatialField.label(bus: bus) as NSString,
                     w.dip, w.step, w.handovers))
    }
}
