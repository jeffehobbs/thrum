import Foundation

// Offline checks for Flow. Flow's whole promise is "nothing ever jumps", and that
// is a property you can measure rather than listen for — so this drives the
// director through hours of compressed time and watches every control.
//
//   swiftc -O -o /tmp/thrumflow \
//     Shared/{Tuning,Harmony,Timbre,Events,Cathedral,DroneEngine,Pulse,Spatial,ThrumModel,Flow}.swift \
//     Tools/flow/main.swift
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
        var run = Run()

        var previous: [Param: Double] = [:]
        for p in Param.allCases { previous[p] = model.value(p) }

        model.flow.start()
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
            run.ticks += 1
        }
        for p in Param.allCases { run.finals[p] = model.value(p) }
        check(model.value(.masterVolume) == volumeAtStart,
              "Output is never touched", "started \(volumeAtStart), ended \(model.value(.masterVolume))")
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

    print("\n— how long a fifth takes to arrive —")

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
    check(byHand < 4, "a hand-made key change still arrives promptly",
          String(format: "%.1f s", byHand))
    check(inFlow > byHand * 4, "Flow's key change is a modulation, not a sweep",
          String(format: "%.1f s vs %.1f s", inFlow, byHand))

    print("\n— it should be a different journey every time —")
    let b = fly(hours: 3)
    let differing = Param.allCases.filter { abs((a.finals[$0] ?? 0) - (b.finals[$0] ?? 0)) > 1e-6 }.count
    check(differing >= 8, "two runs end up somewhere different",
          "\(differing) of \(Param.allCases.count) controls differ")

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
