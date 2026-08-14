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
    // Pulse — appended, so a saved Launch Control map keeps its numbering.
    case tempo, pluckAttack, pluckDecay, arpLevel, swing, humanize
    // Spatial — likewise appended.
    case fieldRadius, fieldLift

    public var id: Int { rawValue }
}

public enum ParamGroup: String, CaseIterable, Identifiable {
    case voice = "Voice"
    case tone = "Tone"
    case space = "Space"
    case master = "Master"
    case pulse = "Pulse"
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
        if unit == "ms" { return String(format: "%.0f ms", v * 1000) }
        if unit == "bpm" { return String(format: "%.0f bpm", v) }
        if unit == "m" { return String(format: "%.1f m", v) }
        if unit == "°" { return String(format: "%.0f°", v) }
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

    /// The last voicing applied, or nil if nothing is sounding from one.
    ///
    /// Kept only so a vote has something to file the voicing under — `padOn` says
    /// which notes are sounding but not which of the fifteen stacks they came from,
    /// and "Gyütö" is the quality a listener has an opinion about.
    ///
    /// Deliberately *not* cleared when a single tone moves register. Flow does that
    /// every couple of minutes, and what makes a voicing that voicing is which
    /// intervals it uses and how they sit relative to each other — which a register
    /// crossfade keeps. Clearing on it would leave the label nil most of the time
    /// and this trait would never learn anything. Letting go of everything does
    /// clear it, because then the voicing genuinely isn't sounding any more.
    @Published public private(set) var voicing: Voicing?
    /// Set while `apply` is laying a stack down, so its own `fadeAll`/`sound` calls
    /// don't clear the label it is about to set.
    private var applyingVoicing = false

    // MARK: Taste

    /// What the listener likes, learned from the thumbs. Defaults to an in-memory
    /// database that never persists and never biases anything — the app hosts hand
    /// in a real store.
    public let taste: Taste

    // MARK: Pulse

    /// The clock and the four arpeggiators. Runs off the main thread; it is
    /// handed a resolved plan whenever anything it depends on moves.
    public let pulse: PulseCore

    @Published public var pulseRunning = false { didSet { pulse.setRunning(pulseRunning); pulseChanged() } }
    @Published public var tempo: Double = 68 { didSet { pulse.setTempo(tempo) } }
    @Published public var lanes: [ArpLane] = ArpLane.defaults { didSet { pulseChanged() } }
    @Published public var arpLevel: Double = 0.7 { didSet { pushFeel() } }
    @Published public var swing: Double = 0 { didSet { pushFeel() } }
    @Published public var humanize: Double = 0.22 { didSet { pushFeel() } }
    /// Last preset applied, so the Launchpad can light it.
    @Published public var pulsePreset: Int? = nil

    // MARK: Flow

    /// The instrument playing itself. Lazily made because it needs `self`.
    public lazy var flow: FlowDirector = FlowDirector(model: self)

    // MARK: Spatial

    /// AirPods head orientation. Owned here so the UI and the audio host see
    /// the same object.
    public let head = HeadTracker()

    /// Set by the host; flips the engine between the stereo and spatial chains
    /// and builds the spatial graph on first use.
    public var onSpatialChange: ((Bool) -> Void)?
    /// Set by the host; re-reads `field` and pushes it onto the nodes.
    public var onFieldChange: (() -> Void)?

    @Published public var spatialEnabled = false {
        didSet {
            guard spatialEnabled != oldValue else { return }
            onSpatialChange?(spatialEnabled)
            if spatialEnabled {
                show("Spatial field on — sixteen positions around you. Turn macOS's own Spatial Audio off for AirPods.")
            } else {
                head.stop()
                show("Back to stereo")
            }
        }
    }
    @Published public var field = SpatialField() { didSet { onFieldChange?() } }
    @Published public var headTracking = false {
        didSet {
            guard headTracking != oldValue else { return }
            if headTracking { head.start() } else { head.stop() }
        }
    }

    // MARK: Output route

    /// What the drone is coming out of. Owned here for the same reason as `head`
    /// — the host and the UI have to be holding the same object. Read-only: the
    /// device itself is chosen in Control Centre, which for AirPlay is the only
    /// place it *can* be chosen. See `AudioRoute`.
    public let route = AudioRoute()

