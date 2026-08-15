import Foundation
import Accelerate
import AVFoundation

// Does a timbre change actually arrive as a change of level and nothing else —
// asked of `DroneEngine.advanceTimbre` and the union-slot spectrum it moves.
//
//   swiftc -O Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine}.swift \
//          Tools/timbre/main.swift -o /tmp/thrumtimbre && /tmp/thrumtimbre
//
// The listener's report was that a timbre change sounded "like someone changing
// presets on a synth keyboard", and that Flow's nine-second dip to 0.22 made it
// worse rather than better by announcing it. So there are two questions here and
// they are not the same one:
//
//   1. Is the *destination* still the instrument it used to be? The spectrum is
//      now stored one-slot-per-harmonic across the union of every timbre's
//      partials rather than as each timbre's own dense list, and a re-encoding
//      that quietly changed what a Harmonium sounds like would be a bad trade for
//      a smooth transition. `SPECTRA` renders all eight and compares each against
//      the catalogue it came from.
//
//   2. Is the *journey* inaudible? `FLUX` measures how much the spectrum moves
//      from one 100 ms frame to the next, which is the thing an ear hears as an
//      edit. Per the house rule the test first has to be shown catching the bug
//      it claims to catch, so every flux figure is reported next to a control run
//      of the identical timeline doing the swap the old way, via `snapTimbre()`.
//      A crossfade that scores the same as a hard swap has not been demonstrated
//      to do anything.
//
// And one that is easy to forget to ask: a crossfade between two spectra that are
// each normalised to the same loudness is *not* automatically level-flat in
// between, because partials the two timbres share add coherently while the rest
// do not. `LEVEL` checks the drone does not sag or bulge on the way across, which
// is what would turn a fixed lurch into a fixed swell.

let sr = 48000.0
let block = 512

// MARK: - Rendering

/// A fixed drone, so the only thing that differs between runs is the timbre.
func makeEngine() -> DroneEngine {
    let engine = DroneEngine()
    engine.setSampleRate(sr)

    var harmony = Harmony()
    harmony.keyPitchClass = 2
    harmony.rootOctave = 3
    harmony.modeIndex = 1
    harmony.tuning = .just5Limit

    engine.swellSeconds = 4
    engine.fadeSeconds = 8
    engine.beating = 0.5
    engine.drift = 0.45
    engine.motion = 0.55
    engine.brightness = 0.52
    engine.reverbMix = 0            // dry: the reverb tail would smear the flux
    engine.globalSwell = 1.0
    engine.masterVolume = 0.85

    let tones = harmony.tones()
    for (pad, level) in [(0, 0.90), (8, 0.55), (12, 0.60), (18, 0.40)] {
        engine.retune(pad: pad, frequency: tones[pad].frequency)
        engine.setLevel(pad: pad, level: level)
        engine.gate(pad: pad, on: true)
    }
    return engine
}

let abl = AudioBufferList.allocate(maximumBuffers: 2)
let bufL = UnsafeMutablePointer<Float>.allocate(capacity: block)
let bufR = UnsafeMutablePointer<Float>.allocate(capacity: block)
abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: bufL)
abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: bufR)

func render(_ engine: DroneEngine, seconds: Double) -> [Float] {
    let total = Int(seconds * sr)
    var out = [Float](repeating: 0, count: total)
    var done = 0
    while done < total {
        let n = min(block, total - done)
        engine.render(frameCount: n, out: abl.unsafeMutablePointer)
        for i in 0..<n { out[done + i] = 0.5 * (bufL[i] + bufR[i]) }
        done += n
    }
    return out
}

// MARK: - Spectra

let fftSize = 4096
let hop = Int(0.1 * sr)          // 100 ms — about the shortest edit an ear resolves
let bins = fftSize / 2

let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(fftSize))), radix: .radix2,
                   ofType: DSPSplitComplex.self)!
let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                         count: fftSize, isHalfWindow: false)

/// Linear magnitude spectrum of one frame. Linear, not dB — see `distance`.
func spectrum(_ x: [Float], at offset: Int) -> [Float] {
    var re = [Float](repeating: 0, count: bins)
    var im = [Float](repeating: 0, count: bins)
    var windowed = [Float](repeating: 0, count: fftSize)
    for i in 0..<fftSize where offset + i < x.count { windowed[i] = x[offset + i] }
    vDSP.multiply(windowed, window, result: &windowed)

    var mags = [Float](repeating: 0, count: bins)
    windowed.withUnsafeBufferPointer { wp in
        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                    fft.forward(input: split, output: &split)
                    vDSP.absolute(split, result: &mags)
                }
            }
        }
    }
    return mags
}

