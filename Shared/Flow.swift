import Foundation

/// Flow — the instrument playing itself.
///
/// The point is music you can work through: something is always moving, nothing
/// ever announces itself, and you should never look up because of a jump. That
/// makes the *transitions* the whole design, not the destinations.
///
/// Two rules follow from it. First, Flow never sets a value — it opens a **ramp**
/// and slides, over twenty to ninety seconds, on a curve with zero velocity and
/// zero acceleration at both ends, so a change has no edge to notice at either
/// side. Second, the one genuinely discontinuous thing in the instrument —
/// swapping a timbre, which recomputes every partial — is hidden underneath a
/// **breath**: Flow leans on Swell Ride, changes the reeds while the drone is
/// down, and brings it back up. That reads as the room inhaling.
///
/// Every gesture runs on its own clock at its own tempo, so nothing lines up:
/// parameters drift every ten seconds or so, voicings turn over every few
/// minutes, the key moves maybe twice an hour. The instrument's own modulation is
/// already prime-numbered and non-repeating; this is the same idea one level up.
@MainActor
public final class FlowDirector: ObservableObject {
    @Published public private(set) var isRunning = false
    /// Seconds since Flow started, for the UI's slow pulse.
    @Published public private(set) var elapsed: Double = 0

    private unowned let model: ThrumModel
    private var timer: Timer?
    private var clock: Double = 0
    private var ramps: [Param: Ramp] = [:]
    private var due: [Gesture: Double] = [:]
    private var pending: [(at: Double, run: () -> Void)] = []
    private var rng = Rng(seed: Rng.freshSeed())

    public init(model: ThrumModel) {
        self.model = model
    }

    // MARK: - Ramps

    private struct Ramp {
        let from: Double
        let to: Double
        let start: Double
        let duration: Double

        /// Smootherstep. Ordinary smoothstep still has an acceleration step at
        /// the ends, and on a forty-second slide of something like Brightness
        /// that is audible as the moment the movement starts.
        func value(at t: Double) -> Double {
            let x = min(1, max(0, (t - start) / max(0.01, duration)))
            let e = x * x * x * (x * (x * 6 - 15) + 10)
            return from + (to - from) * e
        }
        func done(at t: Double) -> Bool { t >= start + duration }
    }

    /// Where Flow is allowed to roam, per control. Deliberately narrower than
    /// each slider's full travel: these are the ranges that stay pleasant for an
    /// hour, not the ranges that are possible.
    ///
    /// Two absences are on purpose. **Output** is never touched — the volume is
    /// the player's business and nothing else's. And **Presence Cut** has a floor
    /// of 0.45, because energy around 3 kHz is what makes a long drone tiring and
    /// Flow is the one thing here that will run for hours unattended.
    private static let roam: [Param: (low: Double, high: Double)] = [
        .swell: (5, 22),          .fade: (7, 30),
        .beating: (0.25, 0.75),   .drift: (0.25, 0.80),
        .motion: (0.35, 0.80),    .sitarDepth: (0.20, 0.70),
        .padLevel: (0.55, 0.85),
        .brightness: (0.32, 0.72), .warmth: (0.40, 0.72),
        .presence: (0.45, 0.85),  .air: (0.20, 0.60),
        .drive: (0.10, 0.40),
        .reverbDecay: (8, 26),    .reverbMix: (0.28, 0.60),
        .reverbDamp: (0.30, 0.70), .reverbSize: (0.90, 1.60),
        .width: (0.90, 1.80),     .spatialDrift: (0.30, 1.00),
        .globalSwell: (0.60, 1.00),
        .arpLevel: (0.35, 0.75),  .pluckAttack: (0.02, 0.25),
        .pluckDecay: (0.70, 4.00), .swing: (0, 0.35),
        .humanize: (0.10, 0.50),
        .tempo: (46, 88),
    ]

    /// Params that only mean anything with the spatial field up.
    private static let spatialRoam: [Param: (low: Double, high: Double)] = [
        .fieldRadius: (1.0, 3.2), .fieldLift: (8, 34),
    ]

    /// The shortest slide Flow will ever open. Anything quicker than this reads
    /// as an event rather than a drift — and at a 0.1 s tick it is also the point
    /// where a single step starts to exceed a few percent of a control's travel,
    /// which is exactly what `Tools/flow` measures.
    static let shortestRamp: Double = 9

    /// Pitch-glide time while Flow is driving, against the app's ordinary one. A
    /// fourth or a fifth arriving over seven and a half seconds is a modulation;
    /// the same interval in half a second is a lurch.
    static let flowGlide: Double = 7.5
    static let handGlide: Double = 0.55

    private func ramp(_ p: Param, to target: Double, over seconds: Double) {
        let spec = ThrumModel.spec(p)
        let clamped = min(max(target, spec.range.lowerBound), spec.range.upperBound)
        ramps[p] = Ramp(from: model.value(p), to: clamped, start: clock,
                        duration: max(Self.shortestRamp, seconds))
    }

