import Foundation
import SwiftUI
import Combine

/// Every continuous control in Thrum, declared once.
///
/// The Mac app renders these as sliders; a Novation Launch Control (or Launch
/// Control XL) binds its knobs and faders to them by `Param` case. Nothing
/// else in the app needs to know which surface a value came from.
public enum Param: Int, CaseIterable, Identifiable, Sendable {
    // Voice
    case swell, fade, beating, drift, motion, sitarDepth, padLevel
    // Tone
    case brightness, warmth, presence, air, drive
    // Space
    case reverbDecay, reverbMix, reverbDamp, reverbSize, width, spatialDrift
    // Master
    case globalSwell, masterVolume

    public var id: Int { rawValue }
}

public enum ParamGroup: String, CaseIterable, Identifiable {
    case voice = "Voice"
    case tone = "Tone"
    case space = "Space"
    case master = "Master"
    public var id: String { rawValue }
}

public struct ParamSpec {
    public let param: Param
    public let name: String
    public let group: ParamGroup
    public let range: ClosedRange<Double>
    public let unit: String
    public let detail: String
    /// Slider travel is exponential for time-like parameters.
    public let exponential: Bool
    let get: (ThrumModel) -> Double
    let set: (ThrumModel, Double) -> Void

    /// 0…1 knob position → value, honouring the curve.
    public func value(fromNormalized x: Double) -> Double {
        let t = min(max(x, 0), 1)
        if exponential {
            return range.lowerBound * pow(range.upperBound / range.lowerBound, t)
        }
        return range.lowerBound + (range.upperBound - range.lowerBound) * t
    }

