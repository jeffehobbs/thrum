// Does the spatial ring survive being rendered to 5.1?
//
//   swiftc -O -o /tmp/thrumsurround Shared/Spatial.swift Tools/surround/main.swift
//   /tmp/thrumsurround
//
// The Apple TV app asks the environment node for a six-channel output, because
// HRTF and HRTFHQ render to a stereo pair and nothing else. Which per-bus
// rendering algorithm then actually spreads sixteen compass points across
// L / R / C / LFE / Ls / Rs — rather than collapsing them to the front pair,
// pouring the bass tier into the LFE, or (as it turned out) rendering nothing
// at all — is not something the header says. This measures it, offline, through a real
// `AVAudioEnvironmentNode` in manual rendering mode with the same channel
// layout the television will be handed (MPEG 5.1 A: L R C LFE Ls Rs).
//
// One mono source, moved bus by bus around `SpatialField`'s ring, half a
// second of 220 Hz per position, RMS per output channel. Then the same for the
// two places the reverb's wet pair is parked. The asserts at the bottom are
// the ones the app's design depends on: ahead is front, behind is surround,
// right is right.

import Foundation
import AVFoundation

let sampleRate = 48_000.0
let frames: AVAudioFrameCount = 1024

guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A) else {
    fatalError("no 5.1 layout")
}
let six = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
    fatalError("no mono format")
}
let channelNames = ["L", "R", "C", "LFE", "Ls", "Rs"]

let engine = AVAudioEngine()
let environment = AVAudioEnvironmentNode()

// The source: a sine, phase carried across calls.
var phase = 0.0
let frequency = CommandLine.arguments.dropFirst().compactMap(Double.init).first ?? 220.0
let source = AVAudioSourceNode(format: mono) { _, _, count, abl -> OSStatus in
    let list = UnsafeMutableAudioBufferListPointer(abl)
    guard let out = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let inc = 2 * Double.pi * frequency / sampleRate
    for i in 0..<Int(count) {
        out[i] = Float(sin(phase)) * 0.5
        phase += inc
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
    }
    return noErr
}

engine.attach(environment)
engine.attach(source)
do {
    try engine.enableManualRenderingMode(.offline, format: six, maximumFrameCount: frames)
} catch {
    fatalError("manual rendering: \(error)")
}
// The connection that decides everything downstream, and the one that is easy
// to leave implicit: without it AVAudioEngine wires the main mixer to the
// output in **stereo**, whatever the manual-rendering (or hardware) format,
// and then folds the environment's six channels down to two before the output
// node ever sees them. The symptom is not silence — it is a perfectly good 5.1
// image downmixed to L/R, which reads as "auto only pans across the front pair"
// and cost an hour here. Connect the mixer to the output in six channels first,
// then hang the environment off it.
engine.connect(engine.mainMixerNode, to: engine.outputNode, format: six)
engine.connect(environment, to: engine.mainMixerNode, format: six)
engine.connect(source, to: environment, format: mono)
environment.outputType = .externalSpeakers
environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
    forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
// No room of the node's own — Thrum brings its own reverb.
environment.reverbParameters.enable = false

source.sourceMode = .pointSource

do { try engine.start() } catch { fatalError("start: \(error)") }

// `applicableRenderingAlgorithms` is `[NSNumber]` in Swift, not the enum.
let applicableAlgorithms = environment.applicableRenderingAlgorithms
    .compactMap { AVAudio3DMixingRenderingAlgorithm(rawValue: $0.intValue) }
let applicable = applicableAlgorithms.map { alg -> String in
    switch alg {
    case .equalPowerPanning: return "equalPowerPanning"
    case .sphericalHead:     return "sphericalHead"
    case .HRTF:              return "HRTF"
    case .soundField:        return "soundField"
    case .stereoPassThrough: return "stereoPassThrough"
    case .HRTFHQ:            return "HRTFHQ"
    case .auto:              return "auto"
    @unknown default:        return "?\(alg.rawValue)"
    }
}
print("output format: \(six.channelCount) ch, layout \(layout.layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A ? "MPEG_5_1_A" : "?")")
print("applicable rendering algorithms at 5.1: \(applicable.joined(separator: ", "))")
let soundFieldOK = applicableAlgorithms.contains(.soundField)
print(soundFieldOK ? "✓ soundField is applicable" : "✗ soundField NOT applicable")

guard let buffer = AVAudioPCMBuffer(pcmFormat: six, frameCapacity: frames) else { fatalError("buffer") }

/// Render `seconds` at the source's current position and return per-channel RMS.
func measure(seconds: Double, settle: Double = 0.15) -> [Double] {
    var sums = [Double](repeating: 0, count: Int(six.channelCount))
    var counted = 0
    let total = Int(seconds * sampleRate)
    let skip = Int(settle * sampleRate)
    var rendered = 0
    while rendered < total {
        let n = min(Int(frames), total - rendered)
        let status = try! engine.renderOffline(AVAudioFrameCount(n), to: buffer)
        guard status == .success, let data = buffer.floatChannelData else { break }
        if rendered >= skip {
            for ch in 0..<Int(six.channelCount) {
                var s = 0.0
                for i in 0..<Int(buffer.frameLength) { s += Double(data[ch][i] * data[ch][i]) }
                sums[ch] += s
            }
            counted += Int(buffer.frameLength)
        }
        rendered += n
    }
    return sums.map { counted > 0 ? sqrt($0 / Double(counted)) : 0 }
}

