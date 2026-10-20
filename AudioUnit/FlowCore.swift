import AudioToolbox
import Foundation

/// Flow inside the audio unit — the instrument playing itself.
///
/// The same rules as the app's `FlowDirector`, which is where the reasoning
/// behind each of them is written up: nothing is ever *set*, only slid on a
/// smootherstep ramp of twenty to ninety seconds; every gesture runs on its own
/// unrelated clock, so nothing lines up; and the key is never moved. Flow finds
/// its variety inside the key it was given — voicings, modes, registers,
/// temperaments, timbres, jawari.
///
/// What differs is where it runs. The app's director is a main-thread object
/// that plays the model. This one lives on the render thread and is clocked by
/// the audio itself, which is the only clock a plugin can trust: Logic renders
/// a bounce faster than real time and stops calling at all when nothing needs
/// sound, and a Flow timed by the wall would drift out of step with both. Here
/// an hour of Flow is an hour of rendered audio, in a bounce or out of one.
///
/// Render-thread rules therefore apply: every table is a raw buffer built at
/// init, and nothing below allocates. What it leaves out of the app's version
/// is what has no place in a plugin — Taste (no thumbs to press), the
/// arpeggiator (Logic has its own), and the spatial field.
final class FlowCore {
    private unowned let kernel: ThrumKernel

    private static let cols = Harmony.cols
    private static let rows = Harmony.rows
    private static let pads = Harmony.padCount
    private static let maxPicks = 8

    // MARK: Tables, built at init

    private let modeCount = ModeCatalog.all.count
    /// `mode * cols + col` → semitones above the tonal center, before the row's octave.
    private let modeSemitone: UnsafeMutablePointer<Int16>
    /// `mode * cols + col` → whether that column is a chord tone.
    private let modeChord: UnsafeMutablePointer<Bool>
    /// Voicings Flow may choose, as indexes into `DroneVoicing.allCases`.
    private let openingCount: Int
    private let openings: UnsafeMutablePointer<Int8>
    /// `(mode * voicingCount + voicing) * maxPicks + i` → pad and level.
    private let voicingCount = DroneVoicing.allCases.count
    private let pickPad: UnsafeMutablePointer<Int8>
    private let pickLevel: UnsafeMutablePointer<Double>
    private let pickCount: UnsafeMutablePointer<Int8>
    private let restfulCount: Int
    private let restful: UnsafeMutablePointer<Int8>
    private let timbreCount = TimbreCatalog.all.count
    private let tuningCount = TuningSystem.allCases.count

    // MARK: State

    private let padOn: UnsafeMutablePointer<Bool>
    private let padLevel: UnsafeMutablePointer<Double>
    private let padSitarDepth: UnsafeMutablePointer<Double>
    private var voicing = -1

    private var clock = 0.0
    private var dice = FlowDice(seed: 1)
    private var due: (drift: Double, voicing: Double, mode: Double, register: Double,
                      timbre: Double, jawari: Double, tuning: Double) = (0, 0, 0, 0, 0, 0, 0)
    /// After a reset has silenced Flow's voices, when to sound a fresh voicing.
    private var revoiceAt: Double?

    /// One open slide per parameter address. `rampLive` is the only field the
    /// other threads touch — `cancelRamp` clears it — and a Bool write is atomic
    /// enough for "stop sliding this".
    private let paramCount = ThrumParam.allCases.count
    private let rampFrom: UnsafeMutablePointer<Double>
    private let rampTo: UnsafeMutablePointer<Double>
    private let rampStart: UnsafeMutablePointer<Double>
    private let rampLength: UnsafeMutablePointer<Double>
    private let rampLive: UnsafeMutablePointer<Bool>
    /// Set from any thread when a control is taken over from outside; the render
    /// thread turns it into `heldUntil` on its next tick.
    private let touched: UnsafeMutablePointer<Bool>
    /// Flow-clock time before which drift leaves this control alone.
    private let heldUntil: UnsafeMutablePointer<Double>
    /// How long a hand on a control keeps Flow off it. Automation is a hand that
    /// never lets go — it arrives every buffer — so an automated control is
    /// Logic's for as long as the lane has data on it.
    private static let handHold = 300.0