    public func normalized(_ v: Double) -> Double {
        let c = min(max(v, range.lowerBound), range.upperBound)
        if exponential {
            return log(c / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
        return (c - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    public func display(_ v: Double) -> String {
        if unit == "s" { return String(format: v < 10 ? "%.1f s" : "%.0f s", v) }
        if unit == "%" { return "\(Int((v * 100).rounded()))%" }
        return String(format: "%.2f", v)
    }
}

/// The state of the instrument: what key it is in, what it is holding, and how
/// every knob is set. Both the on-screen UI and the hardware controllers drive
/// this one object; it is the only writer to the audio engine.
@MainActor
public final class ThrumModel: ObservableObject {
    public let engine: DroneEngine

    @Published public var harmony = Harmony() { didSet { harmonyChanged(from: oldValue) } }
    @Published public var timbreIndex = 0 { didSet { engine.timbreIndex = Int32(timbreIndex) } }
    @Published public var modeBank = 0

    /// Per-pad state, indexed by pad 0…31 (row-major, row 0 = lowest octave).
    @Published public private(set) var padOn = [Bool](repeating: false, count: Harmony.padCount)
    @Published public private(set) var padLevel = [Double](repeating: 0, count: Harmony.padCount)
    @Published public private(set) var padSitar = [Double](repeating: 0, count: Harmony.padCount)

    /// Level a tone starts at when you tap it in.
    @Published public var defaultLevel: Double = 0.72
    /// Sitar depth applied when you arm a tone's jawari.
    @Published public var sitarDepth: Double = 0.55

    @Published public var status: String = "Tap a pad to start the drone."
    @Published public var launchpadConnected = false
    @Published public var launchControlConnected = false

    @Published public var tones: [GridTone] = []

    /// True when no voice is sounding *and* none is still fading. Drives the
    /// on-screen animation, which otherwise redraws a canvas twenty times a
    /// second to show nothing.
    @Published public private(set) var isIdle = true
    /// Mirrors of the engine's render statistics, sampled off the audio thread.
    @Published public private(set) var renderLoad: Float = 0
    @Published public private(set) var renderOverruns: Int32 = 0

    private var watchTimer: Timer?

    /// Mirror of the engine's parameters so SwiftUI can bind to them.
    @Published public var values: [Double] = []

    private var statusResetWork: DispatchWorkItem?

    public init(engine: DroneEngine) {
        self.engine = engine
        values = Self.specs.map { $0.range.lowerBound }
        // Seed from the engine's own defaults.
        for (i, spec) in Self.specs.enumerated() { values[i] = spec.get(self) }
        engine.timbreIndex = Int32(timbreIndex)
        tones = harmony.tones()
        pushAllTunings()

        // Four hertz is enough to notice the last voice finishing its fade and
        // to keep a load readout honest, without being a load of its own.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleEngine() }
        }
    }

    deinit { watchTimer?.invalidate() }

    private func sampleEngine() {
        let idle = engine.activeVoices == 0
        if idle != isIdle { isIdle = idle }
        let load = engine.renderLoad
        if abs(load - renderLoad) > 0.005 { renderLoad = load }
        if engine.renderOverruns != renderOverruns { renderOverruns = engine.renderOverruns }
    }

    public func resetRenderStats() {
        engine.resetRenderStats()
        renderOverruns = 0
        renderLoad = 0
        show("Render statistics cleared")
    }

    // MARK: - Parameters

    /// Split by group — one twenty-element literal of closures takes the Swift
    /// type checker an absurdly long time.
    public static let specs: [ParamSpec] = voiceSpecs + toneSpecs + spaceSpecs + masterSpecs

    private static let voiceSpecs: [ParamSpec] = [
        ParamSpec(param: .swell, name: "Swell", group: .voice, range: 0.4...40, unit: "s",
                  detail: "How long a tone takes to bloom to full after you tap it in.",
                  exponential: true,
                  get: { $0.engine.swellSeconds }, set: { $0.engine.swellSeconds = $1 }),
        ParamSpec(param: .fade, name: "Fade", group: .voice, range: 0.4...60, unit: "s",
                  detail: "How long a tone takes to disappear when you let it go.",
                  exponential: true,
                  get: { $0.engine.fadeSeconds }, set: { $0.engine.fadeSeconds = $1 }),
        ParamSpec(param: .beating, name: "Beating", group: .voice, range: 0...1, unit: "%",
                  detail: "Detune between each partial's oscillator pair, in fractions of a hertz. 220.0 against 220.4.",
                  exponential: false,
                  get: { Double($0.engine.beating) }, set: { $0.engine.beating = Float($1) }),
        ParamSpec(param: .drift, name: "Drift", group: .voice, range: 0...1, unit: "%",
                  detail: "Slow independent pitch wander per voice, up to ±9 cents, on prime-numbered cycles.",
                  exponential: false,
                  get: { Double($0.engine.drift) }, set: { $0.engine.drift = Float($1) }),
        ParamSpec(param: .motion, name: "Motion", group: .voice, range: 0...1, unit: "%",
                  detail: "Depth of the slow filter, tremolo and panning movement. Nothing should ever be still.",
                  exponential: false,
                  get: { Double($0.engine.motion) }, set: { $0.engine.motion = Float($1) }),
        ParamSpec(param: .sitarDepth, name: "Sitar Depth", group: .voice, range: 0...1, unit: "%",
                  detail: "Jawari amount applied when you arm a tone's sitar. Allpass swirl plus a bridge buzz.",
                  exponential: false,
                  get: { $0.sitarDepth }, set: { $0.setSitarDepth($1) }),
        ParamSpec(param: .padLevel, name: "New Tone Level", group: .voice, range: 0...1, unit: "%",
                  detail: "Loudness a tone swells to when you tap it in.",
                  exponential: false,
                  get: { $0.defaultLevel }, set: { $0.defaultLevel = min(max($1, 0), 1) }),
    ]

    private static let toneSpecs: [ParamSpec] = [
        ParamSpec(param: .brightness, name: "Brightness", group: .tone, range: 0...1, unit: "%",
                  detail: "Per-voice lowpass, 320 Hz to 9 kHz, before the slow filter sweep.",
                  exponential: false,
                  get: { Double($0.engine.brightness) }, set: { $0.engine.brightness = Float($1) }),
        ParamSpec(param: .warmth, name: "Warmth", group: .tone, range: 0...1, unit: "%",
                  detail: "Low shelf at 165 Hz. The weight under everything.",
                  exponential: false,
                  get: { Double($0.engine.warmth) }, set: { $0.engine.warmth = Float($1) }),
        ParamSpec(param: .presence, name: "Presence Cut", group: .tone, range: 0...1, unit: "%",
                  detail: "Dip at 3.2 kHz. Energy here is what makes a long drone tiring — this is the guard.",
                  exponential: false,
                  get: { Double($0.engine.presenceCut) }, set: { $0.engine.presenceCut = Float($1) }),
        ParamSpec(param: .air, name: "Air", group: .tone, range: 0...1, unit: "%",
                  detail: "High shelf at 9 kHz. Soft top, not edge.",
                  exponential: false,
                  get: { Double($0.engine.air) }, set: { $0.engine.air = Float($1) }),
        ParamSpec(param: .drive, name: "Saturation", group: .tone, range: 0...1, unit: "%",
                  detail: "Gentle tanh drive ahead of the reverb. Adds the overtones a pure sum can't.",
                  exponential: false,
                  get: { Double($0.engine.drive) }, set: { $0.engine.drive = Float($1) }),
    ]

    private static let spaceSpecs: [ParamSpec] = [
        ParamSpec(param: .reverbDecay, name: "Decay", group: .space, range: 1...32, unit: "s",
                  detail: "RT60 of the feedback delay network. Ten to thirty seconds blurs events into a field.",
                  exponential: true,
                  get: { $0.engine.reverbDecay }, set: { $0.engine.reverbDecay = $1 }),
        ParamSpec(param: .reverbMix, name: "Wet", group: .space, range: 0...1, unit: "%",
                  detail: "How much of the tail you hear.",
                  exponential: false,
                  get: { Double($0.engine.reverbMix) }, set: { $0.engine.reverbMix = Float($1) }),
        ParamSpec(param: .reverbDamp, name: "Damping", group: .space, range: 0...1, unit: "%",
                  detail: "High-frequency absorption in the tail. Up is darker and further away.",
                  exponential: false,
                  get: { Double($0.engine.reverbDamp) }, set: { $0.engine.reverbDamp = Float($1) }),
        ParamSpec(param: .reverbSize, name: "Size", group: .space, range: 0.6...1.7, unit: "",
                  detail: "Scales the delay-line lengths. Bigger is slower and more diffuse.",
                  exponential: false,
                  get: { Double($0.engine.reverbSize) }, set: { $0.engine.reverbSize = Float($1) }),
        ParamSpec(param: .width, name: "Width", group: .space, range: 0...2, unit: "",
                  detail: "Mid/side spread. The fundamental stays centred; harmonics open outward.",
                  exponential: false,
                  get: { Double($0.engine.width) }, set: { $0.engine.width = Float($1) }),
        ParamSpec(param: .spatialDrift, name: "Field Drift", group: .space, range: 0...1, unit: "%",
                  detail: "A 97-second rotation of the reverb field. You notice it only if you wait.",
                  exponential: false,
                  get: { Double($0.engine.spatialDrift) }, set: { $0.engine.spatialDrift = Float($1) }),
    ]

    private static let masterSpecs: [ParamSpec] = [
        ParamSpec(param: .globalSwell, name: "Swell Ride", group: .master, range: 0...1, unit: "%",
                  detail: "Rides everything sounding at once. Live dynamics for the whole drone.",
                  exponential: false,
                  get: { Double($0.engine.globalSwell) }, set: { $0.engine.globalSwell = Float($1) }),
        ParamSpec(param: .masterVolume, name: "Output", group: .master, range: 0...1, unit: "%",
                  detail: "Master level, after the limiter.",
                  exponential: false,
                  get: { Double($0.engine.masterVolume) }, set: { $0.engine.masterVolume = Float($1) }),
    ]

    public static func spec(_ p: Param) -> ParamSpec {
        specs.first { $0.param == p } ?? specs[0]
    }

    private static func index(_ p: Param) -> Int {
        specs.firstIndex { $0.param == p } ?? 0
    }

    public func value(_ p: Param) -> Double { values[Self.index(p)] }

    public func set(_ p: Param, _ v: Double) {
        let i = Self.index(p)
        let spec = Self.specs[i]
        let clamped = min(max(v, spec.range.lowerBound), spec.range.upperBound)
        guard values[i] != clamped else { return }
        values[i] = clamped
        spec.set(self, clamped)
    }

    /// Entry point for hardware knobs: 0…1 in, curve applied.
    public func setNormalized(_ p: Param, _ x: Double) {
        set(p, Self.spec(p).value(fromNormalized: x))
    }

    public func binding(_ p: Param) -> Binding<Double> {
        Binding(get: { [weak self] in self?.value(p) ?? 0 },
                set: { [weak self] in self?.set(p, $0) })
    }

    // MARK: - Harmony

    private func harmonyChanged(from old: Harmony) {
        guard harmony != old else { return }
        tones = harmony.tones()
        // Glide, don't jump: sounding tones slide to their new pitches over
        // half a second, so changing mode mid-performance is a modulation
        // rather than an edit.
        pushAllTunings()
    }

    private func pushAllTunings() {
        for t in tones { engine.retune(pad: t.id, frequency: t.frequency) }
    }

    public func setKey(_ pc: Int) {
        harmony.keyPitchClass = ((pc % 12) + 12) % 12
        show("Key → \(Pitch.name(harmony.keyPitchClass)) \(harmony.mode.name)")
    }

    public func nudgeKey(_ delta: Int) {
        setKey(harmony.keyPitchClass + delta)
    }

    public func nudgeOctave(_ delta: Int) {
        harmony.rootOctave = min(6, max(1, harmony.rootOctave + delta))
        show("Register → octave \(harmony.rootOctave)")
    }

    public func setMode(_ index: Int) {
        guard index >= 0, index < ModeCatalog.all.count else { return }
        harmony.modeIndex = index
        modeBank = index / ModeCatalog.bankSize
        show("\(harmony.title) — \(harmony.mode.name)")
    }

    public func setTuning(_ t: TuningSystem) {
        harmony.tuning = t
        show("\(t.name) — \(t.blurb)")
    }

    public func cycleTuning() {
        let all = TuningSystem.allCases
        let i = (all.firstIndex(of: harmony.tuning).map { $0 + 1 } ?? 0) % all.count
        setTuning(all[i])
    }

    public func toggleReference() {
        harmony.a4 = harmony.a4 == 440 ? 432 : 440
        show("Reference pitch → A\(Int(harmony.a4))")
    }

    public func setTimbre(_ i: Int) {
        guard i >= 0, i < TimbreCatalog.all.count else { return }
        timbreIndex = i
        show("\(TimbreCatalog.all[i].name) — \(TimbreCatalog.all[i].blurb)")
    }

    public func cycleTimbre() {
        setTimbre((timbreIndex + 1) % TimbreCatalog.all.count)
    }

    public func cycleModeBank() {
        modeBank = (modeBank + 1) % ModeCatalog.bankCount
        show("Mode bank \(modeBank == 0 ? "A — diatonic" : "B — colour")")
    }

    // MARK: - Tones

    public func toggle(pad: Int) {
        padOn[pad] ? release(pad: pad) : sound(pad: pad, level: defaultLevel)
    }

    public func sound(pad: Int, level: Double) {
        guard pad >= 0, pad < Harmony.padCount else { return }
        padOn[pad] = true
        padLevel[pad] = min(max(level, 0.02), 1)
        engine.retune(pad: pad, frequency: tones[pad].frequency)
        engine.setLevel(pad: pad, level: padLevel[pad])
        engine.gate(pad: pad, on: true)
        let t = tones[pad]
        let dev = abs(t.deviation) < 0.5 ? "" : String(format: " · %+.1f¢", t.deviation)
        show("\(t.noteName)\(t.octave) — \(t.degreeLabel) · \(Int(t.frequency.rounded())) Hz\(dev)")
    }

    public func release(pad: Int) {
        guard pad >= 0, pad < Harmony.padCount else { return }
        padOn[pad] = false
        engine.gate(pad: pad, on: false)
    }

    /// Live level ride — used by pad aftertouch and by the on-screen faders.
    public func setLevel(pad: Int, _ level: Double) {
        guard pad >= 0, pad < Harmony.padCount else { return }
        let v = min(max(level, 0), 1)
        padLevel[pad] = v
        engine.setLevel(pad: pad, level: v)
        if v > 0.01 && !padOn[pad] {
            padOn[pad] = true
            engine.gate(pad: pad, on: true)
        }
    }

    public func toggleSitar(pad: Int) {
        guard pad >= 0, pad < Harmony.padCount else { return }
        let on = padSitar[pad] < 0.01
        setSitar(pad: pad, on ? sitarDepth : 0)
        show(on ? "Jawari on \(tones[pad].noteName) — sitar buzz and phase"
                : "Jawari off \(tones[pad].noteName)")
    }

    public func setSitar(pad: Int, _ depth: Double) {
        guard pad >= 0, pad < Harmony.padCount else { return }
        padSitar[pad] = min(max(depth, 0), 1)
        engine.setSitar(pad: pad, depth: padSitar[pad])
    }

    private func setSitarDepth(_ d: Double) {
        sitarDepth = min(max(d, 0), 1)
        // Anything already armed follows the new depth.
        for i in 0..<Harmony.padCount where padSitar[i] > 0.01 {
            setSitar(pad: i, sitarDepth)
        }
    }

    public func fadeAll(quick: Bool = false) {
        for i in 0..<Harmony.padCount { padOn[i] = false }
        engine.fadeAll(seconds: quick ? 1.2 : nil)
        show(quick ? "Letting go — 1.2 s" : "Letting go…")
    }

    public func panic() {
        for i in 0..<Harmony.padCount { padOn[i] = false; padLevel[i] = 0 }
        engine.panic()
        show("Silence.")
    }

    // MARK: - Voicings

    public enum Voicing: String, CaseIterable, Identifiable {
        case openFifths = "Open Fifths"
        case fullChord = "Full Chord"
        case modalSpread = "Modal Spread"
        case tanpura = "Tanpura"
        case pedalRoot = "Pedal Root"
        public var id: String { rawValue }

        var detail: String {
            switch self {
            case .openFifths:  return "Root and fifth in three registers. Nothing to argue with."
            case .fullChord:   return "Every chord tone, one per register, spread wide."
            case .modalSpread: return "Chord tones low, colour tones high. Most to blow over."
            case .tanpura:     return "The classic 5–1–1–1̇ cycle, all four registers."
            case .pedalRoot:   return "One low root, one octave. The strictest tonal center."
            }
        }
    }

    public func apply(_ voicing: Voicing) {
        fadeAll()
        let deg = harmony.mode.degrees
        var picks: [(pad: Int, level: Double)] = []

        func pad(_ row: Int, _ col: Int) -> Int { row * Harmony.cols + col }
        /// First column in this row whose pitch class matches a semitone.
        func col(matching semitone: Int) -> Int? {
            let want = ((semitone % 12) + 12) % 12
            return (0..<Harmony.cols).first { c in
                let s = deg[c % deg.count] + 12 * (c / deg.count)
                return ((s % 12) + 12) % 12 == want
            }
        }

        switch voicing {
        case .openFifths:
            if let r = col(matching: 0) { picks += [(pad(0, r), 0.85), (pad(2, r), 0.5)] }
            if let f = col(matching: harmony.mode.chordSemitones.contains(6) ? 6 : 7) {
                picks += [(pad(1, f), 0.6), (pad(3, f), 0.32)]
            }
        case .fullChord:
            for (i, s) in harmony.mode.chordSemitones.enumerated() {
                if let c = col(matching: s) {
                    picks.append((pad(min(3, i), c), i == 0 ? 0.85 : 0.52 - Double(i) * 0.06))
                }
            }
        case .modalSpread:
            for (i, s) in harmony.mode.chordSemitones.enumerated() {
                if let c = col(matching: s) { picks.append((pad(i % 2, c), i == 0 ? 0.8 : 0.45)) }
            }
            let colour = deg.filter { !harmony.mode.chordSemitones.contains(((($0) % 12) + 12) % 12) }
            for (i, s) in colour.prefix(3).enumerated() {
                if let c = col(matching: s) { picks.append((pad(2 + i % 2, c), 0.24)) }
            }
        case .tanpura:
            let fifth = harmony.mode.chordSemitones.contains(6) ? 6 : 7
            if let f = col(matching: fifth) { picks.append((pad(1, f), 0.55)) }
            if let r = col(matching: 0) {
                picks += [(pad(1, r), 0.62), (pad(2, r), 0.5), (pad(0, r), 0.9)]
            }
        case .pedalRoot:
            if let r = col(matching: 0) { picks += [(pad(0, r), 0.95), (pad(1, r), 0.4)] }
        }

        for p in picks { sound(pad: p.pad, level: p.level) }
        show("\(voicing.rawValue) — \(voicing.detail)")
    }

    // MARK: - Status

    public func show(_ text: String) {
        status = text
        statusResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.status = "\(self.harmony.subtitle) · A\(Int(self.harmony.a4))"
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}