/// Mean spectrum over a stretch, which is what "what this timbre sounds like"
/// means for a drone whose partials are all beating against each other.
func meanSpectrum(_ x: [Float], from: Double, to: Double) -> [Float] {
    var acc = [Float](repeating: 0, count: bins)
    var frames = 0
    var o = Int(from * sr)
    while o + fftSize < Int(to * sr) {
        let s = spectrum(x, at: o)
        for i in 0..<bins { acc[i] += s[i] }
        frames += 1
        o += hop
    }
    return acc.map { $0 / Float(max(1, frames)) }
}

/// How much of the spectrum has moved, 0…1, over the band that carries the drone.
///
/// Linear magnitude normalised to unit sum, then half the L1 distance — the total
/// variation between two spectra read as distributions of where the energy is. In
/// dB-per-bin it is unusable: the great majority of bins are noise floor, where a
/// difference of ±15 dB is nothing at all happening, and averaging those in swamps
/// the handful of bins that are the actual partials. The first version of this
/// harness did exactly that and scored a crossfade at 70% of a hard swap, which
/// says only that both runs have a noise floor.
func distance(_ a: [Float], _ b: [Float]) -> Float {
    let lo = Int(40.0 / sr * Double(fftSize)), hi = Int(12000.0 / sr * Double(fftSize))
    var sa: Float = 0, sb: Float = 0
    for i in lo..<hi { sa += a[i]; sb += b[i] }
    guard sa > 0, sb > 0 else { return 0 }
    var sum: Float = 0
    for i in lo..<hi { sum += abs(a[i] / sa - b[i] / sb) }
    return sum / 2
}

func rms(_ x: [Float], from: Double, to: Double) -> Float {
    let a = max(0, Int(from * sr)), b = min(x.count, Int(to * sr))
    guard b > a else { return 0 }
    var acc: Float = 0
    for i in a..<b { acc += x[i] * x[i] }
    return sqrt(acc / Float(b - a))
}

func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }

var failures: [String] = []
func check(_ ok: Bool, _ label: String, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(label)  \(detail)")
    if !ok { failures.append(label) }
}

// MARK: - TABLE: is each timbre still itself?

print("\nTABLE — the union re-encoding is the same eight instruments")
print("  Every timbre now lives in the same sixteen slots, one per harmonic across")
print("  the whole catalogue, instead of its own dense partial list. Read the")
print("  spectrum the engine would sound and compare it with the recipe, partial")
print("  by partial: the amplitudes must be the catalogue's own, normalised, and")
print("  every harmonic the timbre does *not* declare must be silent.\n")

let harmonics = TimbreCatalog.harmonics
print("  slots: \(harmonics.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: " "))\n")

for (ti, t) in TimbreCatalog.all.enumerated() {
    let engine = makeEngine()
    engine.timbreIndex = Int32(ti)
    engine.snapTimbre()
    let sounding = engine.soundingSpectrum()

    var sum = 0.0
    for p in t.partials { sum += p.a }
    let norm = 0.62 / max(0.001, sum)
    let declared = Dictionary(t.partials.map { ($0.h, $0.a) }, uniquingKeysWith: +)

    var worstAmp = 0.0, worstRatio = 0.0, strays = 0
    for (k, h) in harmonics.enumerated() {
        let expectAmp = (declared[h] ?? 0) * norm
        let expectRatio = t.inharmonicity > 0
            ? h * (1.0 + t.inharmonicity * h * h).squareRoot() : h
        worstAmp = max(worstAmp, abs(Double(sounding[k].amp) - expectAmp))
        worstRatio = max(worstRatio, abs(sounding[k].ratio - expectRatio))
        if declared[h] == nil && sounding[k].amp != 0 { strays += 1 }
    }
    check(worstAmp < 1e-6 && worstRatio < 1e-9 && strays == 0,
          String(format: "%-14@", t.name as NSString),
          String(format: "%2d partials  amp err %.1e  ratio err %.1e  strays %d",
                 t.partials.count, worstAmp, worstRatio, strays))
}

// Not every pair can be used, and the reason is worth keeping. Analog Bloom and
// Shruti Box are both dense, near-complete harmonic series, so swapping one for
// the other outright scores only 1.5× its own background — a hard swap between
// them is very nearly inaudible to begin with, and a pair whose defect the
// harness cannot see is a pair whose fix it cannot demonstrate either. The pairs
// below are the ones that differ in kind: a full series against one with the
// evens hollowed out, an unstretched spectrum against a stretched one, and a
// fourteen-partial buzz against a registration with a sub-octave.
let pairs = [(0, 4, "Harmonium → Bagpipe"), (3, 6, "Bowed → Glass"),
             (7, 1, "Tanpura → Pipe Organ"), (6, 4, "Glass → Bagpipe")]

