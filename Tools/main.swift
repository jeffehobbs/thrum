import Foundation
import AVFoundation

// Offline harness: renders the real DroneEngine to a WAV and reports whether
// the result is actually a drone — energy present, nothing clipping, nothing
// NaN, slow beating measurable, spectrum tilted the way section 7 asks for.
//
//   swiftc -O Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine}.swift \
//          Tools/RenderTest.swift -o /tmp/thrumtest && /tmp/thrumtest out.wav 30

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "/tmp/thrum.wav"
let seconds = args.count > 2 ? Double(args[2]) ?? 20 : 20
let sr = 48000.0
let block = 512

let engine = DroneEngine()
engine.setSampleRate(sr)

// A D Dorian drone in 5-limit just intonation: pedal root, fifth, octave,
// minor third and seventh — plus jawari on the top voice.
var harmony = Harmony()
harmony.keyPitchClass = 2
harmony.rootOctave = 3
harmony.modeIndex = 1
harmony.tuning = .just5Limit

engine.timbreIndex = 0
engine.swellSeconds = 6
engine.fadeSeconds = 10
engine.beating = 0.55
engine.drift = 0.5
engine.motion = 0.6
engine.brightness = 0.52
engine.reverbDecay = 16
engine.reverbMix = 0.42
engine.width = 1.3
engine.masterVolume = 0.85

let scenario = args.count > 3 ? args[3] : "drone"
if scenario == "stress" {
    // Worst case: every pad sounding, the fourteen-partial timbre, jawari on
    // all of them, every modulation at maximum.
    engine.timbreIndex = 7
    engine.beating = 1; engine.drift = 1; engine.motion = 1
    engine.brightness = 1; engine.drive = 1
    engine.reverbDecay = 32; engine.reverbMix = 0.9; engine.reverbSize = 1.7
    engine.width = 2; engine.spatialDrift = 1
    engine.swellSeconds = 1
    harmony.tuning = .thirtyOneTET
}
if scenario == "tail" {
    // Short note, hard cut, then nothing but the reverb — so the decay slope
    // can be measured against the RT60 the control claims.
    engine.swellSeconds = 0.5
    engine.fadeSeconds = 0.5
    engine.reverbDecay = 16
    engine.reverbMix = 1.0
}
let tones = harmony.tones()

struct Sounding { let row: Int; let col: Int; let level: Double; let sitar: Double }
let plan: [Sounding] = scenario == "stress"
    ? (0..<Harmony.padCount).map {
        Sounding(row: $0 / Harmony.cols, col: $0 % Harmony.cols, level: 0.7, sitar: 0.9)
      }
    : [
    Sounding(row: 0, col: 0, level: 0.90, sitar: 0),     // low root
    Sounding(row: 1, col: 4, level: 0.60, sitar: 0),     // fifth
    Sounding(row: 1, col: 0, level: 0.55, sitar: 0),     // root + 1
    Sounding(row: 2, col: 2, level: 0.40, sitar: 0),     // minor third
    Sounding(row: 2, col: 6, level: 0.34, sitar: 0.65),  // seventh, jawari on
    Sounding(row: 3, col: 0, level: 0.22, sitar: 0),     // high root
]
for s in plan {
    let pad = s.row * Harmony.cols + s.col
    let t = tones[pad]
    engine.retune(pad: pad, frequency: t.frequency)
    engine.setLevel(pad: pad, level: s.level)
    engine.setSitar(pad: pad, depth: s.sitar)
    engine.gate(pad: pad, on: true)
    print(String(format: "  pad %2d  %-2@ %-3@  %8.3f Hz  %+5.1f¢  level %.2f%@",
                 pad, t.noteName as NSString, t.degreeLabel as NSString,
                 t.frequency, t.deviation, s.level,
                 (s.sitar > 0 ? "  jawari" : "") as NSString))
}

let total = Int(seconds * sr)
var left = [Float](repeating: 0, count: total)
var right = [Float](repeating: 0, count: total)

let abl = AudioBufferList.allocate(maximumBuffers: 2)
let bufL = UnsafeMutablePointer<Float>.allocate(capacity: block)
let bufR = UnsafeMutablePointer<Float>.allocate(capacity: block)
abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: bufL)
abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: bufR)

let start = Date()
var written = 0
while written < total {
    let n = min(block, total - written)
    engine.render(frameCount: n, out: abl.unsafeMutablePointer)
    for i in 0..<n {
        left[written + i] = bufL[i]
        right[written + i] = bufR[i]
    }
    written += n
    let cutAt = scenario == "tail" ? 0.10 : 0.7
    if written >= Int(Double(total) * cutAt) && written - n < Int(Double(total) * cutAt) {
        engine.fadeAll(seconds: scenario == "tail" ? 0.4 : 6)
    }
}
let elapsed = Date().timeIntervalSince(start)

// MARK: - Analysis

var peak: Float = 0
var sumSq = 0.0
var nans = 0
for i in 0..<total {
    let l = left[i], r = right[i]
    if !l.isFinite || !r.isFinite { nans += 1; continue }
    peak = max(peak, max(abs(l), abs(r)))
    sumSq += Double(l * l + r * r)
}
let rms = sqrt(sumSq / Double(total * 2))

