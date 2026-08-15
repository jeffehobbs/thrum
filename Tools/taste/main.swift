import Foundation

// Offline checks for Taste — the thumbs, and what they do to Flow.
//
// A preference system is unusually easy to get wrong in a way nobody notices. The
// failure mode is not a crash, it is an app that claims to be learning and either
// isn't, or is over-learning so hard that it plays one drone forever. Both sound
// plausible from the sofa and neither is visible in the code. So these checks
// teach a simulated listener's taste to a real `Taste`, run real Flow against it,
// and count what comes out.
//
//   swiftc -O -o /tmp/thrumtaste Shared/*.swift \
//     Tools/spatial/ablholder.swift Tools/taste/main.swift
//   /tmp/thrumtaste

var fails = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { fails += 1 }
}

/// A clock we own, so a 150-day half-life can be measured in a millisecond.
final class Dial {
    var t: Double = 1_000_000_000
    func advance(days: Double) { t += days * 86_400 }
}

@MainActor
func newModel(_ taste: Taste) -> ThrumModel {
    let engine = DroneEngine()
    engine.setSampleRate(48000)
    let model = ThrumModel(engine: engine, taste: taste)
    model.flow.picksKeyOnStart = true
    return model
}

/// Run Flow for a stretch of compressed time and tally what it chose.
@MainActor
func fly(_ taste: Taste, hours: Double, sessions: Int = 1)
    -> (modes: [Int: Int], timbres: [Int: Int], voicings: [String: Int], keys: [Int: Int],
        seen: [Param: (low: Double, high: Double)]) {
    var modes: [Int: Int] = [:]
    var timbres: [Int: Int] = [:]
    var voicings: [String: Int] = [:]
    var keys: [Int: Int] = [:]
    var seen: [Param: (low: Double, high: Double)] = [:]

    for _ in 0..<sessions {
        let model = newModel(taste)
        model.flow.start()
        keys[model.harmony.keyPitchClass, default: 0] += 1
        var lastMode = -1
        var lastTimbre = -1
        var lastVoicing = ""
        for _ in 0..<Int(hours * 3600 / 0.1) {
            model.flow.advance(by: 0.1)
            if model.harmony.modeIndex != lastMode {
                lastMode = model.harmony.modeIndex
                modes[lastMode, default: 0] += 1
            }
            if model.timbreIndex != lastTimbre {
                lastTimbre = model.timbreIndex
                timbres[lastTimbre, default: 0] += 1
            }
            if let v = model.voicing, v.rawValue != lastVoicing {
                lastVoicing = v.rawValue
                voicings[lastVoicing, default: 0] += 1
            }
            for p in [Param.brightness, .reverbMix, .warmth, .motion] {
                let v = model.value(p)
                let bounds = seen[p] ?? (v, v)
                seen[p] = (min(bounds.low, v), max(bounds.high, v))
            }
        }
        model.flow.stop()
    }
    return (modes, timbres, voicings, keys, seen)
}

/// Cast a vote as if the listener had reacted to a drone with these qualities.
/// Built by hand rather than through Flow, so a check can teach one specific
/// opinion without waiting for Flow to happen to produce it.
func opinion(mode: Int? = nil, timbre: Int? = nil, voicing: Int? = nil, key: Int? = nil,
             tuning: Int? = nil, params: [Param: Double] = [:]) -> Taste.Snapshot {
    var s = Taste.Snapshot()
    func note(_ kind: Taste.TraitKind, _ value: Int?) {
        guard let value else { return }
        s.traits[kind] = Taste.Snapshot.Trait(value: value, credit: 1)
    }
    note(.mode, mode)
    note(.timbre, timbre)
    note(.voicing, voicing)
    note(.key, key)
    note(.tuning, tuning)
    s.params = params
    return s
}