    /// Overrides what the route implies about how to render the spatial field.
    ///
    /// The route heuristic guesses right for AirPods and for an interface feeding
    /// a PA, and wrong for the one case that is neither: a *Bluetooth speaker*,
    /// which looks like AirPods to CoreAudio and sounds like a room. Rather than
    /// pretend the guess is always right, it is a switch.
    public enum SpatialRender: String, CaseIterable, Identifiable, Sendable {
        case auto = "Auto"
        case headphones = "Headphones"
        case speakers = "Speakers"
        public var id: String { rawValue }
    }

    @Published public var spatialRender: SpatialRender = .auto {
        didSet {
            guard spatialRender != oldValue else { return }
            onRenderModeChange?()
        }
    }

    /// Set by the host; re-reads the render mode and pushes it onto the
    /// environment node. Cheap — no graph change, no restart.
    public var onRenderModeChange: (() -> Void)?

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

    /// `taste` is optional rather than defaulted to `Taste()` because a default
    /// argument is evaluated in the caller's context, which is not this actor.
    public init(engine: DroneEngine, taste: Taste? = nil) {
        self.engine = engine
        self.taste = taste ?? Taste()
        pulse = PulseCore(engine: engine)
        values = Self.specs.map { $0.range.lowerBound }
        // Seed from the engine's own defaults.
        for (i, spec) in Self.specs.enumerated() { values[i] = spec.get(self) }
        engine.timbreIndex = Int32(timbreIndex)
        tones = harmony.tones()
        pushAllTunings()

        // Tap tempo works the tempo out on the pulse queue; this is how the
        // number gets back to the slider.
        pulse.onTempo = { [weak self] bpm in
            guard let self else { return }
            self.set(.tempo, bpm)
            self.show("Tap — \(Int(bpm.rounded())) bpm")
        }
        pushFeel()
        pulseChanged()

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
    public static let specs: [ParamSpec] = voiceSpecs + toneSpecs + spaceSpecs + masterSpecs + pulseSpecs

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
        ParamSpec(param: .fieldRadius, name: "Field Radius", group: .space, range: 0.4...6, unit: "m",
                  detail: "Spatial mode only. How far out the ring of tones sits. Under a metre is a helmet; past three it is a room you're standing in.",
                  exponential: true,
                  get: { $0.field.radius }, set: { $0.field.radius = $1 }),
        ParamSpec(param: .fieldLift, name: "Field Lift", group: .space, range: 0...45, unit: "°",
                  detail: "Spatial mode only. How far apart the low and high octave rings are pushed vertically. At zero everything sits on one ring at ear level.",
                  exponential: false,
                  get: { $0.field.lift }, set: { $0.field.lift = $1 }),
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

    private static let pulseSpecs: [ParamSpec] = [
        ParamSpec(param: .tempo, name: "Tempo", group: .pulse, range: 20...200, unit: "bpm",
                  detail: "The beat every lane divides. Tap it in rather than typing it.",
                  exponential: true,
                  get: { $0.tempo }, set: { $0.tempo = min(200, max(20, $1)) }),
        ParamSpec(param: .pluckAttack, name: "Strike", group: .pulse, range: 0.002...0.6, unit: "ms",
                  detail: "How sharply an arpeggiated note arrives. Short is a pluck, long is a bow.",
                  exponential: true,
                  get: { $0.engine.pluckAttack }, set: { $0.engine.pluckAttack = $1 }),
        ParamSpec(param: .pluckDecay, name: "Ring", group: .pulse, range: 0.05...9, unit: "s",
                  detail: "How long it takes to fall back into the drone. Past a couple of seconds the notes stop being separate.",
                  exponential: true,
                  get: { $0.engine.pluckDecay }, set: { $0.engine.pluckDecay = $1 }),
        ParamSpec(param: .arpLevel, name: "Accent", group: .pulse, range: 0...1, unit: "%",
                  detail: "How far above the drone the arpeggio sits. Low is a shimmer inside the chord; high is a part.",
                  exponential: false,
                  get: { $0.arpLevel }, set: { $0.arpLevel = min(max($1, 0), 1) }),
        ParamSpec(param: .swing, name: "Swing", group: .pulse, range: 0...0.7, unit: "%",
                  detail: "Pushes every other step late, by a fraction of that lane's own step — so lanes at different rates all swing.",
                  exponential: false,
                  get: { $0.swing }, set: { $0.swing = min(max($1, 0), 0.7) }),
        ParamSpec(param: .humanize, name: "Unsteady", group: .pulse, range: 0...1, unit: "%",
                  detail: "Velocity wobble, the same every time round. Without a little of it a long cycle reads as a machine.",
                  exponential: false,
                  get: { $0.humanize }, set: { $0.humanize = min(max($1, 0), 1) }),
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
        // Which columns count as chord tones just changed under the lanes.
        pulseChanged()
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
        let wasOn = padOn[pad]
        padOn[pad] = true
        if !wasOn { pulseChanged() }
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
        let wasOn = padOn[pad]
        padOn[pad] = false
        engine.gate(pad: pad, on: false)
        if wasOn { pulseChanged() }
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
            // Only when the pad actually flips — aftertouch calls this at MIDI
            // rate and re-resolving the lanes on every message is waste.
            pulseChanged()
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
        if !applyingVoicing { voicing = nil }
        engine.fadeAll(seconds: quick ? 1.2 : nil)
        pulseChanged()
        show(quick ? "Letting go — 1.2 s" : "Letting go…")
    }

    public func panic() {
        for i in 0..<Harmony.padCount { padOn[i] = false; padLevel[i] = 0 }
        voicing = nil
        engine.panic()
        // Panic is the emergency key: it stops the clock too.
        pulseRunning = false
        show("Silence.")
    }

    // MARK: - Voicings

    /// Starting points, because a good drone is a specific chord voicing and not
    /// just "the notes of the chord". Most of these are borrowed from traditions
    /// that have been holding drones for a very long time — what is worth
    /// stealing from each is not its scale, which Thrum already has, but *which
    /// intervals it leaves out and in which register it puts the rest*.
    public enum Voicing: String, CaseIterable, Identifiable {
        case openFifths = "Open Fifths"
        case fullChord = "Full Chord"
        case modalSpread = "Modal Spread"
        case tanpura = "Tanpura"
        case pedalRoot = "Pedal Root"
        case highland = "Highland"
        case uilleann = "Uilleann"
        case gaida = "Gaida"
        case aitake = "Aitake"
        case launeddas = "Launeddas"
        case georgian = "Georgian"
        case didgeridoo = "Didgeridoo"
        case hardanger = "Hardanger"
        case gyuto = "Gyütö"
        case guqin = "Guqin"
        public var id: String { rawValue }

        var detail: String {
            switch self {
            case .openFifths:  return "Root and fifth in three registers. Nothing to argue with."
            case .fullChord:   return "Every chord tone, one per register, spread wide."
            case .modalSpread: return "Chord tones low, colour tones high. Most to blow over."
            case .tanpura:     return "The classic 5–1–1–1̇ cycle, all four registers."
            case .pedalRoot:   return "One low root, one octave. The strictest tonal center."
            case .highland:    return "Scotland — Great Highland pipes: a bass drone an octave under two tenors, and no fifth anywhere."
            case .uilleann:    return "Ireland — three uilleann drones an octave apart, with the regulators' triad sitting on top."
            case .gaida:       return "Bulgaria — the gaida's tonic under a second. The rub village singing is built on; turn Beating down for this one."
            case .aitake:      return "Japan — the shō's aitake cluster from gagaku: fourths and seconds over two octaves, every pipe the same weight, nothing in the bass."
            case .launeddas:   return "Sardinia — the triple pipe: the tumbu's low drone with a fourth and a fifth laid over it."
            case .georgian:    return "Georgia — village polyphony over the bass: fifth, fourth and a bare seventh, and no third at all."
            case .didgeridoo:  return "Australia — one fundamental and its own harmonic series, at harmonic-series levels. Almost all bottom."
            case .hardanger:   return "Norway — the hardingfele's sympathetic understrings: root, second, third and fifth ringing quietly in one high register."
            case .gyuto:       return "Tibet — Gyütö chant, with the fifth down in the lowest register where nobody else puts one."
            case .guqin:       return "China — the qin's open strings: pentatonic, so no fourth and no seventh, spread over all four octaves."
            }
        }
    }

    public func apply(_ voicing: Voicing) {
        applyingVoicing = true
        defer { applyingVoicing = false }
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
        func col(any semitones: [Int]) -> Int? {
            for s in semitones { if let c = col(matching: s) { return c } }
            return nil
        }
        /// The borrowed voicings are described in scale degrees — "a fourth over
        /// the drone" — and not every mode has the flavour of fourth they were
        /// built on. Take the interval when the mode has it, and otherwise the
        /// degree that simply *sits* in that position, which is what a player
        /// in that tradition would have reached for anyway. Never nil, so a
        /// voicing can't quietly come out half-built.
        func degree(_ semitones: [Int], position: Int) -> Int {
            col(any: semitones) ?? min(position, Harmony.cols - 1)
        }
        let root = col(matching: 0) ?? 0
        let second = degree([2, 1], position: 1)        // 9, else ♭9
        let third = degree([4, 3], position: 2)         // 3, else ♭3
        let fourth = degree([5, 6], position: 3)        // 11, else ♯11
        let fifth = degree([7, 6, 8], position: 4)      // 5, else ♭5 or ♯5
        let sixth = degree([9, 8], position: 5)         // 13, else ♭13
        let seventh = degree([10, 11], position: 6)     // ♭7, else 7

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

        case .highland:
            // Two tenor drones on the chanter's low A, a bass drone an octave
            // under them, and — the part worth stealing — no fifth at all.
            picks += [(pad(0, root), 0.95), (pad(1, root), 0.7), (pad(2, root), 0.45)]

        case .uilleann:
            picks += [(pad(0, root), 0.9), (pad(1, root), 0.55), (pad(2, root), 0.32),
                      (pad(2, third), 0.3), (pad(2, fifth), 0.3)]

        case .gaida:
            // Tonic and second in the same register. It beats on purpose; that
            // interval is the whole sound.
            picks += [(pad(0, root), 0.9), (pad(1, root), 0.5),
                      (pad(1, second), 0.46), (pad(2, second), 0.24)]

        case .aitake:
            // Gagaku's mouth-organ cluster: six pipes at one weight, seconds
            // and fourths, two octaves, and deliberately nothing underneath.
            picks += [(pad(1, root), 0.5), (pad(3, root), 0.42), (pad(1, second), 0.48),
                      (pad(2, fourth), 0.5), (pad(2, fifth), 0.48), (pad(2, seventh), 0.44)]

        case .launeddas:
            picks += [(pad(0, root), 0.95), (pad(1, fourth), 0.5),
                      (pad(1, fifth), 0.55), (pad(2, root), 0.3)]

        case .georgian:
            picks += [(pad(0, root), 0.85), (pad(1, fifth), 0.6),
                      (pad(2, fourth), 0.4), (pad(2, seventh), 0.34)]

        case .didgeridoo:
            // Partials 1, 2, 3, 4 at roughly 1/n, which is why it reads as one
            // enormous note rather than as a chord.
            picks += [(pad(0, root), 1.0), (pad(1, root), 0.4),
                      (pad(1, fifth), 0.26), (pad(2, root), 0.2)]

        case .hardanger:
            // Understrings only: one high register, quiet, nothing holding the
            // bottom. The resonance of an instrument nobody is playing yet.
            picks += [(pad(2, root), 0.4), (pad(2, second), 0.32),
                      (pad(2, third), 0.3), (pad(2, fifth), 0.36)]

        case .gyuto:
            // A fifth in the bottom octave. Every other voicing here keeps the
            // fifth up out of the mud; this one is the mud.
            picks += [(pad(0, root), 1.0), (pad(0, fifth), 0.5), (pad(1, root), 0.35)]

        case .guqin:
            picks += [(pad(0, root), 0.85), (pad(1, fifth), 0.5),
                      (pad(2, second), 0.34), (pad(2, sixth), 0.3), (pad(3, root), 0.24)]
        }

        // Two degrees can collapse onto one pad in a mode that hasn't got both
        // — whole tone has no perfect fourth or fifth, only the tritone sitting
        // between them. Keep the louder ask rather than letting whichever came
        // last quietly win.
        var levels: [Int: Double] = [:]
        for p in picks { levels[p.pad] = max(levels[p.pad] ?? 0, p.level) }
        for pad in levels.keys.sorted() { sound(pad: pad, level: levels[pad]!) }
        self.voicing = voicing
        show("\(voicing.rawValue) — \(voicing.detail)")
    }