    /// Where Flow is allowed to roam, in the audio unit's own units. The app's
    /// ranges, one for one (`FlowDirector.roam`): the ones that stay pleasant for
    /// an hour rather than the ones that are possible. Output is never touched,
    /// and Presence Cut never drops below 45%.
    private static let roam: [(ThrumParam, Double, Double)] = [
        (.swell, 5, 22), (.fade, 7, 30),
        (.beating, 25, 75), (.drift, 25, 80), (.motion, 35, 80),
        (.brightness, 32, 72), (.warmth, 40, 72), (.presence, 45, 85),
        (.air, 20, 60), (.drive, 10, 40),
        (.decay, 8, 26), (.wet, 28, 60), (.damping, 30, 70),
        (.size, 0.9, 1.6), (.width, 0.9, 1.8), (.fieldDrift, 30, 100),
    ]
    private let roamCount = FlowCore.roam.count
    private let roamParam: UnsafeMutablePointer<AUParameterAddress>
    private let roamLow: UnsafeMutablePointer<Double>
    private let roamHigh: UnsafeMutablePointer<Double>

    /// Seconds between firings of each gesture — the app's numbers.
    private static let intervals: [(Double, Double)] = [
        (9, 23),     // drift
        (110, 270),  // voicing
        (150, 330),  // mode
        (95, 240),   // register
        (210, 470),  // timbre
        (130, 290),  // jawari
        (430, 900),  // tuning
    ]
    private let intervalLow: UnsafeMutablePointer<Double>
    private let intervalHigh: UnsafeMutablePointer<Double>

    /// The shortest slide Flow will ever open; anything quicker reads as an event.
    private static let shortestRamp = 9.0
    private static let jawariDepth = 0.45

    init(kernel: ThrumKernel) {
        self.kernel = kernel
        let cols = Self.cols

        modeSemitone = .allocate(capacity: modeCount * cols)
        modeChord = .allocate(capacity: modeCount * cols)
        for (m, mode) in ModeCatalog.all.enumerated() {
            let d = mode.degrees
            for c in 0..<cols {
                let s = d[c % d.count] + 12 * (c / d.count)
                modeSemitone[m * cols + c] = Int16(s)
                modeChord[m * cols + c] = mode.chordSemitones.contains(((s % 12) + 12) % 12)
            }
        }

        let all = DroneVoicing.allCases
        let opening = DroneVoicing.flowOpenings.compactMap { all.firstIndex(of: $0) }
        openingCount = opening.count
        openings = .allocate(capacity: opening.count)
        for (i, o) in opening.enumerated() { openings[i] = Int8(o) }

        let slots = modeCount * all.count
        pickPad = .allocate(capacity: slots * Self.maxPicks)
        pickPad.initialize(repeating: -1, count: slots * Self.maxPicks)
        pickLevel = .allocate(capacity: slots * Self.maxPicks)
        pickLevel.initialize(repeating: 0, count: slots * Self.maxPicks)
        pickCount = .allocate(capacity: slots)
        for m in 0..<modeCount {
            var h = Harmony()
            h.modeIndex = m
            for (vi, v) in all.enumerated() {
                let picks = v.pads(in: h).prefix(Self.maxPicks)
                let slot = m * all.count + vi
                pickCount[slot] = Int8(picks.count)
                for (i, p) in picks.enumerated() {
                    pickPad[slot * Self.maxPicks + i] = Int8(p.pad)
                    pickLevel[slot * Self.maxPicks + i] = p.level
                }
            }
        }

        restfulCount = DroneVoicing.flowModes.count
        restful = .allocate(capacity: restfulCount)
        for (i, m) in DroneVoicing.flowModes.enumerated() { restful[i] = Int8(m) }

        padOn = .allocate(capacity: Self.pads); padOn.initialize(repeating: false, count: Self.pads)
        padLevel = .allocate(capacity: Self.pads); padLevel.initialize(repeating: 0, count: Self.pads)
        padSitarDepth = .allocate(capacity: Self.pads); padSitarDepth.initialize(repeating: 0, count: Self.pads)

        let pc = ThrumParam.allCases.count
        rampFrom = .allocate(capacity: pc); rampFrom.initialize(repeating: 0, count: pc)
        rampTo = .allocate(capacity: pc); rampTo.initialize(repeating: 0, count: pc)
        rampStart = .allocate(capacity: pc); rampStart.initialize(repeating: 0, count: pc)
        rampLength = .allocate(capacity: pc); rampLength.initialize(repeating: 1, count: pc)
        rampLive = .allocate(capacity: pc); rampLive.initialize(repeating: false, count: pc)
        touched = .allocate(capacity: pc); touched.initialize(repeating: false, count: pc)
        heldUntil = .allocate(capacity: pc); heldUntil.initialize(repeating: 0, count: pc)

        roamParam = .allocate(capacity: Self.roam.count)
        roamLow = .allocate(capacity: Self.roam.count)
        roamHigh = .allocate(capacity: Self.roam.count)
        for (i, r) in Self.roam.enumerated() {
            roamParam[i] = r.0.rawValue; roamLow[i] = r.1; roamHigh[i] = r.2
        }
        intervalLow = .allocate(capacity: Self.intervals.count)
        intervalHigh = .allocate(capacity: Self.intervals.count)
        for (i, r) in Self.intervals.enumerated() { intervalLow[i] = r.0; intervalHigh[i] = r.1 }
    }

