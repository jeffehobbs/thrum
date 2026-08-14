import Foundation
import AVFoundation
import Accelerate
import simd

// The whole chain at once: real music, real HRTFs, and a head that looks at its feet.
//
// Every harness before this took one half of the system and gave the other half a
// stand-in. `Tools/pole` drove real HRTFs with synthetic tones and a synthetic head.
// The first half of `Tools/dropout` drove the real engine with real Flow but stopped
// at the bus outputs, before any HRTF and with no head at all. Both came back clean,
// and neither of them can see a fault that only exists when the two halves are put
// together — which is precisely what the report describes: "some combination of head
// tracking coordinates is causing the tone to cut out."
//
// So this runs the shipped path end to end:
//
//   DroneEngine + Flow → 16 mono buses → AVAudioEnvironmentNode (HRTF) → stereo
//                            ↑
//                    a simulated head, through the real `HeadSmoother`,
//                    the real 0.3° dead band and the real 45 ms rate cap
//
// **The measurement is a transfer gain, and that is what makes it able to answer the
// question.** Comparing the final stereo level against its own past cannot separate
// "the music got quieter" from "the renderer lost a voice" — Flow is moving the music
// the whole time, which is why the first pass turned up 59 events that were all just
// Flow breathing. So each block is measured twice: once at the bus outputs, before
// any spatialisation, and once at the stereo output. The ratio is what the HRTF stage
// did to the material it was given. Flow cancels out of it exactly.
//
// A sudden dip in that ratio is a voice being lost between the engine and the ears,
// with the head motion that caused it recorded alongside.

/// A head on a walk, with a gesture the listener says reproduces the fault.
///
/// Ordinary walking is a small continuous sway — the head is never still, but it is
/// never fast either. Onto that is layered the reported trigger, once every twenty
/// seconds: look all the way down towards your feet, hold, come back up.
struct SimulatedHead {
    /// Where the tilt goes. 75° below the reference horizon is "looking at my feet"
    /// for someone walking, and it takes the field's low ring past the listener's
    /// down-pole on the way — the geometry `Tools/pole` cleared in isolation.
    ///
    /// **Positive**, and the sign was wrong here first time round. Gaze elevation is
    /// `asin(forward.y)`, and `HeadSmoother.rotation` maps *negative* CoreMotion pitch
    /// onto a *positive* `forward.y` — so `-75` pointed the simulated head at the sky
    /// and the harness reported a clean result for a gesture it was not performing.
    /// Verified against the node's own readback: pitch −5° yields forward (0, 0.09,
    /// −1.00), i.e. gaze +5°.
    static let lookDown = 75.0
    static let period = 20.0
    static let fall = 0.6, hold = 1.5, rise = 1.2

    func angles(at t: Double) -> (yaw: Double, pitch: Double, roll: Double) {
        // The sway: a slow figure-of-eight, a few degrees, as a body walks.
        let sway = 4.0 * sin(2 * .pi * t / 3.1)
        let bob = 3.0 * sin(2 * .pi * t / 1.6)
        let tiltRoll = 2.5 * sin(2 * .pi * t / 4.3)

        // The gesture.
        let phase = t.truncatingRemainder(dividingBy: Self.period)
        var look = 0.0
        if phase < Self.fall {
            let x = phase / Self.fall
            look = Self.lookDown * (x * x * (3 - 2 * x))          // smoothstep down
        } else if phase < Self.fall + Self.hold {
            look = Self.lookDown
        } else if phase < Self.fall + Self.hold + Self.rise {
            let x = (phase - Self.fall - Self.hold) / Self.rise
            look = Self.lookDown * (1 - x * x * (3 - 2 * x))      // and back up
        }
        return (yaw: sway, pitch: bob + look, roll: tiltRoll)
    }
}