// MARK: - TRAJECTORY: does any partial ever step?

print("\nTRAJECTORY — read off the engine rather than out of an FFT")
print("  The spectrum sampled every 100 ms through a change, so the question")
print("  \"does a partial ever jump\" is answered in the amplitudes themselves")
print("  rather than inferred from a rendered signal. A hard swap moves a partial")
print("  by its whole travel in one step; the pass mark is that nothing moves more")
print("  than a few percent of its travel in any one frame.\n")

for (a, b, label) in pairs {
    let engine = makeEngine()
    engine.timbreIndex = Int32(a)
    engine.snapTimbre()
    engine.timbreSeconds = 14
    _ = render(engine, seconds: 2)

    let from = engine.soundingSpectrum().map { $0.amp }
    let to = engine.catalogSpectrum(b).map { $0.amp }
    let travel = zip(from, to).map { abs($0 - $1) }
    let span = travel.max() ?? 0

    engine.timbreIndex = Int32(b)
    var worstStep: Float = 0
    var prev = from
    var elapsed = 0.0
    var settledAt = -1.0
    while elapsed < 60 {
        _ = render(engine, seconds: 0.1)
        elapsed += 0.1
        let now = engine.soundingSpectrum().map { $0.amp }
        for k in 0..<now.count { worstStep = max(worstStep, abs(now[k] - prev[k])) }
        prev = now
        if settledAt < 0 && engine.timbreSettled { settledAt = elapsed }
    }
    let arrived = zip(prev, to).allSatisfy { abs($0 - $1) < 1e-6 }
    check(worstStep < span * 0.05 && arrived,
          String(format: "%-22@", label as NSString),
          String(format: "worst step %.1f%% of travel   settled at %.1fs   arrived %@",
                 100 * worstStep / max(span, 1e-9), settledAt, arrived ? "yes" : "NO"))
}

// MARK: - FLUX: is the journey inaudible?

print("\nFLUX — how much the spectrum moves from one 100 ms frame to the next")
print("  Two controls, because one would not settle it. The old behaviour")
print("  (`snapTimbre()` on the change) is the artifact this has to beat; a drone")
print("  left alone on one timbre is the floor it has to reach, and that floor is")
print("  not zero — sixteen detuned pairs beating against each other move the")
print("  spectrum all the time. A crossfade has only been shown to work if it")
print("  scores like the drone that never changed.\n")


/// Renders a change from `from` to `to`, either crossfaded or swapped outright,
/// and returns the mono signal plus the moment of the change.
func changeRun(from: Int, to: Int, hard: Bool, seconds: Double = 34) -> [Float] {
    let engine = makeEngine()
    engine.timbreIndex = Int32(from)
    engine.snapTimbre()
    engine.timbreSeconds = 14
    let before = render(engine, seconds: 10)
    engine.timbreIndex = Int32(to)
    if hard { engine.snapTimbre() }
    let after = render(engine, seconds: seconds - 10)
    return before + after
}

/// Frame-to-frame spectral movement, with the time of each measurement.
func fluxSeries(_ x: [Float]) -> [(at: Double, value: Float)] {
    var out: [(Double, Float)] = []
    var prev: [Float]? = nil
    var o = Int(6 * sr)
    while o + fftSize < x.count {
        let s = spectrum(x, at: o)
        if let p = prev { out.append((Double(o) / sr, distance(p, s))) }
        prev = s
        o += hop
    }
    return out
}

/// The movement *at the change* against the movement everywhere else in the same
/// run.
///
/// Taking the maximum over the whole run — the first version of this — compares a
/// swap against the loudest beat in a thirty-second drone and finds them within a
/// factor of 1.3, which says nothing. The event has a known time, so the honest
/// measurement is the flux in the second it happens against the 95th percentile
/// of the flux when nothing is happening.
func changeFlux(_ x: [Float], at moment: Double) -> (event: Float, background: Float) {
    let series = fluxSeries(x)
    let event = series.filter { $0.at >= moment - 0.05 && $0.at < moment + 1.0 }
                      .map(\.value).max() ?? 0
    let rest = series.filter { $0.at < moment - 1.0 || $0.at > moment + 2.0 }
                     .map(\.value).sorted()
    let background = rest.isEmpty ? 0 : rest[Int(Double(rest.count) * 0.95)]
    return (event, background)
}