    deinit {
        modeSemitone.deallocate(); modeChord.deallocate(); openings.deallocate()
        pickPad.deallocate(); pickLevel.deallocate(); pickCount.deallocate(); restful.deallocate()
        padOn.deallocate(); padLevel.deallocate(); padSitarDepth.deallocate()
        rampFrom.deallocate(); rampTo.deallocate(); rampStart.deallocate()
        rampLength.deallocate(); rampLive.deallocate()
        touched.deallocate(); heldUntil.deallocate()
        roamParam.deallocate(); roamLow.deallocate(); roamHigh.deallocate()
        intervalLow.deallocate(); intervalHigh.deallocate()
    }

    // MARK: - Queries (render thread)

    func semitone(mode: Int, pad: Int) -> Int {
        Int(modeSemitone[mode * Self.cols + pad % Self.cols]) + 12 * (pad / Self.cols)
    }

    func padSitar(_ pad: Int) -> Double { padSitarDepth[pad] }

    /// A voice holding one of Flow's pads was taken for a played note.
    func padLost(_ pad: Int) {
        padOn[pad] = false
        padSitarDepth[pad] = 0
    }

    /// The kernel was reset and everything is silent. Swell a fresh voicing back
    /// in a moment later, rather than leaving Flow running with nothing sounding.
    func voicesLost() {
        for p in 0..<Self.pads { padOn[p] = false; padSitarDepth[p] = 0 }
        if running { revoiceAt = clock + 0.5 }
    }

    // MARK: - Ramps

    /// Any thread: the control has been taken over from outside.
    func cancelRamp(_ address: AUParameterAddress) {
        guard Int(address) < paramCount else { return }
        rampLive[Int(address)] = false
        touched[Int(address)] = true
    }

    private func ramp(_ p: AUParameterAddress, to target: Double, over seconds: Double) {
        let i = Int(p)
        rampFrom[i] = kernel.get(p)
        rampTo[i] = target
        rampStart[i] = clock
        rampLength[i] = max(Self.shortestRamp, seconds)
        rampLive[i] = true
    }

    // MARK: - Transport

    private(set) var running = false