/// The host's own gate on how often the listener is re-pointed, reproduced exactly —
/// dead band and rate cap both, because they are part of the shipped path and a fault
/// that only appears when an update is *withheld* would be invisible without them.
struct ListenerGate {
    var facing = (forward: simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))
    var lastWrite = -1.0

    mutating func shouldWrite(_ o: AVAudio3DVectorOrientation, now: Double) -> Bool {
        let f = simd_float3(o.forward.x, o.forward.y, o.forward.z)
        let u = simd_float3(o.up.x, o.up.y, o.up.z)
        let moved = max(simd_length(f - facing.forward), simd_length(u - facing.up)) * 180 / .pi
        guard moved > 0.3 else { return false }
        guard now - lastWrite > 0.045 else { return false }
        lastWrite = now
        facing = (f, u)
        return true
    }
}

@MainActor
func runTracked(minutes: Double) {
    let engine = DroneEngine()
    engine.setSampleRate(sr)
    let model = ThrumModel(engine: engine)
    model.spatialEnabled = true
    engine.spatialEnabled = true
    model.flow.picksKeyOnStart = true
    model.flow.start()

    let audio = AVAudioEngine()
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
    let env = AVAudioEnvironmentNode()
    audio.attach(env)
    env.outputType = .headphones
    audio.connect(env, to: audio.mainMixerNode, format: stereo)

    let field = SpatialField()
    var nodes: [AVAudioSourceNode] = []
    for bus in 0..<buses {
        let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let d = list.first?.mData else { return noErr }
            engine.copyBus(bus, Int(frameCount), into: d.assumingMemoryBound(to: Float.self))
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
    else { return }

    let scratch = fbuf(block)
    defer { scratch.deallocate() }

    // Flow ramps Radius and Lift continuously, and the host rewrites all sixteen
    // source positions when it does — up to every 40 ms. Leaving that out was a real
    // gap rather than a simplification: **Lift is what moves the two rings towards
    // the poles**, so the geometry under test is not fixed at its default while a
    // session runs. A harness that pins it at 22° is testing one slice of a field
    // that Flow is deliberately opening and closing.
    var fieldDirty = false
    var placed = SpatialField()
    var lastFieldApply = -1.0
    var fieldUpdates = 0
    var liftSeen: [Double] = []
    var radiusSeen: [Double] = []
    model.onFieldChange = { fieldDirty = true }

    var smoother = HeadSmoother()
    var gate = ListenerGate()
    let head = SimulatedHead()
    var nextMotionSample = 0.0

    let blocks = Int(minutes * 60 / step)
    var transfer: [Float] = []      // stereo out minus bus in, dB
    var tilt: [Double] = []         // gaze elevation at that block
    var writes = 0

    for i in 0..<blocks {
        let t = Double(i) * step

        // The motion stream, at the AirPods' real 50 Hz rather than the block rate.
        while nextMotionSample <= t {
            let a = head.angles(at: nextMotionSample)
            let outStep = smoother.step(yaw: a.yaw, pitch: a.pitch, roll: a.roll, dt: 0.02)
            if gate.shouldWrite(outStep.head.orientation, now: nextMotionSample) {
                env.listenerVectorOrientation = outStep.head.orientation
                writes += 1
            }
            nextMotionSample += 0.02
        }

        // The host's own coalescing: mark dirty, apply at most every 40 ms, and only
        // when the geometry has actually moved enough to hear.
        if fieldDirty, t - lastFieldApply > 0.04 {
            fieldDirty = false
            let f = model.field
            if abs(f.radius - placed.radius) > 0.01 || abs(f.lift - placed.lift) > 0.1 {
                placed = f
                for (bus, node) in nodes.enumerated() { node.position = f.position(bus: bus) }
                fieldUpdates += 1
                liftSeen.append(f.lift)
                radiusSeen.append(f.radius)
            }
            lastFieldApply = t
        }

        model.flow.advance(by: step)
        engine.renderSpatial(frameCount: block)

        // What went in, summed across the sixteen buses, before any spatialisation.
        var inPower: Float = 0
        for b in 0..<buses {
            engine.copyBus(b, block, into: scratch)
            var p: Float = 0
            vDSP_measqv(scratch, 1, &p, vDSP_Length(block))
            inPower += p
        }

        guard let status = try? audio.renderOffline(AVAudioFrameCount(block), to: out),
              status == .success, let l = out.floatChannelData?[0],
              let r = out.floatChannelData?[1] else { break }
        var lp: Float = 0, rp: Float = 0
        vDSP_measqv(l, 1, &lp, vDSP_Length(Int(out.frameLength)))
        vDSP_measqv(r, 1, &rp, vDSP_Length(Int(out.frameLength)))

        // Only meaningful while there is material to transfer, and not while the
        // graph is still priming — the first blocks of any render are a transient,
        // which is what produced a spurious "deepest dip at 0.0 s" first time round.
        guard inPower > 1e-9, t > 1.0 else { continue }
        transfer.append(10 * log10(max(lp + rp, 1e-12) / inPower))
        tilt.append(smoother.orientation.forward.y == 0 ? 0
                    : asin(max(-1, min(1, Double(smoother.orientation.forward.y)))) * 180 / .pi)

        if blocks > 10, i % (blocks / 10) == 0 {
            print("  … \(i * 100 / blocks)%", terminator: "\r"); fflush(stdout)
        }
    }

    print(String(format: "\n  field: %d position rewrites, radius %.2f–%.2f m, lift %.0f–%.0f°",
                 fieldUpdates, radiusSeen.min() ?? 0, radiusSeen.max() ?? 0,
                 liftSeen.min() ?? 0, liftSeen.max() ?? 0))
    reportTracked(transfer: transfer, tilt: tilt, writes: writes, minutes: minutes)
}

func reportTracked(transfer: [Float], tilt: [Double], writes: Int, minutes: Double) {
    guard transfer.count > 100 else { print("\nTRACKED — too short"); return }
    let sorted = transfer.sorted()
    let median = sorted[sorted.count / 2]
    print("\nTRACKED — \(String(format: "%.0f", minutes)) min of Flow through 16 HRTFs "
          + "with a head that looks at its feet every \(Int(SimulatedHead.period)) s")
    print(String(format: "  %d blocks, %d listener writes (%.1f/s)",
                 transfer.count, writes, Double(writes) / (minutes * 60)))
    print(String(format: "  transfer gain: median %.1f dB, min %.1f, max %.1f, p1 %.1f",
                 median, sorted.first!, sorted.last!, sorted[sorted.count / 100]))

    // A dip in transfer gain is the HRTF stage losing material it was given. Flow
    // cancels out, so anything here is spatialisation.
    var worst: (dip: Float, at: Int) = (0, 0)
    for (i, v) in transfer.enumerated() where median - v > worst.dip { worst = (median - v, i) }
    var worstStep: (db: Float, at: Int) = (0, 0)
    for i in 1..<transfer.count where abs(transfer[i] - transfer[i - 1]) > worstStep.db {
        worstStep = (abs(transfer[i] - transfer[i - 1]), i)
    }
    print(String(format: "  deepest dip below median: %.1f dB at %.1f s (gaze %+.0f°)",
                 worst.dip, Double(worst.at) * step, tilt[worst.at]))
    print(String(format: "  worst block-to-block step: %.1f dB at %.1f s (gaze %+.0f°)",
                 worstStep.db, Double(worstStep.at) * step, tilt[worstStep.at]))

    // And the question the listener actually asked: does it depend on where the head
    // is pointing? Bucket the transfer gain by gaze elevation.
    print("\n  transfer gain by gaze elevation (the reported trigger is the bottom row)")
    for lo in stride(from: 70.0, through: -90.0, by: -20.0) {
        let hi = lo + 20
        let band = zip(transfer, tilt).filter { $0.1 >= lo && $0.1 < hi }.map(\.0)
        guard band.count > 5 else { continue }
        let s = band.sorted()
        print(String(format: "    %+4.0f…%+4.0f°  n %6d   median %6.1f dB   min %6.1f dB",
                     lo, hi, band.count, s[s.count / 2], s.first!))
    }

    print(worst.dip < 10
          ? "\n  ok    the HRTF stage never loses more than a few dB of what it is given, "
            + "at any gaze angle"
          : "\n  FOUND the spatial stage drops material at particular head angles")
}