    // MARK: - Pulse

    private func pushFeel() {
        pulse.setFeel(swing: swing, humanize: humanize, level: arpLevel)
    }

    /// Which scale degrees — grid columns — a lane draws from. Everything the
    /// arpeggiator plays comes out of the mode and chord that are already
    /// loaded; there is no second note pool to keep in step with the harmony.
    private func columns(for source: ArpSource) -> [Int] {
        switch source {
        case .scale:
            return Array(0..<Harmony.cols)
        case .chord:
            return (0..<Harmony.cols).filter { tones[$0].isChordTone }
        case .colour:
            return (0..<Harmony.cols).filter { !tones[$0].isChordTone }
        case .root:
            return (0..<Harmony.cols).filter { tones[$0].isRoot }
        case .held:
            // A column counts as held if any register of it is sounding, so
            // holding one chord low arpeggiates it in whichever registers each
            // lane is set to. Tap it in once, hear it in four octaves.
            return (0..<Harmony.cols).filter { col in
                (0..<Harmony.rows).contains { padOn[$0 * Harmony.cols + col] }
            }
        }
    }

    private func pads(for lane: ArpLane) -> [Int] {
        let cols = columns(for: lane.source)
        guard !cols.isEmpty else { return [] }
        let span = lane.span
        var out: [Int] = []
        out.reserveCapacity(cols.count * (span.high - span.low + 1))
        for row in span.low...span.high {
            for col in cols { out.append(row * Harmony.cols + col) }
        }
        return out.sorted()
    }