    func start() {
        running = true
        clock = 0
        revoiceAt = nil
        // A fresh session: what was touched before Flow started is the starting
        // point, not a claim on the control.
        for i in 0..<paramCount { touched[i] = false; heldUntil[i] = 0 }
        dice = FlowDice(seed: mach_absolute_time() ^ 0x9E37_79B9_7F4A_7C15)
        // Staggered, so Flow doesn't open with every gesture at once.
        due.drift = stagger(0); due.voicing = stagger(1); due.mode = stagger(2)
        due.register = stagger(3); due.timbre = stagger(4); due.jawari = stagger(5)
        due.tuning = stagger(6)
        if !(0..<Self.pads).contains(where: { padOn[$0] }) { apply(voicing: chooseVoicing()) }
    }

    /// Flow's pads fade out at the Fade setting. Every control stays wherever it
    /// had drifted to — as in the app, that is often better than where it began.
    func stop() {
        running = false
        for i in 0..<paramCount { rampLive[i] = false }
        for p in 0..<Self.pads where padOn[p] {
            padOn[p] = false
            padSitarDepth[p] = 0
            kernel.flowRelease(pad: p)
        }
        voicing = -1
    }

    private func stagger(_ g: Int) -> Double {
        dice.range(intervalLow[g] * 0.15, intervalLow[g] * 0.6)
    }

    private func next(_ g: Int) -> Double {
        clock + dice.range(intervalLow[g], intervalHigh[g])
    }

    // MARK: - Tick

    func advance(by dt: Double) {
        guard running else { return }
        clock += dt

        for i in 0..<paramCount where touched[i] {
            touched[i] = false
            heldUntil[i] = clock + Self.handHold
        }

        for i in 0..<paramCount where rampLive[i] {
            let x = min(1, max(0, (clock - rampStart[i]) / rampLength[i]))
            let e = x * x * x * (x * (x * 6 - 15) + 10)
            kernel.store(AUParameterAddress(i), rampFrom[i] + (rampTo[i] - rampFrom[i]) * e)
            if x >= 1 { rampLive[i] = false }
        }

        if let at = revoiceAt, clock >= at {
            revoiceAt = nil
            apply(voicing: chooseVoicing())
        }

        if clock >= due.drift { due.drift = next(0); drift() }
        if clock >= due.voicing { due.voicing = next(1); moveVoicing() }
        if clock >= due.mode { due.mode = next(2); moveMode() }
        if clock >= due.register { due.register = next(3); moveRegister() }
        if clock >= due.timbre { due.timbre = next(4); moveTimbre() }
        if clock >= due.jawari { due.jawari = next(5); toggleJawari() }
        if clock >= due.tuning { due.tuning = next(6); moveTuning() }
    }

    // MARK: - Gestures

    private func held(_ p: ThrumParam) -> Bool { clock < heldUntil[Int(p.rawValue)] }

    /// Two to four controls at a time, each on its own slow slide, so there are
    /// always several overlapping and none of them is the event.
    private func drift() {
        for _ in 0..<(2 + dice.int(3)) {
            let r = dice.int(roamCount)
            guard clock >= heldUntil[Int(roamParam[r])] else { continue }
            ramp(roamParam[r], to: dice.range(roamLow[r], roamHigh[r]), over: dice.range(20, 90))
        }
    }

    /// A quarter of the time, add a quiet chord tone; otherwise a new voicing.
    private func moveVoicing() {
        if dice.chance(0.25), let pad = quietPad() {
            sound(pad, level: dice.range(0.25, 0.55))
        } else {
            apply(voicing: chooseVoicing())
        }
    }

    private func chooseVoicing() -> Int {
        var pick = Int(openings[dice.int(openingCount)])
        // Always somewhere new, so the gesture can never quietly do nothing.
        if pick == voicing, openingCount > 1 {
            pick = Int(openings[(dice.int(openingCount - 1) + 1 + indexOfOpening(voicing)) % openingCount])
        }
        return pick
    }

