import AVFoundation

/// Measures the *real* output of spatial mode, after the HRTF.
///
/// This matters because the engine's limiter can only detect the mono sum of its
/// sixteen buses, and that is not what leaves the machine. `AVAudioEnvironmentNode`
/// filters each bus through a head-related transfer function whose gain is not
/// unity, then sums sixteen of them per ear — so the binaural peak can sit well
/// above the mono sum the limiter was watching. If it lands over ±1 the output
/// device clips, and clipping on a sustained drone is heard as faint crackle that
/// only shows up when the level is high.
///
/// Manual rendering mode lets us build the app's exact graph offline and read the
/// samples that would have been played.
enum Binaural {
    struct Result {
        var peak: Float
        var rms: Float
        var overs: Int          // samples at or past full scale
        var frames: Int
        /// Wall time to render, so the HRTF stage can be costed. This is the
        /// number the app's DSP badge cannot see: it times DroneEngine only, and
        /// the sixteen HRTFs live downstream inside AVAudioEnvironmentNode.
        var seconds: Double
    }

    static func measure(_ kernel: DroneEngine, sampleRate: Double,
                        seconds: Double, block: Int = 512,
                        algorithm: AVAudio3DMixingRenderingAlgorithm = .HRTF,
                        buses: Int = DroneEngine.spatialBusCount) -> Result? {
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { return nil }

        kernel.spatialEnabled = true
        let audio = AVAudioEngine()
        let environment = AVAudioEnvironmentNode()
        audio.attach(environment)
        environment.outputType = .headphones
        audio.connect(environment, to: audio.mainMixerNode, format: stereo)

        // Same timestamp latch as the app: one engine render per cycle.
        final class Pump {
            let kernel: DroneEngine
            var last: Double = -1
            init(_ k: DroneEngine) { kernel = k }
            func go(_ ts: UnsafePointer<AudioTimeStamp>, _ n: Int) {
                let t = ts.pointee.mSampleTime
                if t != last { last = t; kernel.renderSpatial(frameCount: n) }
            }
        }
        let pump = Pump(kernel)
        let field = SpatialField()

        for bus in 0..<buses {
            let node = AVAudioSourceNode(format: mono) { _, ts, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let first = list.first, let data = first.mData else { return noErr }
                pump.go(ts, Int(frameCount))
                kernel.copyBus(bus, Int(frameCount), into: data.assumingMemoryBound(to: Float.self))
                return noErr
            }
            audio.attach(node)
            audio.connect(node, to: environment, format: mono)
            node.renderingAlgorithm = algorithm
            node.position = field.position(bus: bus)
        }

        let wet = AVAudioSourceNode(format: stereo) { _, ts, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let ld = list[0].mData, let rd = list[1].mData else { return noErr }
            pump.go(ts, Int(frameCount))
            kernel.copyWet(Int(frameCount),
                           ld.assumingMemoryBound(to: Float.self),
                           rd.assumingMemoryBound(to: Float.self))
            return noErr
        }
        audio.attach(wet)
        audio.connect(wet, to: audio.mainMixerNode, format: stereo)
        audio.mainMixerNode.outputVolume = 1.0

        do {
            try audio.enableManualRenderingMode(.offline, format: stereo,
                                                maximumFrameCount: AVAudioFrameCount(block))
            try audio.start()
        } catch {
            print("      manual rendering unavailable: \(error.localizedDescription)")
            return nil
        }

        guard let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                         frameCapacity: AVAudioFrameCount(block)) else { return nil }

        var peak: Float = 0
        var sum = 0.0
        var overs = 0
        var frames = 0
        let total = Int(seconds * sampleRate)
        let started = Date()
        while frames < total {
            let want = AVAudioFrameCount(min(block, total - frames))
            guard let status = try? audio.renderOffline(want, to: out), status == .success else { break }
            let n = Int(out.frameLength)
            for ch in 0..<Int(out.format.channelCount) {
                guard let p = out.floatChannelData?[ch] else { continue }
                for i in 0..<n {
                    let a = abs(p[i])
                    if a > peak { peak = a }
                    if a >= 0.999 { overs += 1 }
                    sum += Double(p[i]) * Double(p[i])
                }
            }
            frames += n
        }
        let wall = Date().timeIntervalSince(started)
        audio.stop()
        let count = Double(max(1, frames * Int(out.format.channelCount)))
        return Result(peak: peak, rms: Float((sum / count).squareRoot()),
                      overs: overs, frames: frames, seconds: wall)
    }
}