    /// Re-resolve every lane and hand the result to the clock. Cheap enough to
    /// call on any change — four lanes over thirty-two pads.
    public func pulseChanged() {
        var plan: [PulseCore.PlanLane] = []
        plan.reserveCapacity(lanes.count)
        for lane in lanes {
            var p = PulseCore.PlanLane()
            p.enabled = lane.enabled
            p.pads = lane.enabled ? pads(for: lane) : []
            p.perBeat = lane.division.perBeat
            p.pattern = lane.pattern
            p.level = lane.level
            p.accentEvery = max(1, lane.accentEvery)
            p.phase = lane.phase
            plan.append(p)
        }
        pulse.update(lanes: plan)
    }

    public func togglePulse() {
        pulseRunning.toggle()
        if pulseRunning {
            pulse.realign()
            let live = lanes.filter { $0.enabled }.count
            show("Pulse running — \(Int(tempo.rounded())) bpm, \(live) lane\(live == 1 ? "" : "s")")
        } else {
            show("Pulse stopped")
        }
    }

    public func tapTempo() {
        pulse.tap()
    }

    public func realignPulse() {
        pulse.realign()
        show("Lanes realigned")
    }

    public func nudgeTempo(_ delta: Double) {
        set(.tempo, tempo + delta)
        show("\(Int(tempo.rounded())) bpm")
    }