// Pairs chosen to be the hardest cases: a full harmonic series against one with
// the evens hollowed out, a stretched spectrum against an unstretched one, and a
// timbre with a sub-octave against one without.

for (a, b, label) in pairs {
    let soft = changeFlux(changeRun(from: a, to: b, hard: false), at: 10)
    let hard = changeFlux(changeRun(from: a, to: b, hard: true), at: 10)
    // Two claims at once, and both are needed. The swap must stand out of its own
    // background — otherwise this harness cannot see the defect it was written for
    // and the crossfade's score means nothing. And the crossfade must *not* stand
    // out of its: at the moment of the change it should look like a drone that is
    // not changing.
    let detects = hard.event > hard.background * 1.6
    let hidden = soft.event < soft.background * 1.15
    check(detects && hidden,
          String(format: "%-22@", label as NSString),
          String(format: "swap %.3f vs %.3f background (%.1f×)   crossfade %.3f vs %.3f (%.2f×)",
                 hard.event, hard.background, hard.event / max(hard.background, 1e-6),
                 soft.event, soft.background, soft.event / max(soft.background, 1e-6)))
}

// MARK: - LEVEL: does the drone hold its level across the change?

print("\nLEVEL — no sag or bulge in the middle of a crossfade")
print("  Each timbre is normalised to the same summed partial amplitude, but that")
print("  guarantees the endpoints, not the middle: shared harmonics add coherently")
print("  while the rest do not. A crossfade that dips is a breath nobody asked for.\n")

for (a, b, label) in pairs {
    let x = changeRun(from: a, to: b, hard: false, seconds: 40)
    let start = rms(x, from: 7, to: 10)
    let end = rms(x, from: 34, to: 40)
    var worst: Float = 0
    var worstAt = 0.0
    var t = 10.0
    while t < 26 {
        let mid = rms(x, from: t, to: t + 1)
        // Against the interpolation of the two endpoints, not against either one,
        // since the two timbres genuinely differ in level a little.
        let expected = start + (end - start) * Float((t - 10) / 14)
        let dev = abs(db(mid) - db(expected))
        if dev > worst { worst = dev; worstAt = t }
        t += 1
    }
    check(worst < 3.0, String(format: "%-22@", label as NSString),
          String(format: "worst deviation %4.1f dB at %.0fs   (%.1f → %.1f dBFS)",
                 worst, worstAt, db(start), db(end)))
}

// MARK: - TIME: does `timbreSeconds` mean what it says?

print("\nTIME — the change takes as long as it was asked to")
print("  Progress measured as spectral distance travelled from the old timbre")
print("  towards the new one; reported as the 10%→90% time.\n")

for secs in [6.0, 14.0, 28.0] {
    let engine = makeEngine()
    engine.timbreIndex = 0
    engine.snapTimbre()
    engine.timbreSeconds = secs
    _ = render(engine, seconds: 2)

    let from = engine.soundingSpectrum().map { $0.amp }
    let to = engine.catalogSpectrum(4).map { $0.amp }
    let span = zip(from, to).map { abs($0 - $1) }.reduce(0, +)

    engine.timbreIndex = 4
    var t10 = -1.0, t90 = -1.0, done = -1.0
    var elapsed = 0.0
    while elapsed < secs * 3 + 6 {
        _ = render(engine, seconds: 0.1)
        elapsed += 0.1
        let now = engine.soundingSpectrum().map { $0.amp }
        let travelled = 1 - zip(now, to).map { abs($0 - $1) }.reduce(0, +) / max(span, 1e-9)
        if t10 < 0 && travelled > 0.1 { t10 = elapsed }
        if t90 < 0 && travelled > 0.9 { t90 = elapsed }
        if done < 0 && engine.timbreSettled { done = elapsed; break }
    }
    // Smootherstep spends its first and last sixth barely moving, so 10→90% of a
    // ramp of length T is about 0.55T. What is being asserted is that the dial
    // means seconds and that the change ends when it says it will, rather than
    // trailing off asymptotically as the one-pole this replaced did.
    let took = t90 - t10
    check(t90 > 0 && abs(took - secs * 0.55) < secs * 0.15 && abs(done - secs) < 0.3,
          String(format: "timbreSeconds = %4.0f  ", secs),
          String(format: "10%%→90%% in %5.1f s (%.0f%% of the ramp)   settled at %5.1f s",
                 took, 100 * took / secs, done))
}

print("")
if failures.isEmpty {
    print("PASS — all checks green")
} else {
    print("FAIL — \(failures.count): \(failures.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))")
    exit(1)
}
