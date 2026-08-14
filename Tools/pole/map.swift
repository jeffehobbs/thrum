import Foundation
import AVFoundation
import Accelerate

// Is there a *direction* where a voice nearly vanishes?
//
// The last question left standing after everything else was cleared. The 08-13
// flight log settles the mechanical explanations from the device's side: over 42
// minutes of head-tracked walking, `gaps 0` and `overruns 0` on all 84 heartbeats —
// the audio never had a hole in it — with the motion stream at a solid 50 Hz and the
// head's own rate at a median 144°/s. Nothing stalled, nothing overran, nothing was
// rate-limited except five frames at a reference re-seat. And offline, the node
// interpolates through a pole crossing within 2.6 dB.
//
// So the audio is continuous and the geometry is smooth, and yet a listener reliably
// hears a tone go away when they look at their feet. Which leaves the possibility
// that nothing is malfunctioning at all: that the HRTF, working exactly as designed,
// has directions in it where a source loses most of its energy — and that Thrum's
// field puts a voice into one of them when the head tilts far enough.
//
// That is not a bug in anyone's code, but it *is* something this app can fix, because
// it chooses where its sources sit. If there is a hole in the sphere, the field can
// be shaped to keep sixteen drone voices out of it.
//
// So: sweep the whole sphere, one source at a time, and measure total rendered energy
// per direction. Two roots, because elevation is carried by pinna notches at 5–10 kHz
// and a 110 Hz stack has little to lose up there — if the effect is real it should be
// stronger on the high voices, which is what the listener reported the first time.

/// Total rendered energy of a source at one direction, in dB, once settled.
func energy(azimuth: Double, elevation: Double, root: Double) -> Float {
    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    else { return 0 }

    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    var phases = [Double](repeating: 0, count: 24)
    let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
        let list = UnsafeMutableAudioBufferListPointer(abl)
        guard let d = list.first?.mData else { return noErr }
        droneBlock(&phases, root: root, frames: Int(frameCount),
                   into: d.assumingMemoryBound(to: Float.self))
        return noErr
    }
    audio.attach(node)
    audio.connect(node, to: env, format: mono)
    node.renderingAlgorithm = .HRTF

    let az = azimuth * .pi / 180, el = elevation * .pi / 180
    node.position = AVAudio3DPoint(x: Float(radius * cos(el) * sin(az)),
                                   y: Float(radius * sin(el)),
                                   z: Float(-radius * cos(el) * cos(az)))
    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    env.listenerVectorOrientation = orientation()

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(block))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(block))
    else { return 0 }

    var last: Float = 0
    for _ in 0..<(settling + 2) {
        guard let s = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              s == .success, let l = out.floatChannelData?[0],
              let r = out.floatChannelData?[1] else { break }
        var lp: Float = 0, rp: Float = 0
        vDSP_measqv(l, 1, &lp, vDSP_Length(Int(out.frameLength)))
        vDSP_measqv(r, 1, &rp, vDSP_Length(Int(out.frameLength)))
        last = 10 * log10(max(lp + rp, 1e-12))
    }
    audio.stop()
    return last
}

/// The whole sphere, coarse, looking for outliers rather than for detail.
func sphereMap() {
    print("\nSPHERE — total rendered energy per direction, relative to the loudest")
    print("         a 'hole' would be a direction many dB below its neighbours")
    for root in [110.0, 880.0] {
        var grid: [(az: Double, el: Double, db: Float)] = []
        for el in stride(from: -90.0, through: 90.0, by: 15) {
            for az in stride(from: 0.0, to: 360.0, by: 30) {
                grid.append((az, el, energy(azimuth: az, elevation: el, root: root)))
                if abs(el) == 90 { break }   // one point at each pole, not twelve
            }
        }
        let loudest = grid.map(\.db).max() ?? 0
        let quietest = grid.min { $0.db < $1.db }!
        print(String(format: "\n  root %.0f Hz — %d directions, spread %.1f dB",
                     root, grid.count, loudest - quietest.db))
        print(String(format: "    quietest: az %.0f° el %.0f° at %.1f dB below the loudest",
                     quietest.az, quietest.el, loudest - quietest.db))

        // Elevation profile: average over azimuth, which is the shape that matters
        // for a field built as two rings at fixed elevation.
        print("    by elevation (mean over azimuth, dB below loudest):")
        for el in stride(from: 90.0, through: -90.0, by: -15) {
            let band = grid.filter { $0.el == el }
            let mean = band.map { loudest - $0.db }.reduce(0, +) / Float(band.count)
            let bar = String(repeating: "▏", count: max(0, Int(mean.rounded())))
            print(String(format: "      %+4.0f°  %5.1f  %@", el, mean, bar as NSString))
        }
    }
}