    public func scaleTempo(_ factor: Double) {
        set(.tempo, tempo * factor)
        show("\(Int(tempo.rounded())) bpm")
    }

    public func cycleSwing() {
        let steps: [Double] = [0, 0.16, 0.3, 0.46]
        let next = steps.first { $0 > swing + 0.01 } ?? 0
        set(.swing, next)
        show(next == 0 ? "Straight" : "Swing \(Int(next * 100))%")
    }

    public func cycleHumanize() {
        let steps: [Double] = [0, 0.22, 0.5, 0.8]
        let next = steps.first { $0 > humanize + 0.01 } ?? 0
        set(.humanize, next)
        show(next == 0 ? "Dead straight" : "Unsteady \(Int(next * 100))%")
    }

    // MARK: Lanes

    private func mutate(lane i: Int, _ body: (inout ArpLane) -> Void) {
        guard i >= 0, i < lanes.count else { return }
        var l = lanes[i]
        body(&l)
        lanes[i] = l
        pulsePreset = nil
    }

    public func describe(lane i: Int) -> String {
        guard i >= 0, i < lanes.count else { return "" }
        let l = lanes[i]
        guard l.enabled else { return "Lane \(i + 1) off" }
        return "Lane \(i + 1) — \(l.source.rawValue) · \(l.pattern.rawValue) · \(l.division.name) · octave \(l.span.name)"
    }

