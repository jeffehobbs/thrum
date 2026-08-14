import Foundation

// Offline checks for Flow. Flow's whole promise is "nothing ever jumps", and that
// is a property you can measure rather than listen for — so this drives the
// director through hours of compressed time and watches every control.
//
//   swiftc -O -o /tmp/thrumflow Shared/*.swift \
//     Tools/spatial/ablholder.swift Tools/flow/main.swift
//   /tmp/thrumflow

var fails = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { fails += 1 }
}

@MainActor
func runFlowChecks() {
    let step = 0.1

    struct Run {
        var maxJump: [Param: Double] = [:]      // largest one-tick move, as a fraction of range
        var moved: Int = 0                      // ticks where at least one control moved
        var ticks: Int = 0
        var finals: [Param: Double] = [:]
        var minSeen: [Param: Double] = [:]
        var maxSeen: [Param: Double] = [:]
    }

    func fly(hours: Double) -> Run {
        let engine = DroneEngine()
        engine.setSampleRate(48000)
        let model = ThrumModel(engine: engine)
        let volumeAtStart = model.value(.masterVolume)
        var keyMoved = false
        var run = Run()

        var previous: [Param: Double] = [:]
        for p in Param.allCases { previous[p] = model.value(p) }

        model.flow.start()
        // Read after `start()`, not before: on the phone Flow chooses the key as it
        // starts, and what this run is checking is that the key never moves *while
        // it plays*. Those are different claims and only the second one is a
        // promise — see `picksKeyOnStart`.
        let keyAtStart = model.harmony.keyPitchClass
        let octaveAtStart = model.harmony.rootOctave
        let total = Int(hours * 3600 / step)
        for _ in 0..<total {
            model.flow.advance(by: step)
            var anyMoved = false
            for p in Param.allCases {
                let v = model.value(p)
                let range = ThrumModel.spec(p).range
                let span = max(1e-9, range.upperBound - range.lowerBound)
                let jump = abs(v - (previous[p] ?? v)) / span
                if jump > 1e-12 { anyMoved = true }
                run.maxJump[p] = max(run.maxJump[p] ?? 0, jump)
                run.minSeen[p] = min(run.minSeen[p] ?? v, v)
                run.maxSeen[p] = max(run.maxSeen[p] ?? v, v)
                previous[p] = v
            }
            if anyMoved { run.moved += 1 }
            if model.harmony.keyPitchClass != keyAtStart
                || model.harmony.rootOctave != octaveAtStart { keyMoved = true }
            run.ticks += 1
        }
        for p in Param.allCases { run.finals[p] = model.value(p) }
        check(model.value(.masterVolume) == volumeAtStart,
              "Output is never touched", "started \(volumeAtStart), ended \(model.value(.masterVolume))")
        // Moving the key glides every sounding pitch at once by a fourth or a
        // fifth; moving the register does it by an octave. Both were tried, both
        // got the slow glide and the breath, and neither was enough — under a
        // director it still reads as an event nobody asked for. Flow stays put.
        check(!keyMoved, "the key and the register never move",
              "key \(keyAtStart) → \(model.harmony.keyPitchClass), octave \(octaveAtStart) → \(model.harmony.rootOctave)")
        model.flow.stop()
        return run
    }

    print("\n— three hours of drifting —")
    let a = fly(hours: 3)

    // The headline promise. A ramp of at least 20 s at 0.1 s ticks moves under 1% of
    // a control's travel per tick even at its steepest, so anything above a few
    // percent means something is being *set* somewhere instead of slid.
    let worst = a.maxJump.max { $0.value < $1.value }
    check((worst?.value ?? 0) < 0.03, "no control ever jumps",
          String(format: "worst was %@ at %.2f%% of its travel in one tick",
                 worst.map { ThrumModel.spec($0.key).name } ?? "-", (worst?.value ?? 0) * 100))

    // "Something is always shifting" is the point of the mode, not a nicety.
    let busy = Double(a.moved) / Double(max(1, a.ticks))
    check(busy > 0.95, "something is moving essentially always",
          String(format: "%.1f%% of ticks", busy * 100))

    // The anti-fatigue guard has to hold for the one mode that runs unattended.
    check((a.minSeen[.presence] ?? 1) >= 0.449, "Presence Cut never drops below its floor",
          String(format: "%.3f", a.minSeen[.presence] ?? 0))

    // Nothing may leave its declared range.
    var escaped: [String] = []
    for p in Param.allCases {
        let r = ThrumModel.spec(p).range
        if let lo = a.minSeen[p], lo < r.lowerBound - 1e-9 { escaped.append("\(ThrumModel.spec(p).name) low") }
        if let hi = a.maxSeen[p], hi > r.upperBound + 1e-9 { escaped.append("\(ThrumModel.spec(p).name) high") }
    }
    check(escaped.isEmpty, "no control leaves its legal range", escaped.joined(separator: ", "))

    // Stillness is death: these three are what keep the drone alive.
    for p in [Param.beating, .drift, .motion] {
        check((a.minSeen[p] ?? 0) > 0.2, "\(ThrumModel.spec(p).name) never goes dead",
              String(format: "min %.2f", a.minSeen[p] ?? 0))
    }

    print("\n— how long a pitch change takes to arrive —")

    // The user-visible complaint that produced `glideSeconds`: in Flow, a key
    // change is nobody's decision, so a 700-cent sweep in half a second reads as
    // a lurch. Measured here by tracking the actual pitch, not by trusting that
    // the setting is wired up.
    func glideTime(_ seconds: Double) -> Double {
        let e = DroneEngine()
        e.setSampleRate(48000)
        e.reverbMix = 0
        e.brightness = 0          // near-sinusoidal, so zero crossings mean pitch
        e.beating = 0; e.drift = 0; e.motion = 0
        e.swellSeconds = 0.2
        e.glideSeconds = seconds
        e.retune(pad: 0, frequency: 220)
        e.setLevel(pad: 0, level: 0.9)
        e.gate(pad: 0, on: true)

        let block = 2048
        let abl = AudioBufferListHolder(block)
        // Settle the swell at the old pitch.
        for _ in 0..<40 { e.render(frameCount: block, out: abl.ptr) }

        e.retune(pad: 0, frequency: 330)      // up a fifth
        var elapsed = 0.0
        for _ in 0..<2400 {                   // up to ~100 s
            e.render(frameCount: block, out: abl.ptr)
            elapsed += Double(block) / 48000
            var crossings = 0
            for i in 1..<block where (abl.l[i - 1] < 0) != (abl.l[i] < 0) { crossings += 1 }
            let hz = Double(crossings) / 2 / (Double(block) / 48000)
            if hz >= 327 { return elapsed }   // within 1% of the fifth
        }
        return .infinity
    }

    let byHand = glideTime(FlowDirector.handGlide)
    let inFlow = glideTime(FlowDirector.flowGlide)
    print(String(format: "       by hand (%.2f s setting): arrives in %.1f s", FlowDirector.handGlide, byHand))
    print(String(format: "       in Flow (%.2f s setting): arrives in %.1f s", FlowDirector.flowGlide, inFlow))
    check(byHand < 4, "a hand-made change still arrives promptly",
          String(format: "%.1f s", byHand))
    check(inFlow > byHand * 4, "in Flow a pitch change is a modulation, not a sweep",
          String(format: "%.1f s vs %.1f s", inFlow, byHand))

    print("\n— it should be a different journey every time —")
    let b = fly(hours: 3)
    let differing = Param.allCases.filter { abs((a.finals[$0] ?? 0) - (b.finals[$0] ?? 0)) > 1e-6 }.count
    check(differing >= 8, "two runs end up somewhere different",
          "\(differing) of \(Param.allCases.count) controls differ")

    print("\n— a different key every time it is started (the phone's mode) —")

    // The bug this answers: `Harmony` defaults to D Dorian, the phone has no grid
    // to change it from, and Flow never moves the key once running — so every
    // session ThrumFlow had ever played was a modal variant of D. Checked by
    // starting and stopping many times rather than by reading the code, because
    // "picks a key" and "picks a key that isn't the one it just had" differ by one
    // `filter` and only the second is worth having.
    var keys: [Int] = []
    var repeats = 0
    do {
        let engine = DroneEngine()
        engine.setSampleRate(48000)
        let model = ThrumModel(engine: engine)
        model.flow.picksKeyOnStart = true
        for _ in 0..<60 {
            let before = model.harmony.keyPitchClass
            model.flow.start()
            let now = model.harmony.keyPitchClass
            if now == before { repeats += 1 }
            keys.append(now)
            // A few minutes of playing, so the key is also checked to sit still
            // through a whole session's worth of gestures rather than just at t=0.
            let sessionKey = now
            for _ in 0..<3000 { model.flow.advance(by: step) }
            if model.harmony.keyPitchClass != sessionKey { repeats += 1000 }
            model.flow.stop()
        }
    }
    check(repeats == 0, "no session opens in the key the last one was in",
          "\(repeats) repeats in \(keys.count) starts")
    check(Set(keys).count >= 9, "the keys spread across the circle",
          "\(Set(keys).count) distinct of 12 in \(keys.count) starts")

    // And the same across a cold launch, which on a phone is the common case: a
    // fresh model knows nothing, so without the stored key this would be a 1-in-11
    // chance of opening exactly where the last listen left off.
    var coldRepeats = 0
    for _ in 0..<40 {
        let last = keys.last!
        let engine = DroneEngine()
        engine.setSampleRate(48000)
        let model = ThrumModel(engine: engine)      // as if the app had just launched
        model.flow.picksKeyOnStart = true
        model.flow.start()
        if model.harmony.keyPitchClass == last { coldRepeats += 1 }
        keys.append(model.harmony.keyPitchClass)
        model.flow.stop()
    }
    check(coldRepeats == 0, "nor after a relaunch", "\(coldRepeats) repeats in 40 cold starts")

    // And the Mac's: the player's key is the player's.
    do {
        let engine = DroneEngine()
        engine.setSampleRate(48000)
        let model = ThrumModel(engine: engine)
        model.setKey(7)
        model.flow.start()
        for _ in 0..<600 { model.flow.advance(by: step) }
        check(model.harmony.keyPitchClass == 7, "left off, Flow honours the key it was handed",
              "asked for 7, got \(model.harmony.keyPitchClass)")
        model.flow.stop()
    }

    print("\n— does the field actually move —")

    // The iOS bug this measures: `field` only reaches the audio graph through
    // `onFieldChange`, the phone's host never wired it, and so sixteen bus
    // positions stayed at their defaults for the app's whole life while Flow
    // happily ramped Radius and Lift into a void. Nothing offline can test a host
    // callback, but this pins down what the host was throwing away — if the
    // geometry barely moves, wiring it up buys nothing and the subtlety is
    // elsewhere.
    do {
        let engine = DroneEngine()
        engine.setSampleRate(48000)
        let model = ThrumModel(engine: engine)
        model.spatialEnabled = true           // the Field gesture is gated on it
        var updates = 0
        var radii: [Double] = []
        var lifts: [Double] = []
        model.onFieldChange = {
            updates += 1
            radii.append(model.field.radius)
            lifts.append(model.field.lift)
        }
        model.flow.start()
        for _ in 0..<Int(1 * 3600 / step) { model.flow.advance(by: step) }
        model.flow.stop()

        let rSpan = (radii.max() ?? 0) - (radii.min() ?? 0)
        let lSpan = (lifts.max() ?? 0) - (lifts.min() ?? 0)
        print(String(format: "       %d geometry updates in an hour, radius %.2f–%.2f m, lift %.0f–%.0f°",
                     updates, radii.min() ?? 0, radii.max() ?? 0, lifts.min() ?? 0, lifts.max() ?? 0))
        check(updates > 500, "the field is re-placed continuously, not once", "\(updates) updates")
        check(rSpan > 0.8, "the ring travels far enough to hear",
              String(format: "%.2f m of travel", rSpan))
        check(lSpan > 8, "the octave tiers open and close",
              String(format: "%.0f° of travel", lSpan))
    }

    print("\n— range actually explored —")
    for p in [Param.brightness, .reverbMix, .tempo, .warmth] {
        let spec = ThrumModel.spec(p)
        print(String(format: "       %-14@ %@ … %@", spec.name as NSString,
                     spec.display(a.minSeen[p] ?? 0) as NSString,
                     spec.display(a.maxSeen[p] ?? 0) as NSString))
    }

    print(fails == 0 ? "\nAll checks passed.\n" : "\n\(fails) FAILED\n")
    exit(fails == 0 ? 0 : 1)
}

// A CLI's top level is not actor-isolated, but it is genuinely the main thread.
MainActor.assumeIsolated { runFlowChecks() }