// The finding that shaped the television host, measured here so it is not
// re-derived from the header: at a 5.1 output the node *lists* soundField as
// applicable and then renders **silence** with it — every channel, every
// position. `.auto` is the algorithm that actually distributes a point source
// across the six channels (a front-right source lands in R with a little Rs),
// so the app uses `.auto` and this harness measures with it. soundField is
// probed first, so a future OS that fixes it shows up as a changed line.
source.position = AVAudio3DPoint(x: 1, y: 0, z: -1)
let skipSF = ProcessInfo.processInfo.environment["NOSF"] == "1"
if !skipSF { source.renderingAlgorithm = .soundField }
let soundFieldPeak = skipSF ? -1 : (measure(seconds: 0.3).max() ?? 0)
print(String(format: "soundField at 5.1 renders peak RMS %.4f — %@", soundFieldPeak,
             (soundFieldPeak < 1e-4 ? "SILENT (known; the app uses .auto)" : "audible — re-examine the choice of .auto") as NSString))
source.renderingAlgorithm = .auto
_ = measure(seconds: 0.2)   // let the algorithm switch settle before the table
if ProcessInfo.processInfo.environment["DEBUGPOS"] == "1" {
    print("DEBUG auto at (1,0,-1):", measure(seconds: 0.3).map { String(format: "%.3f", $0) })
}

func dB(_ x: Double, ref: Double) -> String {
    guard ref > 0, x > 0 else { return "   -∞" }
    return String(format: "%5.1f", 20 * log10(x / ref))
}

var field = SpatialField()
field.radius = 2.0
field.lift = 22

print("")
print(String(format: "%-4@ %-10@ %5@ %5@ | %@", "bus" as NSString, "place" as NSString, "az" as NSString, "el" as NSString,
             channelNames.map { String(format: "%5@", $0 as NSString) }.joined(separator: " ") as NSString))

struct Row { let bus: Int; let az: Double; let el: Double; let rms: [Double] }
var rows: [Row] = []

for bus in 0..<16 {
    source.position = field.position(bus: bus)
    let col = bus % SpatialField.azimuths
    let az = Double(col) / Double(SpatialField.azimuths) * 360
    let el = bus < 8 ? -field.lift : field.lift
    let rms = measure(seconds: 0.5)
    rows.append(Row(bus: bus, az: az, el: el, rms: rms))
    let peak = rms.max() ?? 1
    print(String(format: "%-4d %-10@ %5.0f %5.0f | %@", bus, SpatialField.label(bus: bus) as NSString, az, el,
                 rms.map { dB($0, ref: peak) }.joined(separator: " ") as NSString))
}

// Where the television parks the reverb's wet pair: wide, a little behind.
print("")
for (name, az) in [("wet L", -110.0), ("wet R", 110.0)] {
    let a = az * Double.pi / 180
    source.position = AVAudio3DPoint(x: Float(2.0 * sin(a)), y: 0.3, z: Float(-2.0 * cos(a)))
    let rms = measure(seconds: 0.5)
    let peak = rms.max() ?? 1
    print(String(format: "%-15@ %5.0f     0 | %@", name as NSString, az,
                 rms.map { dB($0, ref: peak) }.joined(separator: " ") as NSString))
}

// MARK: - Asserts

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "✓ " : "✗ ") + what)
    if !ok { failures += 1 }
}
func level(_ r: Row, _ chs: [Int]) -> Double { chs.map { r.rms[$0] * r.rms[$0] }.reduce(0, +).squareRoot() }
func ratioDB(_ a: Double, _ b: Double) -> Double { 20 * log10(max(a, 1e-9) / max(b, 1e-9)) }

let L = 0, R = 1, C = 2, LFE = 3, Ls = 4, Rs = 5
for tier in [0, 8] {
    let ahead = rows[tier + 0], right = rows[tier + 2], behind = rows[tier + 4], left = rows[tier + 6]
    let t = tier == 0 ? "low" : "high"
    check(ratioDB(level(ahead, [L, R, C]), level(ahead, [Ls, Rs])) >= 6,
          "\(t) tier, tonic ahead: front ≥ 6 dB over surrounds (\(String(format: "%.1f", ratioDB(level(ahead, [L, R, C]), level(ahead, [Ls, Rs])))) dB)")
    check(ratioDB(level(behind, [Ls, Rs]), level(behind, [L, R, C])) >= 6,
          "\(t) tier, behind: surrounds ≥ 6 dB over front (\(String(format: "%.1f", ratioDB(level(behind, [Ls, Rs]), level(behind, [L, R, C])))) dB)")
    check(ratioDB(level(right, [R, Rs]), level(right, [L, Ls])) >= 6,
          "\(t) tier, right: right side ≥ 6 dB over left (\(String(format: "%.1f", ratioDB(level(right, [R, Rs]), level(right, [L, Ls])))) dB)")
    check(ratioDB(level(left, [L, Ls]), level(left, [R, Rs])) >= 6,
          "\(t) tier, left: left side ≥ 6 dB over right (\(String(format: "%.1f", ratioDB(level(left, [L, Ls]), level(left, [R, Rs])))) dB)")
}
// The LFE is a report, not a rule — but if soundField dumps the bass tier there,
// the drone's low octaves would come out of a subwoofer alone, which is worth
// knowing before anyone listens.
let lfeShare = rows.map { $0.rms[LFE] * $0.rms[LFE] }.reduce(0, +) / rows.map { $0.rms.map { $0 * $0 }.reduce(0, +) }.reduce(0, +)
print(String(format: "LFE share of total energy across all buses: %.1f%%", lfeShare * 100))
check(soundFieldOK, "soundField listed as applicable at 5.1 (it is; it is also silent — see above)")
check(applicableAlgorithms.contains(.auto), "auto listed as applicable at 5.1")

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