    public func toggleLane(_ i: Int) {
        mutate(lane: i) { $0.enabled.toggle() }
        show(describe(lane: i))
    }

    /// Picking a rate arms the lane too — one gesture on the hardware.
    public func setLaneDivision(_ i: Int, _ d: Int) {
        guard i >= 0, i < lanes.count else { return }
        if lanes[i].enabled && lanes[i].divisionIndex == d {
            mutate(lane: i) { $0.enabled = false }
        } else {
            mutate(lane: i) { $0.divisionIndex = d; $0.enabled = true }
        }
        show(lanes[i].enabled
             ? "Lane \(i + 1) — \(Division.at(d).name) · \(Division.at(d).detail)"
             : "Lane \(i + 1) off")
    }

    public func setLanePattern(_ i: Int, _ p: ArpPattern) {
        mutate(lane: i) { $0.pattern = p }
        show("Lane \(i + 1) — \(p.rawValue): \(p.detail)")
    }

    public func setLaneSource(_ i: Int, _ s: ArpSource) {
        mutate(lane: i) { $0.source = s }
        show("Lane \(i + 1) — \(s.rawValue): \(s.detail)")
    }

    public func setLaneSpan(_ i: Int, _ s: Int) {
        mutate(lane: i) { $0.spanIndex = min(max(s, 0), RowSpan.all.count - 1) }
        show("Lane \(i + 1) — octave \(lanes[i].span.name)")
    }

    public func setLaneLevel(_ i: Int, _ v: Double) {
        mutate(lane: i) { $0.level = min(max(v, 0), 1) }
    }

    public func cycleLanePattern(_ i: Int) {
        guard i >= 0, i < lanes.count else { return }
        let all = ArpPattern.allCases
        let next = all[((all.firstIndex(of: lanes[i].pattern) ?? 0) + 1) % all.count]
        setLanePattern(i, next)
    }

    public func cycleLaneSource(_ i: Int) {
        guard i >= 0, i < lanes.count else { return }
        let all = ArpSource.allCases
        let next = all[((all.firstIndex(of: lanes[i].source) ?? 0) + 1) % all.count]
        setLaneSource(i, next)
    }

    public func cycleLaneSpan(_ i: Int) {
        guard i >= 0, i < lanes.count else { return }
        setLaneSpan(i, (lanes[i].spanIndex + 1) % RowSpan.all.count)
    }

    /// Shove one lane a quarter beat later. The cheapest way to turn two lanes
    /// that are locked together into two lanes that are chasing each other.
    public func nudgeLanePhase(_ i: Int) {
        mutate(lane: i) { $0.phase = (($0.phase * 4).rounded() + 1).truncatingRemainder(dividingBy: 4) / 4 }
        show("Lane \(i + 1) — offset \(Int(lanes[i].phase * 4))/4 beat")
    }

    public func allLanesOff() {
        for i in lanes.indices { lanes[i].enabled = false }
        pulsePreset = nil
        show("All lanes off")
    }

    /// `adoptTempo: false` leaves the clock where it is and changes only the
    /// lanes — Flow uses that, because a preset's tempo arriving as a jump is the
    /// one thing in a preset that can't be slid into.
    public func applyPulsePreset(_ i: Int, adoptTempo: Bool = true) {
        guard i >= 0, i < PulsePreset.all.count else { return }
        let p = PulsePreset.all[i]
        lanes = p.lanes
        if adoptTempo { set(.tempo, p.bpm) }
        pulsePreset = i
        show("\(p.name) — \(p.detail)")
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