    private func indexOfOpening(_ v: Int) -> Int {
        for i in 0..<openingCount where Int(openings[i]) == v { return i }
        return 0
    }

    /// Let go of what this voicing doesn't use, swell in what it does. The pads
    /// it shares with what was sounding simply carry on, at their new level.
    private func apply(voicing v: Int) {
        let slot = kernel.mode * voicingCount + v
        let n = Int(pickCount[slot])
        for p in 0..<Self.pads where padOn[p] {
            var kept = false
            for i in 0..<n where Int(pickPad[slot * Self.maxPicks + i]) == p { kept = true }
            if !kept { release(p) }
        }
        for i in 0..<n {
            sound(Int(pickPad[slot * Self.maxPicks + i]), level: pickLevel[slot * Self.maxPicks + i])
        }
        voicing = v
    }

    private func moveMode() {
        guard !held(.mode) else { return }
        let current = kernel.mode
        var m = Int(restful[dice.int(restfulCount)])
        var tries = 0
        while m == current && tries < 8 { m = Int(restful[dice.int(restfulCount)]); tries += 1 }
        kernel.store(ThrumParam.mode.rawValue, Double(m))
    }

    /// Where the drone sits without moving what it is: one degree let go in one
    /// octave and swelled in another. A crossfade, never a glide.
    private func moveRegister() {
        guard let from = soundingPad() else { return }
        let col = from % Self.cols
        let row = from / Self.cols
        var to = dice.int(Self.rows - 1)
        if to >= row { to += 1 }
        let target = to * Self.cols + col
        guard !padOn[target] else { return }
        let level = padLevel[from]
        release(from)
        sound(target, level: min(0.85, max(0.22, level)))
    }

    private func moveTimbre() {
        guard !held(.timbre) else { return }
        let current = Int(kernel.value(.timbre).rounded())
        let t = (current + 1 + dice.int(timbreCount - 1)) % timbreCount
        kernel.store(ThrumParam.timbre.rawValue, Double(t))
    }

    private func toggleJawari() {
        guard let pad = soundingPad() else { return }
        padSitarDepth[pad] = padSitarDepth[pad] < 0.01 ? Self.jawariDepth : 0
        kernel.flowSitarChanged(pad: pad)
    }

    private func moveTuning() {
        guard !held(.tuning) else { return }
        let current = Int(kernel.value(.tuning).rounded())
        let t = (current + 1 + dice.int(tuningCount - 1)) % tuningCount
        kernel.store(ThrumParam.tuning.rawValue, Double(t))
    }

    // MARK: - Pads

    private func sound(_ pad: Int, level: Double) {
        guard pad >= 0, pad < Self.pads else { return }
        padOn[pad] = true
        padLevel[pad] = level
        kernel.flowSound(pad: pad, level: level)
    }

    private func release(_ pad: Int) {
        padOn[pad] = false
        padSitarDepth[pad] = 0
        kernel.flowRelease(pad: pad)
    }

    private func soundingPad() -> Int? {
        var count = 0
        for p in 0..<Self.pads where padOn[p] { count += 1 }
        guard count > 0 else { return nil }
        var k = dice.int(count)
        for p in 0..<Self.pads where padOn[p] {
            if k == 0 { return p }
            k -= 1
        }
        return nil
    }

    private func quietPad() -> Int? {
        let m = kernel.mode
        var count = 0
        for p in 0..<Self.pads where !padOn[p] && modeChord[m * Self.cols + p % Self.cols] { count += 1 }
        guard count > 0 else { return nil }
        var k = dice.int(count)
        for p in 0..<Self.pads where !padOn[p] && modeChord[m * Self.cols + p % Self.cols] {
            if k == 0 { return p }
            k -= 1
        }
        return nil
    }
}

/// The app's xorshift, again: Flow's wandering is its own and doesn't depend
/// on the system generator, and it allocates nothing.
struct FlowDice {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func nextBits() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> Double { Double(nextBits() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : min(n - 1, Int(unit() * Double(n))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}
