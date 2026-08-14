import Foundation
import AVFoundation

// Who pulls what, when — asked of the sixteen-bus graph rather than of the HRTF.
//
// `SpatialPump` (in both hosts) rests on an assumption that is nowhere checked:
// that within one output cycle, all seventeen source nodes — sixteen mono buses
// into the environment node, plus the stereo wet bed straight to the main mixer —
// are pulled exactly once each, with the same `mSampleTime` and the same frame
// count. That is what makes this correct:
//
//     if t != lastSampleTime { lastSampleTime = t; engine.renderSpatial(frames) }
//
// The first node to ask renders one block of DSP; the other sixteen recognise the
// timestamp and copy their slice out of the buffer it filled. If the assumption
// holds, every bus in a cycle sees the same block of music.
//
// If it does not hold — if the environment node pulls its inputs in chunks smaller
// than the output cycle, or pulls one input twice, or the wet node arrives on a
// different clock — then some bus copies its slice out of a buffer that has already
// been overwritten by the *next* block, or copies the same block twice. Either one
// is a per-bus fault in a mix that otherwise keeps playing, which is the only
// app-side mechanism that can make **one** drone tone misbehave while the other
// fifteen carry on. It is worth knowing whether the assumption is true before
// blaming Apple's HRTF for the report.
//
// Caveat stated up front: this is offline manual rendering, whose pull pattern is
// not guaranteed to match a live IO unit's. A clean result here is therefore weaker
// than a dirty one — it cannot exonerate the device, but an anomaly offline would
// be real.

/// One render callback, as it happened.
struct Pull {
    var node: String
    var sampleTime: Double
    var frames: Int
    var cycle: Int
}

/// Build the app's actual graph shape and record every pull for a few cycles.
func pullPattern(cycleFrames: Int, cycles: Int, rotateListener: Bool) -> [Pull] {
    final class Log {
        var pulls: [Pull] = []
        var cycle = 0
    }
    let sink = Log()

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
        let node = AVAudioSourceNode(format: mono) { _, timestamp, frameCount, abl -> OSStatus in
            sink.pulls.append(Pull(node: "bus \(bus)",
                                   sampleTime: timestamp.pointee.mSampleTime,
                                   frames: Int(frameCount), cycle: sink.cycle))
            let list = UnsafeMutableAudioBufferListPointer(abl)
            for buffer in list { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }
        audio.attach(node)
        audio.connect(node, to: env, format: mono)
        node.renderingAlgorithm = .HRTF
        node.position = field.position(bus: bus)
        nodes.append(node)
    }

    let wet = AVAudioSourceNode(format: stereo) { _, timestamp, frameCount, abl -> OSStatus in
        sink.pulls.append(Pull(node: "wet",
                               sampleTime: timestamp.pointee.mSampleTime,
                               frames: Int(frameCount), cycle: sink.cycle))
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for buffer in list { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
        return noErr
    }
    audio.attach(wet)
    audio.connect(wet, to: audio.mainMixerNode, format: stereo)
    defer { _ = nodes; _ = wet }

    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

    guard (try? audio.enableManualRenderingMode(.offline, format: stereo,
            maximumFrameCount: AVAudioFrameCount(cycleFrames))) != nil,
          (try? audio.start()) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat,
                                     frameCapacity: AVAudioFrameCount(cycleFrames))
    else { return [] }

    for cycle in 0..<cycles {
        sink.cycle = cycle
        // Rotating or still, because the report is head-angle-correlated: if the
        // pull pattern is a function of the listener orientation, that alone would
        // explain why this only happens while the head is moving.
        if rotateListener {
            env.listenerVectorOrientation = orientation(pitch: -60 - Double(cycle))
        }
        guard let status = try? audio.renderOffline(AVAudioFrameCount(cycleFrames), to: out),
              status == .success else { break }
    }
    audio.stop()
    return sink.pulls
}

/// Does each cycle pull all seventeen nodes exactly once, on one timestamp?
func reportPulls(_ label: String, cycleFrames: Int, rotateListener: Bool) {
    // Discard the first two cycles: priming a graph is not steady state.
    let pulls = pullPattern(cycleFrames: cycleFrames, cycles: 6,
                            rotateListener: rotateListener).filter { $0.cycle >= 2 }
    guard !pulls.isEmpty else { print("  \(label): no pulls recorded"); return }

    var problems: [String] = []
    for cycle in Set(pulls.map(\.cycle)).sorted() {
        let inCycle = pulls.filter { $0.cycle == cycle }
        let stamps = Set(inCycle.map(\.sampleTime))
        let frames = Set(inCycle.map(\.frames))
        // One pull per node per cycle.
        var counts: [String: Int] = [:]
        for p in inCycle { counts[p.node, default: 0] += 1 }
        let repeated = counts.filter { $0.value != 1 }
        // Every bus, and the wet bed, present.
        let missing = (0..<buses).map { "bus \($0)" }.filter { counts[$0] == nil }
            + (counts["wet"] == nil ? ["wet"] : [])

        if stamps.count != 1 {
            problems.append("cycle \(cycle): \(stamps.count) distinct timestamps "
                + "(\(stamps.sorted().map { String(format: "%.0f", $0) }.joined(separator: ", ")))")
        }
        if frames.count != 1 {
            problems.append("cycle \(cycle): mixed frame counts \(frames.sorted())")
        }
        if !repeated.isEmpty {
            problems.append("cycle \(cycle): pulled more than once — "
                + repeated.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", "))
        }
        if !missing.isEmpty {
            problems.append("cycle \(cycle): never pulled — \(missing.joined(separator: ", "))")
        }
    }

    let perCycle = Double(pulls.count) / Double(Set(pulls.map(\.cycle)).count)
    print(String(format: "  %@: %.1f pulls/cycle", label, perCycle))
    if problems.isEmpty {
        print("  ok    all 17 nodes pulled once per cycle, one timestamp, uniform frames"
              + " — the pump's assumption holds")
    } else {
        for p in problems.prefix(8) { print("  FAIL  \(p)") }
        if problems.count > 8 { print("  …and \(problems.count - 8) more") }
    }
    // The order matters too: whichever node is pulled first is the one that runs
    // the DSP, and if that changes cycle to cycle the render happens at a different
    // point in the sequence each time. Not a fault by itself — worth seeing.
    let firsts = Set(Set(pulls.map(\.cycle)).map { cycle in
        pulls.first { $0.cycle == cycle }!.node
    })
    print("  first pulled: \(firsts.sorted().joined(separator: ", "))")
}