    private func drift(_ p: Param, _ bounds: (low: Double, high: Double), over seconds: Double) {
        ramp(p, to: rng.range(bounds.low, bounds.high), over: seconds)
    }

    private func after(_ delay: Double, _ run: @escaping () -> Void) {
        pending.append((at: clock + delay, run: run))
    }

    // MARK: - Transport

    public func toggle() { isRunning ? stop() : start() }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        clock = 0
        elapsed = 0
        ramps.removeAll()
        pending.removeAll()
        // Reseeded on every start, not just at launch, so stopping and starting
        // again gives a fresh journey rather than resuming the old one's dice.
        rng = Rng(seed: Rng.freshSeed())

        // Stagger the first firing of everything, so Flow doesn't open with all
        // its gestures at once.
        for g in Gesture.allCases {
            due[g] = rng.range(g.interval.low * 0.15, g.interval.low * 0.6)
        }
        // Something has to be sounding for any of this to mean anything.
        if !model.padOn.contains(true) {
            model.apply(rng.pick(Self.openings))
        }
        // Harmony moves slowly in Flow. Every key, mode and temperament change
        // glides at this rate, so a fifth becomes a modulation you notice
        // afterwards rather than a sweep you notice happening.
        model.engine.glideSeconds = Self.flowGlide
        model.show("Flow — the instrument takes it from here")

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(0.1) }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        ramps.removeAll()
        pending.removeAll()
        model.engine.glideSeconds = Self.handGlide
        // Deliberately no snap-back: wherever Flow had got to is now the patch,
        // which is often better than whatever you started from.
        model.show("Flow off — everything stays where it drifted to")
    }

    // MARK: - Tick

    /// Drive Flow without a run loop, for the offline harness — it compresses an
    /// hour of drifting into a second so the invariants can actually be checked.
    /// The app uses the timer.
    func advance(by dt: Double) { tick(dt) }

    private func tick(_ dt: Double) {
        guard isRunning else { return }
        clock += dt
        elapsed = clock

        for (p, r) in ramps {
            model.set(p, r.value(at: clock))
            if r.done(at: clock) { ramps[p] = nil }
        }

        if !pending.isEmpty {
            let ready = pending.filter { $0.at <= clock }
            pending.removeAll { $0.at <= clock }
            for item in ready { item.run() }
        }

        for g in Gesture.allCases {
            guard let t = due[g], clock >= t else { continue }
            due[g] = clock + rng.range(g.interval.low, g.interval.high)
            perform(g)
        }
    }

    // MARK: - Gestures

    private enum Gesture: CaseIterable {
        case drift, voicing, mode, key, timbre, pulse, jawari, tuning, field

        /// Seconds between firings. Mutually unrelated on purpose — the whole
        /// instrument is built on periods that never line up, and this is that
        /// idea applied to the arrangement rather than the waveform.
        var interval: (low: Double, high: Double) {
            switch self {
            case .drift:   return (9, 23)
            case .voicing: return (110, 270)
            case .mode:    return (150, 330)
            case .key:     return (280, 640)
            case .timbre:  return (210, 470)
            case .pulse:   return (75, 200)
            case .jawari:  return (130, 290)
            case .tuning:  return (430, 900)
            case .field:   return (85, 220)
            }
        }
    }

    /// Voicings Flow will open with or move to. Weighted to the sustained ones —
    /// these are the ones that hold up for minutes without asking anything.
    private static let openings: [ThrumModel.Voicing] = [
        .tanpura, .openFifths, .pedalRoot, .modalSpread, .aitake,
        .hardanger, .guqin, .launeddas, .highland, .gyuto, .didgeridoo, .uilleann,
    ]

    /// Modes Flow will move between. The tense ones — Locrian, Altered,
    /// Diminished, Whole Tone — are left out: they are good to play *over* and
    /// wearing to sit *inside* for an hour.
    private static let restfulModes = [0, 1, 3, 4, 5, 11, 14, 8]

    private func perform(_ g: Gesture) {
        switch g {
        case .drift:
            // Two to four controls at a time, each on its own slow slide, so
            // there are always several overlapping and none of them is the event.
            var pool = Array(Self.roam.keys)
            if model.spatialEnabled { pool += Array(Self.spatialRoam.keys) }
            let n = 2 + rng.int(3)
            for _ in 0..<n {
                let p = rng.pick(pool)
                let bounds = Self.roam[p] ?? Self.spatialRoam[p]!
                drift(p, bounds, over: rng.range(20, 90))
            }

        case .voicing:
            // apply() fades what is sounding at the Fade setting and swells the
            // new stack in at the Swell setting, so a voicing change is already a
            // slow crossfade rather than a cut.
            if rng.chance(0.75) {
                model.apply(rng.pick(Self.openings))
            } else if let pad = quietPad() {
                model.sound(pad: pad, level: rng.range(0.25, 0.55))
            }

        case .mode:
            model.setMode(rng.pick(Self.restfulModes))

        case .key:
            // The largest harmonic move Flow makes, so it gets both protections:
            // the glide is already wound out to seven and a half seconds, and the
            // change happens under a breath, with the drone down at a fifth of its
            // level while the pitches travel. A fourth or a fifth shares the most
            // notes with where you already were, which is the rest of why it sits.
            let up = rng.chance(0.5)
            let octaveInstead = rng.chance(0.28)
            breathe {
                if octaveInstead {
                    self.model.nudgeOctave(self.model.harmony.rootOctave >= 4 ? -1 : 1)
                } else {
                    self.model.nudgeKey(up ? 7 : -5)
                }
            }

        case .timbre:
            breathe {
                self.model.setTimbre(self.rng.int(TimbreCatalog.all.count))
            }

        case .pulse:
            shiftPulse()

        case .jawari:
            if let pad = soundingPad() { model.toggleSitar(pad: pad) }

        case .tuning:
            // Retuning glides over half a second, so this is a modulation.
            model.setTuning(rng.pick(TuningSystem.allCases))

        case .field:
            guard model.spatialEnabled else { return }
            drift(.fieldRadius, Self.spatialRoam[.fieldRadius]!, over: rng.range(40, 120))
            drift(.fieldLift, Self.spatialRoam[.fieldLift]!, over: rng.range(40, 120))
        }
    }

    /// Dip the whole drone, do something that would otherwise jump, bring it
    /// back. Swapping a timbre recomputes every partial of every voice; heard at
    /// full level that is a lurch, and heard through this it is the room
    /// breathing.
    private func breathe(_ change: @escaping () -> Void) {
        let back = model.value(.globalSwell)
        ramp(.globalSwell, to: 0.22, over: 9)
        after(9.6) {
            change()
            self.ramp(.globalSwell, to: max(0.75, back), over: 14)
        }
    }

    /// Arpeggios come and go rather than running all evening: a lane arriving
    /// after four minutes of stillness is worth far more than four lanes running
    /// the whole time.
    private func shiftPulse() {
        if !model.pulseRunning {
            guard rng.chance(0.45) else { return }
            let choice = rng.int(PulsePreset.all.count)
            // Take the preset's lanes but not its tempo, and ease toward that
            // tempo instead — clamped into Flow's own range, since a couple of
            // the presets are brisker than this mode wants to sit at.
            model.applyPulsePreset(choice, adoptTempo: false)
            let bpm = PulsePreset.all[choice].bpm
            let band = Self.roam[.tempo]!
            ramp(.tempo, to: min(max(bpm, band.low), band.high), over: rng.range(18, 40))
            // Slide the accents down before starting, then fade them up, so the
            // arpeggio arrives out of nothing. Nothing here is ever *set*: even
            // though no plucks are sounding yet and a jump would be inaudible,
            // "every control only ever ramps" is worth keeping true so it can be
            // checked rather than assumed.
            ramp(.arpLevel, to: 0.02, over: 9)
            let target = rng.range(0.35, 0.7)
            let rise = rng.range(30, 70)
            after(9.4) {
                self.model.pulseRunning = true
                self.ramp(.arpLevel, to: target, over: rise)
            }
            return
        }
        switch rng.int(4) {
        case 0:
            // Leave. Fade the accents out first so it thins rather than stops.
            ramp(.arpLevel, to: 0.02, over: 22)
            after(23) { self.model.pulseRunning = false }
        case 1:
            let lane = rng.int(PulseCore.laneCount)
            model.setLaneDivision(lane, rng.int(Division.all.count))
        case 2:
            let lane = rng.int(PulseCore.laneCount)
            model.setLanePattern(lane, rng.pick(ArpPattern.allCases))
            model.setLaneSource(lane, rng.pick(ArpSource.allCases))
        default:
            let lane = rng.int(PulseCore.laneCount)
            model.setLaneSpan(lane, rng.int(RowSpan.all.count))
            if rng.chance(0.4) { model.nudgeLanePhase(lane) }
        }
    }

    private func soundingPad() -> Int? {
        let on = (0..<Harmony.padCount).filter { model.padOn[$0] }
        return on.isEmpty ? nil : on[rng.int(on.count)]
    }

    private func quietPad() -> Int? {
        let off = (0..<Harmony.padCount).filter { !model.padOn[$0] && model.tones[$0].isChordTone }
        return off.isEmpty ? nil : off[rng.int(off.count)]
    }
}

// MARK: - Randomness

/// A small xorshift, so Flow's wandering is its own and doesn't depend on the
/// system generator's mood.
struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    /// A different sequence every time Flow is started.
    static func freshSeed() -> UInt64 {
        UInt64.random(in: 1...UInt64.max)
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : min(n - 1, Int(unit() * Double(n))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}
