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
    /// Held mid-journey. `isRunning` stays true — the session is still this
    /// session — but the clock stops, so every ramp resumes exactly where it was
    /// rather than restarting or jumping to where it would have got to.
    @Published public private(set) var isPaused = false
    /// Seconds since Flow started, for the UI's slow pulse.
    @Published public private(set) var elapsed: Double = 0

    /// Whether Flow gets to choose the key at the moment it starts.
    ///
    /// Off on the Mac, where the key is the player's — they set it on the grid and
    /// Flow has no business overruling it. On the phone there is no grid and
    /// nothing else ever touches the harmony, so leaving this off meant every
    /// session opened in the built-in default of D Dorian and, since Flow never
    /// moves the key once running, spent its entire life on modal variants of D.
    ///
    /// This is not the same as the key *drifting*, which stays forbidden for the
    /// reasons written up on `Gesture` — a fresh key is chosen while nothing is
    /// sounding yet, so there is no glide and nothing to notice.
    public var picksKeyOnStart = false

    private unowned let model: ThrumModel
    private var keyPicked = false
    private var timer: Timer?
    private var clock: Double = 0
    private var ramps: [Param: Ramp] = [:]
    private var due: [Gesture: Double] = [:]
    private var pending: [(at: Double, run: () -> Void)] = []
    private var rng = Rng(seed: Rng.freshSeed())
    /// When each discrete quality last changed, on Flow's own clock. Only used to
    /// work out how much of a vote it may take — see `Taste.credit(dwell:)`.
    private var changedAt: [Taste.TraitKind: Double] = [:]

    /// The last vote actually written to the book, and what the drone was at the
    /// time. See `rate` — this is what stops one opinion being counted five times.
    private var lastRated: (vote: Taste.Vote, traits: [Taste.TraitKind: Int])?

    private var taste: Taste { model.taste }

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

    /// One drift in six ignores everything the thumbs have taught, and that is not
    /// a hedge against the learning being wrong — it is the only way it can ever be
    /// corrected. A control kept inside its learned band is a control whose other
    /// settings never get heard again, so they never get rated, so the band can only
    /// ever tighten. Occasionally wandering outside is what keeps the evidence
    /// coming in.
    private static let exploration = 0.18

    private func drift(_ p: Param, _ bounds: (low: Double, high: Double), over seconds: Double) {
        let band = rng.chance(Self.exploration) ? bounds : taste.band(p, within: bounds)
        ramp(p, to: rng.range(band.low, band.high), over: seconds)
    }

    // MARK: - Choosing, with a thumb on the scale

    /// Every discrete choice Flow makes goes through here rather than `rng.pick`,
    /// so a liked mode comes up more often and a disliked one comes up less — and
    /// nothing is ever off the table, because `Taste.weight` has a floor.
    private func choose(_ kind: Taste.TraitKind, from candidates: [Int], excluding: Int? = nil) -> Int {
        var pool = candidates
        if let excluding, pool.count > 1 { pool.removeAll { $0 == excluding } }
        guard !pool.isEmpty else { return candidates.first ?? 0 }
        return rng.pick(pool, weights: taste.weights(kind, pool))
    }

    private func chooseVoicing(excluding current: ThrumModel.Voicing? = nil) -> ThrumModel.Voicing {
        var pool = Self.openings
        if let current, pool.count > 1 { pool.removeAll { $0 == current } }
        let all = ThrumModel.Voicing.allCases
        let weights = pool.map { taste.weight(.voicing, all.firstIndex(of: $0) ?? 0) }
        return rng.pick(pool, weights: weights)
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
        changedAt.removeAll()
        // A new journey is a new thing to have an opinion about, even in the case
        // where the dice happen to hand back the drone that just ended.
        lastRated = nil
        // Reseeded on every start, not just at launch, so stopping and starting
        // again gives a fresh journey rather than resuming the old one's dice.
        rng = Rng(seed: Rng.freshSeed())

        // Stagger the first firing of everything, so Flow doesn't open with all
        // its gestures at once.
        for g in Gesture.allCases {
            due[g] = rng.range(g.interval.low * 0.15, g.interval.low * 0.6)
        }
        // Before anything is gated on, so this is a choice rather than a glide.
        chooseFreshKey()
        // Something has to be sounding for any of this to mean anything.
        if !model.padOn.contains(true) {
            model.apply(chooseVoicing())
        }
        // Harmony moves slowly in Flow. Every key, mode and temperament change
        // glides at this rate, so a fifth becomes a modulation you notice
        // afterwards rather than a sweep you notice happening.
        model.engine.glideSeconds = Self.flowGlide
        model.show("Flow — the instrument takes it from here")

        startClock()
    }

    private func startClock() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(0.1) }
        }
    }

    /// Hold everything where it is. Called when the audio stops for a reason that
    /// is not the end of the session — the listener paused it, or Siri did.
    ///
    /// Only the clock stops. Ramps, gesture timers and the taste snapshot's idea of
    /// how long each quality has been sounding all freeze with it, which is the
    /// point: a drone paused for a ninety-second phone call should come back to the
    /// forty-second slide it was in the middle of, not to wherever that slide would
    /// have finished, and certainly not to a fresh journey. Wall-clock time passing
    /// while nothing is audible is not time this instrument has lived through.
    public func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        timer?.invalidate()
        timer = nil
    }

    public func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        startClock()
    }

    /// Pick a key — and an opening mode — for this session. Idempotent within a
    /// run, so a host that wants the key settled *before* it sounds an opening
    /// voicing can call it itself and `start()` will leave that choice alone.
    ///
    /// Every degree of the grid is tuned relative to the root, so no key is
    /// harmonically better than another here; all that changes between them is how
    /// high the drone sits, and a pitch class is at most a semitone shy of an
    /// octave from D either way. The one thing worth ruling out is the key it was
    /// already in, because a session that opens where the last one ended is
    /// exactly the complaint this answers — and on a phone that has to outlive the
    /// process, since a passive app is killed between listens far more often than
    /// it is stopped and started again. Hence the one value Thrum keeps on disk.
    ///
    /// The mode goes with it. Flow already turns modes over every few minutes, but
    /// the *first* few minutes were always Dorian, and the opening is the part
    /// anyone hears deliberately.
    public func chooseFreshKey() {
        guard picksKeyOnStart, !keyPicked else { return }
        keyPicked = true
        let store = UserDefaults.standard
        let previous = store.object(forKey: Self.lastKeyDefault) as? Int
            ?? model.harmony.keyPitchClass
        let candidates: [Int] = (0..<12).filter { $0 != previous }
        // The one place a learned key preference can be acted on. Flow never moves
        // the key while it plays, so if the thumbs say this listener keeps liking
        // drones in B♭, the only moment that can matter is this one.
        let key = choose(.key, from: candidates)
        store.set(key, forKey: Self.lastKeyDefault)
        model.setKey(key)
        model.setMode(choose(.mode, from: Self.restfulModes))
    }

    private static let lastKeyDefault = "flow.lastKey"

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        isPaused = false
        keyPicked = false
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
        // `isPaused` is checked here and not only at the timer, because the timer is
        // not the only thing that drives this: the offline harness calls `advance`
        // directly, and a host could too. Pause has to be a property of the director
        // rather than a property of one particular clock, or "paused" quietly means
        // "paused unless something else is ticking it".
        guard isRunning, !isPaused else { return }
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

    /// Note what is *not* here: the key never moves, and neither does the
    /// register. Both were tried and both are too disruptive under a director —
    /// moving the key glides every sounding pitch by a fourth or a fifth, and
    /// moving the register glides them all by an octave, and no amount of
    /// stretching the glide or hiding it under a breath stops that reading as an
    /// event you didn't ask for. Flow stays in the key it was given and finds its
    /// variety inside it: modes, voicings, registers of the *voicing*,
    /// temperaments, timbres and arpeggios. Where the key comes from in the first
    /// place is a separate question — see `picksKeyOnStart`.
    private enum Gesture: CaseIterable {
        case drift, voicing, mode, register, timbre, pulse, jawari, tuning, field

        /// Seconds between firings. Mutually unrelated on purpose — the whole
        /// instrument is built on periods that never line up, and this is that
        /// idea applied to the arrangement rather than the waveform.
        var interval: (low: Double, high: Double) {
            switch self {
            case .drift:   return (9, 23)
            case .voicing: return (110, 270)
            case .mode:    return (150, 330)
            case .register: return (95, 240)
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
            // Written as "a quarter of the time, add a tone — otherwise rebuild",
            // rather than the other way round, so that a missing quiet pad falls
            // through to a real voicing change instead of the gesture doing nothing
            // at all. Same odds, no silent branch.
            if rng.chance(0.25), let pad = quietPad() {
                model.sound(pad: pad, level: rng.range(0.25, 0.55))
            } else {
                moveVoicing()
            }

        case .mode:
            moveMode()

        case .register:
            // Where the drone sits, without moving what it is. The same scale
            // degree is let go in one octave and swelled in another, so this is a
            // crossfade rather than a glide — the pitch that arrives was never
            // somewhere else. That is the whole reason it can be done in the open
            // while a key change cannot.
            guard let from = soundingPad() else { return }
            let col = from % Harmony.cols
            let rows = (0..<Harmony.rows).filter { $0 != from / Harmony.cols }
            guard !rows.isEmpty else { return }
            let to = rows[rng.int(rows.count)] * Harmony.cols + col
            guard !model.padOn[to] else { return }
            let level = model.padLevel[from]
            model.release(pad: from)
            model.sound(pad: to, level: min(0.85, max(0.22, level)))

        case .timbre:
            moveTimbre()

        case .pulse:
            shiftPulse()

        case .jawari:
            if let pad = soundingPad() { model.toggleSitar(pad: pad) }

        case .tuning:
            moveTuning()

        case .field:
            guard model.spatialEnabled else { return }
            drift(.fieldRadius, Self.spatialRoam[.fieldRadius]!, over: rng.range(40, 120))
            drift(.fieldLift, Self.spatialRoam[.fieldLift]!, over: rng.range(40, 120))
        }
    }

    // MARK: - Moving one quality

    /// The four discrete changes Flow can make, each of which **always lands on
    /// something different from what is sounding**.
    ///
    /// That exclusion used to be optional and is now the whole point. A weighted
    /// draw over eight timbres will pick the current one about an eighth of the
    /// time, and a "change the timbre" gesture that changes it to itself is a
    /// gesture that quietly did nothing. Tolerable while these only fired on their
    /// own timers — you would never know a scheduled change had no-opped. Not
    /// tolerable now that thumbs-down pulls the next one forward, because then the
    /// no-op is a button press that produced silence where a change was promised.
    ///
    /// They live outside `perform` so that pulling one forward runs exactly the
    /// scheduled code — the crossfade in `apply`, the glide in `setMode`, the
    /// nine-second breath around a timbre. A vote changes *when* Flow acts, never
    /// how carefully.

    private func moveVoicing() {
        let next = chooseVoicing(excluding: model.voicing)
        changedAt[.voicing] = clock
        model.apply(next)
    }

    private func moveMode() {
        let next = choose(.mode, from: Self.restfulModes, excluding: model.harmony.modeIndex)
        changedAt[.mode] = clock
        model.setMode(next)
    }

    private func moveTuning() {
        // Retuning glides over half a second, so this is a modulation.
        let next = choose(.tuning, from: TuningSystem.allCases.map(\.rawValue),
                          excluding: model.harmony.tuning.rawValue)
        changedAt[.tuning] = clock
        model.setTuning(TuningSystem(rawValue: next) ?? .just5Limit)
    }

    private func moveTimbre() {
        let next = choose(.timbre, from: Array(0..<TimbreCatalog.all.count),
                          excluding: model.timbreIndex)
        breathe {
            // Stamped here rather than at the call, because this is when the timbre
            // actually changes — nine and a half seconds after the breath began.
            self.changedAt[.timbre] = self.clock
            self.model.setTimbre(next)
        }
    }

    // MARK: - Rating

    /// Two buttons' worth of API.
    ///
    /// The two thumbs are deliberately **not** symmetrical in what they do to the
    /// sound, only in what they teach.
    ///
    /// **Thumbs-up changes nothing.** It is filed and that is all. An earlier
    /// version pushed the disruptive gestures out so a praised drone would last
    /// longer, and it was wrong for a reason worth keeping written down: saying you
    /// like something should not be a thing you have to think twice about pressing.
    /// The moment approving of a drone also silently rearranges it, the button has a
    /// cost, and a rating button with a cost gets used less and teaches less.
    ///
    /// **Thumbs-down brings the next change forward.** Not a new or special change —
    /// whichever one Flow had already planned next, simply sooner. That keeps every
    /// transition on the rails it was always going to run on (the crossfade in
    /// `apply`, the glide in `setMode`, the nine-second breath around a timbre), and
    /// it means the button never invents an event of its own. What arrives is still
    /// shaped by the vote, because every choice Flow makes is weighted by taste.
    /// **One opinion per drone.** A vote is spread across every quality that was
    /// audible when it was cast, which only averages out if each opinion is cast
    /// once. Pressing ★ five times while the same drone plays is not five listeners
    /// agreeing — it is one listener pressing a button five times, and letting it
    /// through would put five times the weight on whichever key, mode, temperament
    /// and timbre happened to be sounding. That is the one kind of noise this design
    /// cannot average away, because it is entirely one-sided.
    ///
    /// So the gate is on *what the drone is*, not on the clock: a second vote is
    /// recorded once any discrete quality has changed, however soon that is, and not
    /// before, however long the listener waits. A fixed debounce interval would have
    /// been both too short (Flow holds a voicing for minutes) and too long (⏭ can
    /// change the drone in a tenth of a second).
    ///
    /// Two things deliberately still happen on a repeat press. The listener always
    /// gets the acknowledgement, because a button that silently ignores you reads as
    /// broken. And thumbs-down always hurries the next change along — that is what
    /// makes a second ⏭ meaningful rather than merely tolerated, since by the time it
    /// lands the drone is a different one and the vote counts.
    ///
    /// Changing your mind is not a repeat: the opposite vote on an unchanged drone is
    /// a new fact and goes in. It is not an undo — nothing is subtracted — but the
    /// two sides of the ledger are what cancel, so saying both is self-correcting.
    @discardableResult
    public func rate(_ vote: Taste.Vote) -> Bool {
        let snapshot = snapshot()
        let traits = snapshot.traits.mapValues(\.value)
        let repeated = lastRated.map { $0.vote == vote && $0.traits == traits } ?? false
        if !repeated {
            taste.record(vote, snapshot)
            lastRated = (vote, traits)
        }

        guard isRunning else {
            // Rating the tail of something you have just stopped is legitimate, and
            // there is nothing to hurry along.
            model.show(vote == .up ? "Noted — more like that" : "Noted — less like that")
            return !repeated
        }
        switch vote {
        case .up:
            model.show("Noted — more like this")
        case .down:
            hastenNextChange()
            model.show("Noted — less like this")
        }
        return !repeated
    }

    /// Gestures that change the character of the drone rather than nudging a
    /// slider, and that are *guaranteed* to change it — each excludes what is
    /// already sounding. One of them is always pending, so there is always
    /// something to pull forward.
    ///
    /// `.register` is a characterful change too and is deliberately not here: it
    /// can legitimately find nowhere to go (every other octave of that column
    /// already sounding) and quietly return, which is fine on its own timer and
    /// wrong as the answer to a button press.
    private static let characterful: [Gesture] = [.voicing, .mode, .timbre, .tuning]

    private func hastenNextChange() {
        let soonest = Self.characterful.min {
            (due[$0] ?? .greatestFiniteMagnitude) < (due[$1] ?? .greatestFiniteMagnitude)
        }
        guard let soonest else { return }
        // Due now, so it fires on the next tick and then reschedules itself on its
        // own interval exactly as if it had come round naturally. Nothing else in
        // the timetable is touched — pressing it twice does not stack up a queue of
        // changes waiting to land on top of each other.
        due[soonest] = clock
    }

    /// Everything true of the drone at this moment, with each discrete quality
    /// weighted by how long it has been in place.
    private func snapshot() -> Taste.Snapshot {
        var out = Taste.Snapshot()

        func note(_ kind: Taste.TraitKind, _ value: Int) {
            out.traits[kind] = Taste.Snapshot.Trait(
                value: value,
                credit: Taste.credit(dwell: clock - (changedAt[kind] ?? 0)))
        }
        note(.key, model.harmony.keyPitchClass)
        note(.mode, model.harmony.modeIndex)
        note(.tuning, model.harmony.tuning.rawValue)
        note(.timbre, model.timbreIndex)
        if let voicing = model.voicing,
           let index = ThrumModel.Voicing.allCases.firstIndex(of: voicing) {
            note(.voicing, index)
        }

        for p in Self.learnable where audible(p) {
            out.params[p] = ThrumModel.spec(p).normalized(model.value(p))
        }
        return out
    }

    /// Exactly the controls Flow drives — which is also the set it is allowed to
    /// learn about. Output is absent because Flow never touches it, so a preference
    /// for it could only ever record how loud the room was.
    private static let learnable: [Param] = Array(roam.keys) + Array(spatialRoam.keys)

    private static let pulseOnly: Set<Param> = [.tempo, .pluckAttack, .pluckDecay,
                                                .arpLevel, .swing, .humanize]

    /// Whether this control is currently making any difference to what is coming
    /// out. Filing an opinion about Field Radius while the phone is on its own
    /// speaker, or about Accent with no arpeggio running, is recording a preference
    /// about something the listener demonstrably could not hear — and enough of
    /// those is how a database of real preferences turns into noise.
    private func audible(_ p: Param) -> Bool {
        if Self.spatialRoam[p] != nil { return model.spatialEnabled }
        if Self.pulseOnly.contains(p) { return model.pulseRunning }
        if p == .sitarDepth { return model.padSitar.contains { $0 > 0.01 } }
        return true
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

    /// Roulette-wheel draw, for the one thing Flow uses learned preferences for:
    /// tilting a choice without removing any of the options. Falls back to a flat
    /// pick on anything malformed — a bad weight array should make this feature
    /// invisible, never make Flow stop choosing.
    mutating func pick<T>(_ xs: [T], weights: [Double]) -> T {
        guard xs.count > 1, weights.count == xs.count else { return xs[int(xs.count)] }
        var total = 0.0
        for w in weights where w > 0 && w.isFinite { total += w }
        guard total > 0 else { return xs[int(xs.count)] }
        var r = unit() * total
        for (i, w) in weights.enumerated() where w > 0 && w.isFinite {
            r -= w
            if r <= 0 { return xs[i] }
        }
        return xs[xs.count - 1]
    }
}