// Slow-envelope fluctuation = the audible beating. Measure over the sustained
// middle third only, after the swell and before the release.
let a = total / 3, b = (total * 2) / 3
var env: [Double] = []
let win = Int(sr / 40)  // 25 ms
var i = a
while i + win < b {
    var s = 0.0
    for k in i..<(i + win) { s += Double(abs(left[k]) + abs(right[k])) }
    env.append(s / Double(win * 2))
    i += win
}
let envMean = env.reduce(0, +) / Double(env.count)
let envVar = env.reduce(0) { $0 + pow($1 - envMean, 2) } / Double(env.count)
let beatDepth = sqrt(envVar) / max(1e-9, envMean)

// Crude band energies via Goertzel-ish direct sums over the sustain window.
func bandEnergy(_ lo: Double, _ hi: Double) -> Double {
    // One-pole bandpass sweep is overkill; use a DFT at a few probe bins.
    var total = 0.0
    var probes = 0
    var f = lo
    while f < hi {
        var re = 0.0, im = 0.0
        let w = 2.0 * Double.pi * f / sr
        let n = min(b - a, Int(sr))  // one second is plenty
        for k in 0..<n {
            let x = Double(left[a + k] + right[a + k]) * 0.5
            re += x * cos(w * Double(k))
            im += x * sin(w * Double(k))
        }
        total += (re * re + im * im) / Double(n * n)
        probes += 1
        f *= 1.26  // ~1/3 octave
    }
    return probes > 0 ? total / Double(probes) : 0
}
func db(_ x: Double) -> Double { 10 * log10(max(1e-12, x)) }

let low = bandEnergy(60, 250)
let lowMid = bandEnergy(250, 900)
let upperMid = bandEnergy(2000, 5000)
let high = bandEnergy(6000, 12000)

print("")
print(String(format: "render        %.2fs of audio in %.2fs  (%.0f× realtime, %.1f%% of one core)",
             seconds, elapsed, seconds / elapsed, 100 * elapsed / seconds))
print(String(format: "peak          %.4f  %@", peak, peak < 0.999 ? "ok" : "CLIPPING"))
print(String(format: "rms           %.4f  (%.1f dBFS)", rms, 20 * log10(max(1e-9, Double(rms)))))
print("non-finite    \(nans)  \(nans == 0 ? "ok" : "BAD")")
print(String(format: "beat depth    %.3f  (slow amplitude fluctuation in the sustain)", beatDepth))
print(String(format: "spectrum      low %.1f dB  lowmid %.1f dB  uppermid %.1f dB  high %.1f dB",
             db(low), db(lowMid), db(upperMid), db(high)))
print(String(format: "  low→uppermid tilt %+.1f dB  (positive = warm, section 7 wants this)",
             db(low) - db(upperMid)))

// Envelope trace, one bucket per second — the shape of the whole take.
print("\nenvelope (rms per second, dBFS)")
var trace = ""
var peakSecond = 0.0
var seconds1: [Double] = []
for s in 0..<Int(seconds) {
    let lo = Int(Double(s) * sr), hi = min(total, Int(Double(s + 1) * sr))
    var acc = 0.0
    for k in lo..<hi { acc += Double(left[k] * left[k] + right[k] * right[k]) }
    let r = sqrt(acc / Double(max(1, (hi - lo) * 2)))
    seconds1.append(r)
    peakSecond = max(peakSecond, r)
}
for (s, r) in seconds1.enumerated() {
    let d = 20 * log10(max(1e-9, r))
    let bars = Int(max(0, min(40, (d + 70) * 0.6)))
    trace += String(format: "%3ds %6.1f  %@\n", s, d, String(repeating: "▇", count: bars))
}
print(trace, terminator: "")

if scenario == "tail" {
    // RT60 from the slope between −10 dB and −40 dB below the post-cut peak.
    let cutSecond = Int(seconds * 0.10) + 1
    guard cutSecond + 2 < seconds1.count else { exit(0) }
    let ref = 20 * log10(max(1e-9, seconds1[cutSecond + 1]))
    var t10 = -1.0, t40 = -1.0
    for s in (cutSecond + 1)..<seconds1.count {
        let d = 20 * log10(max(1e-9, seconds1[s])) - ref
        if t10 < 0 && d <= -10 { t10 = Double(s) }
        if t40 < 0 && d <= -40 { t40 = Double(s); break }
    }
    if t10 >= 0 && t40 > t10 {
        print(String(format: "\nmeasured RT60 %.1f s  (control says %.0f s)",
                     (t40 - t10) * 2.0, engine.reverbDecay))
    } else {
        print("\nRT60 not reached inside \(Int(seconds))s — tail is at least that long")
    }
}

// MARK: - Write WAV

var data = Data()
func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
let frames = UInt32(total)
let dataBytes = frames * 2 * 2
data.append("RIFF".data(using: .ascii)!)
data.append(le32(36 + dataBytes))
data.append("WAVEfmt ".data(using: .ascii)!)
data.append(le32(16)); data.append(le16(1)); data.append(le16(2))
data.append(le32(UInt32(sr))); data.append(le32(UInt32(sr) * 4))
data.append(le16(4)); data.append(le16(16))
data.append("data".data(using: .ascii)!)
data.append(le32(dataBytes))
var pcm = [Int16](repeating: 0, count: total * 2)
for i in 0..<total {
    pcm[i * 2] = Int16(max(-32767, min(32767, left[i] * 32767)))
    pcm[i * 2 + 1] = Int16(max(-32767, min(32767, right[i] * 32767)))
}
pcm.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
try! data.write(to: URL(fileURLWithPath: outPath))
print("\nwrote \(outPath)")

bufL.deallocate()
bufR.deallocate()