@MainActor
func runTasteChecks() {
    let dial = Dial()

    // ---------------------------------------------------------------- untaught

    print("\n— an untaught Taste is a no-op —")
    do {
        let blank = Taste(now: { dial.t })
        check(blank.isEmpty, "starts with no opinions")
        for kind in Taste.TraitKind.allCases {
            check(blank.weight(kind, 0) == 1, "\(kind.rawValue) weight is exactly 1",
                  String(format: "%.6f", blank.weight(kind, 0)))
        }
        // The important one. Flow's roam bands are the ranges that stay pleasant
        // for an hour; if this returned anything but them, installing this feature
        // would change the music before a single button had been pressed.
        var identical = true
        for p in Param.allCases {
            let roam = (low: ThrumModel.spec(p).range.lowerBound,
                        high: ThrumModel.spec(p).range.upperBound)
            let out = blank.band(p, within: roam)
            if out.low != roam.low || out.high != roam.high { identical = false }
        }
        check(identical, "every roam band comes back untouched")
        check(blank.summary.isEmpty, "claims to have learned nothing")
    }

    // ------------------------------------------------------- discrete learning

    print("\n— what fifty votes do to the odds —")
    let taught = Taste(now: { dial.t })
    do {
        // A listener who loves Lydian (3) and Melodic Minor (11) on Glass Choir's
        // opposite — Shruti Box (2) — and cannot stand Bagpipe Drone (4).
        for _ in 0..<12 {
            taught.record(.up, opinion(mode: 3, timbre: 2, voicing: 13))
            taught.record(.up, opinion(mode: 11, timbre: 2, voicing: 13))
            taught.record(.down, opinion(mode: 5, timbre: 4, voicing: 1))
        }
        check(taught.score(.mode, 3) > 0.5, "a repeatedly liked mode scores high",
              String(format: "%.2f", taught.score(.mode, 3)))
        check(taught.score(.timbre, 4) < -0.5, "a repeatedly disliked timbre scores low",
              String(format: "%.2f", taught.score(.timbre, 4)))
        check(taught.score(.mode, 0) == 0, "an unheard mode stays neutral")

        // Nothing is ever ruled out. This is the property that keeps the
        // instrument an instrument: a floored weight is still a weight.
        let worst = Taste.TraitKind.allCases.flatMap { kind in
            (0..<8).map { taught.weight(kind, $0) }
        }.min() ?? 0
        check(worst > 0.15, "no weight ever reaches zero",
              String(format: "lowest was %.3f", worst))

        check(taught.summary.contains("Lydian"), "the summary names what is liked",
              "\"\(taught.summary)\"")
        check(taught.summary.contains("Bagpipe"), "and what is not",
              "\"\(taught.summary)\"")
    }

    // ------------------------------------------------------- Flow acts on them

    print("\n— Flow acts on them, without becoming a loop —")
    do {
        let blank = Taste(now: { dial.t })
        let before = fly(blank, hours: 6, sessions: 3)
        let after = fly(taught, hours: 6, sessions: 3)

        func share(_ counts: [Int: Int], _ value: Int) -> Double {
            let total = counts.values.reduce(0, +)
            return total == 0 ? 0 : Double(counts[value] ?? 0) / Double(total)
        }

        let likedBefore = share(before.modes, 3)
        let likedAfter = share(after.modes, 3)
        check(likedAfter > likedBefore * 1.25,
              "the liked mode turns up materially more often",
              String(format: "%.1f%% → %.1f%%", likedBefore * 100, likedAfter * 100))

        let hatedBefore = share(before.timbres, 4)
        let hatedAfter = share(after.timbres, 4)
        check(hatedAfter < hatedBefore * 0.75,
              "the disliked timbre turns up materially less often",
              String(format: "%.1f%% → %.1f%%", hatedBefore * 100, hatedAfter * 100))

        // The counterweight, and the check most worth having: a preference engine
        // that is working *too* well is a broken instrument. Six hours of Flow
        // must still visit most of the catalogue.
        check(after.modes.count >= 6, "Flow still visits most of the modes",
              "\(after.modes.count) of \(Self_restfulModeCount) restful modes")
        check(after.timbres.keys.contains(4), "including the disliked one, sometimes",
              "\(after.timbres[4] ?? 0) visits in 18 hours")
        check(after.voicings.count >= 8, "and most of the voicings",
              "\(after.voicings.count) distinct")
    }

    // --------------------------------------------------------- continuous bands

    print("\n— a control learns where to sit, and keeps moving —")
    do {
        let dim = Taste(now: { dial.t })
        // A listener who consistently likes a dark drone: Brightness low.
        for i in 0..<30 {
            let jitter = Double(i % 5) * 0.01
            dim.record(.up, opinion(params: [.brightness: 0.18 + jitter]))
            dim.record(.down, opinion(params: [.brightness: 0.78 + jitter]))
        }
        let roam = (low: 0.32, high: 0.72)          // Flow's own band for Brightness
        let band = dim.band(.brightness, within: roam)
        check(band.low >= roam.low - 1e-9 && band.high <= roam.high + 1e-9,
              "the learned band stays inside Flow's pleasant range",
              String(format: "%.3f…%.3f inside %.2f…%.2f", band.low, band.high, roam.low, roam.high))
        check(band.high < roam.high - 0.05, "and has pulled away from the disliked end",
              String(format: "top %.3f vs %.2f", band.high, roam.high))
        let width = band.high - band.low
        let floorWidth = (roam.high - roam.low) * 0.34
        check(width > floorWidth, "but never collapses to a point",
              String(format: "%.3f wide, floor %.3f", width, floorWidth))

        // Down votes alone: no idea where to go, but a clear idea where not to be.
        let avoid = Taste(now: { dial.t })
        for _ in 0..<20 { avoid.record(.down, opinion(params: [.warmth: 0.95])) }
        let warm = avoid.band(.warmth, within: (low: 0.40, high: 0.72))
        check(warm.high < 0.72 - 1e-6, "down votes alone still steer away",
              String(format: "top %.3f vs 0.72", warm.high))

        // And the whole point of the exploration term: with the band narrowed,
        // Flow must still occasionally go outside it, or the evidence stops coming.
        let travelled = fly(dim, hours: 8).seen[.brightness]!
        check(travelled.high > band.high + 0.02,
              "Flow still wanders outside the learned band sometimes",
              String(format: "reached %.3f, band tops at %.3f", travelled.high, band.high))
        check(travelled.low < band.low + 0.05 || travelled.high - travelled.low > width,
              "and the control is still genuinely moving",
              String(format: "%.3f…%.3f", travelled.low, travelled.high))
    }

    // ------------------------------------------------------------ what a vote does

    print("\n— a vote has an audible consequence —")
    do {
        // **Thumbs-up must not touch the sound.** It is filed and nothing else — so
        // the strongest available check is that a rated run and an unrated one are
        // *statistically identical*, not merely similar. An earlier version pushed
        // the disruptive gestures out to make a praised drone last longer, and this
        // is the check that would now catch that coming back.
        let settled = Taste(now: { dial.t })
        func upheavals(rating: Bool, trials: Int) -> Double {
            var total = 0
            for _ in 0..<trials {
                let model = newModel(settled)
                model.flow.start()
                for _ in 0..<900 { model.flow.advance(by: 0.1) }        // 90 s in
                if rating { model.flow.rate(.up) }
                var mode = model.harmony.modeIndex
                var timbre = model.timbreIndex
                var voicing = model.voicing
                for _ in 0..<6000 { // ten minutes
                    model.flow.advance(by: 0.1)
                    if model.harmony.modeIndex != mode { mode = model.harmony.modeIndex; total += 1 }
                    if model.timbreIndex != timbre { timbre = model.timbreIndex; total += 1 }
                    if model.voicing != voicing { voicing = model.voicing; total += 1 }
                }
                model.flow.stop()
            }
            return Double(total) / Double(trials)
        }
        let unrated = upheavals(rating: false, trials: 30)
        let rated = upheavals(rating: true, trials: 30)
        check(abs(rated - unrated) < 1.0,
              "thumbs-up changes nothing about the sound",
              String(format: "%.2f changes in the next ten minutes vs %.2f unrated", rated, unrated))

        // Thumbs-down brings the next planned change forward. Two things have to be
        // true and they pull against each other: it must *always* produce an audible
        // change (a button that sometimes does nothing is worse than no button), and
        // it must do it through Flow's ordinary machinery — so the key and register
        // stay put, exactly as they do when nobody is pressing anything.
        // Includes which pads are sounding, not just the four named qualities. The
        // voicing gesture sometimes swells one extra colour tone in rather than
        // rebuilding the stack — a smaller change, but an audible one, and a check
        // that ignored it would report a thumbs-down as having done nothing.
        func character(_ m: ThrumModel) -> String {
            let pads = m.padOn.map { $0 ? "1" : "0" }.joined()
            return "\(m.harmony.modeIndex)/\(m.timbreIndex)/\(m.voicing?.rawValue ?? "-")/\(m.harmony.tuning.rawValue)/\(pads)"
        }
        var moved = 0
        var keyMoved = false
        var soonest = 0
        for _ in 0..<40 {
            let model = newModel(taught)
            model.flow.start()
            for _ in 0..<900 { model.flow.advance(by: 0.1) }
            let key = model.harmony.keyPitchClass
            let octave = model.harmony.rootOctave
            let before = character(model)
            model.flow.rate(.down)
            // A timbre swap hides under a nine-and-a-half-second breath before it
            // lands, so the window has to be longer than that or this measures the
            // breath rather than the change.
            var when = -1
            for step in 0..<300 {                                // 30 s
                model.flow.advance(by: 0.1)
                if when < 0, character(model) != before { when = step }
            }
            if when >= 0 { moved += 1; soonest += when }
            if model.harmony.keyPitchClass != key || model.harmony.rootOctave != octave {
                keyMoved = true
            }
            model.flow.stop()
        }
        check(moved == 40, "thumbs-down always changes the drone's character",
              "\(moved)/40, on average after \(moved > 0 ? String(format: "%.1f s", Double(soonest) / Double(moved) * 0.1) : "—")")
        check(!keyMoved, "and never the key or the register, even when asked")

        // The change it hastens is one Flow had already planned, so pressing it
        // repeatedly must not stack up a queue of changes landing on top of each
        // other — the drone should not fall apart under an impatient listener.
        let model = newModel(taught)
        model.flow.start()
        for _ in 0..<900 { model.flow.advance(by: 0.1) }
        var churn = 0
        var last = character(model)
        for burst in 0..<10 {
            model.flow.rate(.down)
            for _ in 0..<50 { model.flow.advance(by: 0.1) }      // 5 s between presses
            if character(model) != last { churn += 1; last = character(model) }
            _ = burst
        }
        for _ in 0..<600 { model.flow.advance(by: 0.1) }
        if character(model) != last { churn += 1 }
        check(churn <= 11, "ten impatient presses do not stack up a queue of changes",
              "\(churn) character changes across the burst")
        model.flow.stop()
    }

    // ------------------------------------------------------------------- pause

    print("\n— pausing holds the journey rather than ending it —")
    do {
        let blank = Taste(now: { dial.t })
        let model = newModel(blank)
        model.flow.start()
        for _ in 0..<3000 { model.flow.advance(by: 0.1) }        // five minutes in

        let key = model.harmony.keyPitchClass
        let mode = model.harmony.modeIndex
        let voicing = model.voicing
        let held = Param.allCases.map { model.value($0) }

        model.flow.pause()
        check(model.flow.isPaused && model.flow.isRunning,
              "paused is a state of a running session, not a stopped one")

        // The whole point: wall-clock time passing while nothing is audible is not
        // time the instrument has lived through. A drone paused for a phone call
        // must not come back to where it *would* have drifted to.
        for _ in 0..<6000 { model.flow.advance(by: 0.1) }        // ten minutes of "silence"
        let stillThere = Param.allCases.map { model.value($0) }
        check(zip(held, stillThere).allSatisfy { $0 == $1 },
              "nothing drifts while paused")
        check(model.harmony.keyPitchClass == key && model.harmony.modeIndex == mode
              && model.voicing == voicing,
              "and the drone is the same one when it comes back")

        model.flow.resume()
        check(!model.flow.isPaused, "resuming clears the hold")
        var moved = false
        for _ in 0..<600 { model.flow.advance(by: 0.1) }
        for (i, p) in Param.allCases.enumerated() where model.value(p) != stillThere[i] { moved = true }
        check(moved, "and it picks the ramps back up rather than sitting still")

        // Resuming is not restarting: `start()` reseeds and re-chooses a key, which
        // is exactly what a listener pressing play after a pause must not get.
        check(model.harmony.keyPitchClass == key,
              "resuming keeps the session's key — it is not a fresh start",
              "\(key) → \(model.harmony.keyPitchClass)")
        model.flow.stop()
    }

    // ------------------------------------------------------------------- decay

    print("\n— old opinions fade —")
    do {
        let fading = Taste(now: { dial.t })
        for _ in 0..<15 { fading.record(.up, opinion(mode: 3)) }
        let fresh = fading.score(.mode, 3)
        dial.advance(days: 150)
        let halved = fading.score(.mode, 3)
        dial.advance(days: 600)
        let faint = fading.score(.mode, 3)
        check(halved < fresh * 0.92, "a 150-day-old opinion counts for less",
              String(format: "%.3f → %.3f", fresh, halved))
        check(faint < halved * 0.7, "and keeps fading",
              String(format: "%.3f after two more years", faint))
        check(faint > 0, "without ever flipping sign", String(format: "%.4f", faint))

        // Recent evidence must be able to overturn old evidence, or the first week
        // of use decides the rest of the app's life.
        for _ in 0..<6 { fading.record(.down, opinion(mode: 3)) }
        check(fading.score(.mode, 3) < 0, "six recent down votes beat fifteen old up votes",
              String(format: "%.3f", fading.score(.mode, 3)))
    }

    // -------------------------------------------------------------- persistence

    print("\n— the database survives a relaunch —")
    do {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("thrum-taste-check-\(ProcessInfo.processInfo.processIdentifier).json")
        try? FileManager.default.removeItem(at: file)

        let first = Taste(store: file, now: { dial.t })
        for _ in 0..<8 {
            first.record(.up, opinion(mode: 4, timbre: 6, params: [.reverbMix: 0.55]))
            first.record(.down, opinion(mode: 6, timbre: 1, params: [.reverbMix: 0.12]))
        }
        let wanted = first.score(.mode, 4)
        let wantedBand = first.band(.reverbMix, within: (low: 0.28, high: 0.60))

        // The write is asynchronous by design — a vote must never wait on the disk.
        var waited = 0.0
        while !FileManager.default.fileExists(atPath: file.path), waited < 3 {
            usleep(50_000)
            waited += 0.05
        }
        check(FileManager.default.fileExists(atPath: file.path), "it wrote a file",
              file.lastPathComponent)

        let second = Taste(store: file, now: { dial.t })
        check(abs(second.score(.mode, 4) - wanted) < 1e-9, "discrete scores round-trip",
              String(format: "%.4f vs %.4f", second.score(.mode, 4), wanted))
        let reread = second.band(.reverbMix, within: (low: 0.28, high: 0.60))
        check(abs(reread.low - wantedBand.low) < 1e-9 && abs(reread.high - wantedBand.high) < 1e-9,
              "and so do the learned bands",
              String(format: "%.4f…%.4f", reread.low, reread.high))
        check(second.ups == 8 && second.downs == 8, "and the tally",
              "\(second.ups) up, \(second.downs) down")

        second.forget()
        let third = Taste(store: file, now: { dial.t })
        // Forget writes asynchronously too.
        var settled = 0.0
        while third.ups != 0, settled < 3 { usleep(50_000); settled += 0.05 }
        check(Taste(store: file, now: { dial.t }).isEmpty, "and forgetting really forgets")
        try? FileManager.default.removeItem(at: file)
    }

    // ------------------------------------------------------ credit for dwell time

    // -------------------------------------------------------- correcting a vote

    print("\n— reversing a thumb within five seconds is a correction, not a second opinion —")
    do {
        /// Start Flow, let it settle, then press thumbs in a given order at given
        /// times, and run on long enough for everything to be written down.
        @MainActor
        func press(_ presses: [(at: Double, vote: Taste.Vote)], then: Double = 12)
            -> (taste: Taste, verdicts: [FlowDirector.Verdict]) {
            let taste = Taste(now: { dial.t })
            let model = newModel(taste)
            model.flow.start()
            for _ in 0..<900 { model.flow.advance(by: 0.1) }
            var verdicts: [FlowDirector.Verdict] = []
            var t = 0.0
            for p in presses.sorted(by: { $0.at < $1.at }) {
                while t < p.at { model.flow.advance(by: 0.1); t += 0.1 }
                verdicts.append(model.flow.rate(p.vote))
            }
            for _ in 0..<Int(then * 10) { model.flow.advance(by: 0.1) }
            model.flow.stop()
            return (taste, verdicts)
        }

        // The case the listener described: thumbs-down by mistake, thumbs-up a
        // second later. One opinion goes in, and it is the second one.
        let fixed = press([(0, .down), (1.0, .up)])
        check(fixed.taste.ups == 1 && fixed.taste.downs == 0,
              "a reversal inside the window files one vote, the corrected one",
              "\(fixed.taste.ups) up, \(fixed.taste.downs) down")
        check(fixed.verdicts == [.filed, .corrected],
              "and the second press reports itself as a correction",
              "\(fixed.verdicts)")

        // The control that gives the check above its meaning: the same two presses
        // far enough apart are two genuine changes of mind, and both are recorded.
        // Without this, "one vote went in" would also be satisfied by a bug that
        // dropped the second press entirely.
        let late = press([(0, .down), (7.0, .up)])
        check(late.taste.ups == 1 && late.taste.downs == 1,
              "the same two presses outside it are still two opinions",
              "\(late.taste.ups) up, \(late.taste.downs) down")
        check(late.verdicts == [.filed, .filed],
              "and neither reports as a correction", "\(late.verdicts)")

        // Correcting the correction, all inside one window.
        let twice = press([(0, .up), (1.0, .down), (2.0, .up)])
        check(twice.taste.ups == 1 && twice.taste.downs == 0,
              "changing your mind twice inside the window still files one vote",
              "\(twice.taste.ups) up, \(twice.taste.downs) down")

        // A run of presses of the *same* thumb must not hold the vote open for
        // ever — the window is anchored to the first press, not the last.
        let nervous = press([(0, .up), (1, .up), (2, .up), (3, .up), (4, .up)], then: 3)
        check(nervous.taste.ups == 1 && nervous.taste.downs == 0,
              "a nervous run of the same thumb still files exactly one vote, on time",
              "\(nervous.taste.ups) up, \(nervous.taste.downs) down")

        // And the audible half. A thumbs-down that was taken back must leave no
        // trace at all, which means it must not have hurried a change along.
        //
        // Measured against two controls rather than in the abstract, because Flow
        // reseeds every `start()` and changes the drone on its own timers anyway:
        // how often the character moves in the twelve seconds after a *corrected*
        // press has to look like a run with no press in it, and nothing like a run
        // with a real thumbs-down in it.
        @MainActor
        func movedWithin(_ presses: [(at: Double, vote: Taste.Vote)], trials: Int = 30) -> Int {
            func character(_ m: ThrumModel) -> String {
                "\(m.harmony.modeIndex)/\(m.timbreIndex)/\(m.voicing?.rawValue ?? "-")/\(m.harmony.tuning.rawValue)"
            }
            var moved = 0
            for _ in 0..<trials {
                let model = newModel(Taste(now: { dial.t }))
                model.flow.start()
                for _ in 0..<900 { model.flow.advance(by: 0.1) }
                var t = 0.0
                for p in presses.sorted(by: { $0.at < $1.at }) {
                    while t < p.at { model.flow.advance(by: 0.1); t += 0.1 }
                    model.flow.rate(p.vote)
                }
                let before = character(model)
                for _ in 0..<120 { model.flow.advance(by: 0.1) }   // 12 s
                if character(model) != before { moved += 1 }
                model.flow.stop()
            }
            return moved
        }
        // Stated as "which population does the corrected run belong to" rather than
        // as a tolerance on the quiet one. Flow reseeds every `start()` and moves
        // the drone on its own timers, so the quiet baseline is itself noisy — 1 to
        // 7 in 30 across runs — and `corrected <= quiet + 3` failed a third of the
        // time on nothing but that noise. The separation is enormous and stable;
        // the first version of this check just measured it in the wrong units.
        let trials = 40
        let quiet = movedWithin([], trials: trials)
        let corrected = movedWithin([(0, .down), (1.0, .up)], trials: trials)
        let real = movedWithin([(0, .down)], trials: trials)
        check(real >= trials * 4 / 5 && Double(corrected) < Double(quiet + real) / 2,
              "a taken-back thumbs-down does not hurry a change along either",
              "changed within 12 s: no press \(quiet)/\(trials), corrected \(corrected)/\(trials), real \(real)/\(trials)")
    }

    print("\n— credit follows how long a quality has been audible —")
    do {
        check(Taste.credit(dwell: 0) < 0.4, "a quality that just arrived takes partial credit",
              String(format: "%.2f", Taste.credit(dwell: 0)))
        check(Taste.credit(dwell: 6) > Taste.credit(dwell: 1), "and more as it settles")
        check(Taste.credit(dwell: 300) == 1, "a settled one takes all of it")
        check(Taste.credit(dwell: 0) >= 0.3,
              "but a just-changed quality is never discounted to nothing",
              "it is the likeliest reason for the press")
    }

    print(fails == 0 ? "\nAll checks passed.\n" : "\n\(fails) FAILED\n")
    exit(fails == 0 ? 0 : 1)
}

/// Flow keeps its restful-mode list private; this is the count it publishes
/// through behaviour, kept here so a failure message can be read.
let Self_restfulModeCount = 8

MainActor.assumeIsolated { runTasteChecks() }
