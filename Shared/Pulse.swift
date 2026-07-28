import Foundation

/// Thrum's pulse: a tempo, and up to four arpeggiators running over the drone
/// at the same time.
///
/// Nothing here makes a sound of its own. An arpeggio in Thrum is an *accent*:
/// the drone keeps holding exactly as it was, and the pulse rides a fast
/// attack-decay envelope on top of whichever voice it is pointing at. Tap in a
/// chord, start the pulse, and the chord you are already holding starts to
/// shimmer through itself.
///
/// Four lanes at four different rates is the whole point. A lane at one step
/// per beat against a lane at one and a half takes six beats to come back
/// around; against a lane at five it takes a very long time indeed. That drift
/// is where the hypnosis is, and it is why the divisions are ratios rather
/// than note values.

// MARK: - Vocabulary

/// Which columns of the grid a lane draws from. Everything is expressed in
/// *columns* — scale degrees — and then laid out across whichever registers
/// the lane is set to, so one held chord can arpeggiate in four octaves at
/// once without the player having to tap it in four times.
public enum ArpSource: String, CaseIterable, Identifiable, Sendable {
    case held = "Held"
    case chord = "Chord"
    case scale = "Scale"
    case root = "Root"
    case colour = "Colour"

    public var id: String { rawValue }

    public var detail: String {
        switch self {
        case .held:   return "The degrees you are holding, echoed into this lane's registers."
        case .chord:  return "The chord tones of the current mode."
        case .scale:  return "Every degree of the mode."
        case .root:   return "The tonal centre only — a pedal."
        case .colour: return "The degrees the chord leaves out. The tension notes."
        }
    }
}

/// The order a lane walks its notes in.
public enum ArpPattern: String, CaseIterable, Identifiable, Sendable {
    case up = "Up"
    case down = "Down"
    case upDown = "Up·Down"
    case downUp = "Down·Up"
    case converge = "Converge"
    case diverge = "Diverge"
    case pinwheel = "Pinwheel"
    case scatter = "Scatter"
    case chord = "Chord"

    public var id: String { rawValue }

    public var detail: String {
        switch self {
        case .up:       return "Lowest to highest, then round again."
        case .down:     return "Highest to lowest."
        case .upDown:   return "Up and back, turning at both ends."
        case .downUp:   return "Down and back."
        case .converge: return "Outside in — bottom, top, next up, next down."
        case .diverge:  return "Inside out, from the middle of the set."
        case .pinwheel: return "Steps by a stride coprime with the set, so it covers everything in an order you can't predict."
        case .scatter:  return "Any of them, deterministically — the same seed gives the same rain."
        case .chord:    return "All of them together. A pulse rather than an arpeggio."
        }
    }

    /// Which note of `count` this pattern wants on `step`.
    /// Step numbers are absolute positions on the clock, not a running index,
    /// so a lane stays phase-locked to the transport no matter what else
    /// changes underneath it.
    public func index(step: Int, count n: Int, seed: Int) -> Int {
        guard n > 1 else { return 0 }
        let s = step < 0 ? 0 : step
        switch self {
        case .up:
            return s % n
        case .down:
            return n - 1 - s % n
        case .upDown:
            let period = 2 * n - 2
            let k = s % period
            return k < n ? k : period - k
        case .downUp:
            let period = 2 * n - 2
            let k = s % period
            return n - 1 - (k < n ? k : period - k)
        case .converge:
            let k = s % n
            return k % 2 == 0 ? k / 2 : n - 1 - k / 2
        case .diverge:
            let k = s % n
            let mid = n / 2
            return k % 2 == 0 ? min(n - 1, mid + k / 2) : max(0, mid - 1 - k / 2)
        case .pinwheel:
            var stride = 2
            while stride < n && Self.gcd(stride, n) != 1 { stride += 1 }
            return (s &* stride) % n
        case .scatter:
            return min(n - 1, Int(Self.hash01(seed &* 7919 &+ 17, s) * Double(n)))
        case .chord:
            return 0
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Deterministic 0…1 from two integers — no RNG state to carry across
    /// threads, and the same figure every time you come back to it.
    static func hash01(_ a: Int, _ b: Int) -> Double {
        var x = UInt64(bitPattern: Int64(a &* 0x9E37_79B1 &+ b &* 0x85EB_CA77))
        x ^= x >> 33; x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33; x = x &* 0xc4ce_b9fe_1a85_ec53
        x ^= x >> 33
        return Double(x >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// Steps per beat. Ratios rather than note names, because the interesting ones
/// here are the ones that fight: ×1 against ×1.5 is three over two.
public struct Division: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let perBeat: Double
    public let detail: String

    public static let all: [Division] = [
        Division(id: 0, name: "×½",  perBeat: 0.5,  detail: "One note every two beats."),
        Division(id: 1, name: "×¾",  perBeat: 0.75, detail: "Three notes every four beats — the long lean."),
        Division(id: 2, name: "×1",  perBeat: 1.0,  detail: "One note a beat."),
        Division(id: 3, name: "×1½", perBeat: 1.5,  detail: "Three against two."),
        Division(id: 4, name: "×2",  perBeat: 2.0,  detail: "Eighths."),
        Division(id: 5, name: "×3",  perBeat: 3.0,  detail: "Triplets."),
        Division(id: 6, name: "×4",  perBeat: 4.0,  detail: "Sixteenths."),
        Division(id: 7, name: "×6",  perBeat: 6.0,  detail: "Sextuplets — a shimmer more than a rhythm."),
    ]

    public static func at(_ i: Int) -> Division { all[min(max(i, 0), all.count - 1)] }
}

/// Which registers a lane works in. Eight of them, so the Launchpad can cycle
/// the whole list from one pad.
public struct RowSpan: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let low: Int
    public let high: Int

    public static let all: [RowSpan] = [
        RowSpan(id: 0, name: "1–4", low: 0, high: 3),
        RowSpan(id: 1, name: "1–2", low: 0, high: 1),
        RowSpan(id: 2, name: "2–3", low: 1, high: 2),
        RowSpan(id: 3, name: "3–4", low: 2, high: 3),
        RowSpan(id: 4, name: "1",   low: 0, high: 0),
        RowSpan(id: 5, name: "2",   low: 1, high: 1),
        RowSpan(id: 6, name: "3",   low: 2, high: 2),
        RowSpan(id: 7, name: "4",   low: 3, high: 3),
    ]

    public static func at(_ i: Int) -> RowSpan { all[min(max(i, 0), all.count - 1)] }
}

/// One lane's settings, as the player sees them.
public struct ArpLane: Equatable, Sendable {
    public var enabled = false
    public var source: ArpSource = .held
    public var pattern: ArpPattern = .up
    public var divisionIndex = 2
    public var spanIndex = 0
    public var level: Double = 0.8
    /// Every nth step is played at full velocity; the rest sit back.
    public var accentEvery = 4
    /// Where in the bar this lane's step zero falls, in beats.
    public var phase: Double = 0

    public init(enabled: Bool = false, source: ArpSource = .held, pattern: ArpPattern = .up,
                divisionIndex: Int = 2, spanIndex: Int = 0, level: Double = 0.8,
                accentEvery: Int = 4, phase: Double = 0) {
        self.enabled = enabled
        self.source = source
        self.pattern = pattern
        self.divisionIndex = divisionIndex
        self.spanIndex = spanIndex
        self.level = level
        self.accentEvery = accentEvery
        self.phase = phase
    }

    public var division: Division { Division.at(divisionIndex) }
    public var span: RowSpan { RowSpan.at(spanIndex) }

    /// Sensible starting point: two lanes three-against-two, the other two off.
    public static let defaults: [ArpLane] = [
        ArpLane(enabled: true,  source: .held, pattern: .up,     divisionIndex: 2, spanIndex: 1, level: 0.85, accentEvery: 4),
        ArpLane(enabled: true,  source: .held, pattern: .upDown, divisionIndex: 3, spanIndex: 3, level: 0.55, accentEvery: 3, phase: 0.5),
        ArpLane(enabled: false, source: .chord, pattern: .down,  divisionIndex: 4, spanIndex: 2, level: 0.45, accentEvery: 4),
        ArpLane(enabled: false, source: .colour, pattern: .scatter, divisionIndex: 5, spanIndex: 7, level: 0.30, accentEvery: 5),
    ]
}

/// Whole-rig starting points. Eight, so the Launchpad's mode row can hold them.
public struct PulsePreset: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let detail: String
    public let bpm: Double
    public let lanes: [ArpLane]

    public static let all: [PulsePreset] = [
        PulsePreset(id: 0, name: "Pulse", detail: "One lane, one note a beat. The plainest thing that still moves.",
                    bpm: 64, lanes: [
            ArpLane(enabled: true, source: .held, pattern: .up, divisionIndex: 2, spanIndex: 0, level: 0.85, accentEvery: 4),
            ArpLane(), ArpLane(), ArpLane(),
        ]),
        PulsePreset(id: 1, name: "Three : Two", detail: "Two lanes, one and a half against one. Comes round every six beats.",
                    bpm: 68, lanes: [
            ArpLane(enabled: true, source: .held, pattern: .up, divisionIndex: 2, spanIndex: 1, level: 0.85, accentEvery: 4),
            ArpLane(enabled: true, source: .held, pattern: .up, divisionIndex: 3, spanIndex: 3, level: 0.6, accentEvery: 3),
            ArpLane(), ArpLane(),
        ]),
        PulsePreset(id: 2, name: "Tanpura", detail: "A pedal underneath, the held chord walking above it.",
                    bpm: 52, lanes: [
            ArpLane(enabled: true, source: .root, pattern: .up, divisionIndex: 0, spanIndex: 4, level: 0.95, accentEvery: 1),
            ArpLane(enabled: true, source: .held, pattern: .down, divisionIndex: 2, spanIndex: 2, level: 0.6, accentEvery: 4, phase: 0.5),
            ArpLane(), ArpLane(),
        ]),
        PulsePreset(id: 3, name: "Gamelan", detail: "Four registers, four rates, chord tones low and colour up top.",
                    bpm: 76, lanes: [
            ArpLane(enabled: true, source: .chord,  pattern: .up,       divisionIndex: 2, spanIndex: 4, level: 0.9,  accentEvery: 4),
            ArpLane(enabled: true, source: .chord,  pattern: .down,     divisionIndex: 3, spanIndex: 5, level: 0.62, accentEvery: 3),
            ArpLane(enabled: true, source: .scale,  pattern: .pinwheel, divisionIndex: 4, spanIndex: 6, level: 0.42, accentEvery: 6),
            ArpLane(enabled: true, source: .colour, pattern: .scatter,  divisionIndex: 5, spanIndex: 7, level: 0.26, accentEvery: 5),
        ]),
        PulsePreset(id: 4, name: "Phase", detail: "Same figure, four rates, four starting points. Give it two minutes.",
                    bpm: 96, lanes: [
            ArpLane(enabled: true, source: .scale, pattern: .pinwheel, divisionIndex: 2, spanIndex: 4, level: 0.7,  accentEvery: 5, phase: 0.0),
            ArpLane(enabled: true, source: .scale, pattern: .pinwheel, divisionIndex: 3, spanIndex: 5, level: 0.58, accentEvery: 5, phase: 0.25),
            ArpLane(enabled: true, source: .scale, pattern: .pinwheel, divisionIndex: 4, spanIndex: 6, level: 0.46, accentEvery: 5, phase: 0.5),
            ArpLane(enabled: true, source: .scale, pattern: .pinwheel, divisionIndex: 5, spanIndex: 7, level: 0.34, accentEvery: 5, phase: 0.75),
        ]),
        PulsePreset(id: 5, name: "Rain", detail: "A slow root, and scatter falling through the top two octaves.",
                    bpm: 60, lanes: [
            ArpLane(enabled: true, source: .root,  pattern: .up,      divisionIndex: 0, spanIndex: 4, level: 0.85, accentEvery: 1),
            ArpLane(enabled: true, source: .scale, pattern: .scatter, divisionIndex: 6, spanIndex: 6, level: 0.26, accentEvery: 7),
            ArpLane(enabled: true, source: .scale, pattern: .scatter, divisionIndex: 7, spanIndex: 7, level: 0.18, accentEvery: 11),
            ArpLane(),
        ]),
        PulsePreset(id: 6, name: "Undertow", detail: "Half-time and three-quarter time, low and slow. Barely an arpeggio.",
                    bpm: 48, lanes: [
            ArpLane(enabled: true, source: .held, pattern: .down,   divisionIndex: 0, spanIndex: 1, level: 0.9, accentEvery: 2),
            ArpLane(enabled: true, source: .held, pattern: .downUp, divisionIndex: 1, spanIndex: 2, level: 0.6, accentEvery: 3, phase: 0.5),
            ArpLane(), ArpLane(),
        ]),
        PulsePreset(id: 7, name: "Swarm", detail: "Everything at once, quietly. Individual notes stop being audible.",
                    bpm: 108, lanes: [
            ArpLane(enabled: true, source: .scale, pattern: .converge, divisionIndex: 4, spanIndex: 1, level: 0.34, accentEvery: 8),
            ArpLane(enabled: true, source: .scale, pattern: .diverge,  divisionIndex: 5, spanIndex: 2, level: 0.30, accentEvery: 7),
            ArpLane(enabled: true, source: .scale, pattern: .pinwheel, divisionIndex: 6, spanIndex: 3, level: 0.24, accentEvery: 6),
            ArpLane(enabled: true, source: .scale, pattern: .scatter,  divisionIndex: 7, spanIndex: 7, level: 0.18, accentEvery: 5),
        ]),
    ]
}

// MARK: - Clock

/// The clock and the four lanes, running off the main thread.
///
/// The lanes are handed a *resolved* plan — a plain list of pad numbers per
/// lane — so this object never has to reach back into the harmony, the model
/// or SwiftUI to decide what to play. Everything it touches is confined to one
/// serial queue, and the only thing it talks to is the engine's lock-free
/// event queue.
///
/// Steps land on a four-millisecond grid, and the engine picks them up at the
/// next render block. Against a pluck attack measured in tens of milliseconds
/// that is inaudible, and it buys the whole feature freedom from the main
/// thread: the pulse does not stutter when the window redraws.
public final class PulseCore: @unchecked Sendable {
    public static let laneCount = 4
    /// One hue per lane, used everywhere a lane shows up — on screen and on
    /// the Launchpad's arp page — so lane two is the same green in both places.
    public static let laneHues: [Double] = [0.09, 0.36, 0.55, 0.80]

    /// A lane with its notes already worked out.
    public struct PlanLane: Sendable {
        public var enabled = false
        public var pads: [Int] = []
        public var perBeat: Double = 1
        public var pattern: ArpPattern = .up
        public var level: Double = 0.8
        public var accentEvery = 4
        public var phase: Double = 0
        public init() {}
    }

    private let engine: DroneEngine
    private let queue = DispatchQueue(label: "space.thrum.pulse", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // Everything below is confined to `queue`.
    private var lanes = [PlanLane](repeating: PlanLane(), count: laneCount)
    private var nextStep = [Int](repeating: 0, count: laneCount)
    private var bpm = 68.0
    private var swing = 0.0
    private var humanize = 0.22
    private var masterLevel = 0.7
    private var running = false
    private var beat = 0.0
    private var lastTick = 0.0
    private var taps: [Double] = []

    /// Written from the pulse queue, read from the UI at animation rate. Same
    /// benign race as the engine's meters — a stale frame costs nothing.
    public private(set) var displayBeat: Double = 0
    /// Last pad each lane struck, and when, for the on-screen lane strips.
    public let lanePad: UnsafeMutablePointer<Int32>
    public let laneFlash: UnsafeMutablePointer<Double>

    /// Called on the main queue when tap tempo works out a new tempo.
    public var onTempo: ((Double) -> Void)?

    public init(engine: DroneEngine) {
        self.engine = engine
        lanePad = .allocate(capacity: Self.laneCount)
        lanePad.initialize(repeating: -1, count: Self.laneCount)
        laneFlash = .allocate(capacity: Self.laneCount)
        laneFlash.initialize(repeating: 0, count: Self.laneCount)
    }

    deinit {
        timer?.cancel()
        lanePad.deallocate()
        laneFlash.deallocate()
    }

    @inline(__always)
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) * 1e-9
    }

    // MARK: Control

    public func setRunning(_ on: Bool) {
        queue.async {
            guard on != self.running else { return }
            self.running = on
            if on {
                self.lastTick = Self.now()
                self.startTimer()
            } else {
                self.stopTimer()
            }
        }
    }

    public func setTempo(_ v: Double) {
        queue.async { self.bpm = min(240, max(20, v)) }
    }

    public func setFeel(swing: Double, humanize: Double, level: Double) {
        queue.async {
            self.swing = min(0.7, max(0, swing))
            self.humanize = min(1, max(0, humanize))
            self.masterLevel = min(1, max(0, level))
        }
    }

    public func update(lanes: [PlanLane]) {
        queue.async { self.lanes = lanes }
    }

    /// Tap tempo. The timestamp is taken on the caller's thread so queue
    /// latency never lands in the average.
    public func tap() {
        let t = Self.now()
        queue.async {
            if let last = self.taps.last, t - last > 2.4 { self.taps.removeAll() }
            self.taps.append(t)
            if self.taps.count > 5 { self.taps.removeFirst() }
            if self.taps.count >= 2 {
                var total = 0.0
                for i in 1..<self.taps.count { total += self.taps[i] - self.taps[i - 1] }
                let avg = total / Double(self.taps.count - 1)
                if avg > 0.22, avg < 3.2 {
                    self.bpm = min(240, max(20, 60.0 / avg))
                    let out = self.bpm
                    DispatchQueue.main.async { self.onTempo?(out) }
                }
            }
            // The tap you just made is the downbeat.
            self.realignLocked(at: t)
        }
    }

    /// Drop the whole rig back onto beat zero — the "everybody together" gesture.
    public func realign() {
        let t = Self.now()
        queue.async { self.realignLocked(at: t) }
    }

    private func realignLocked(at t: Double) {
        beat = 0
        lastTick = t
        displayBeat = 0
        for i in nextStep.indices { nextStep[i] = 0 }
    }

    public func stop() {
        queue.sync {
            running = false
            stopTimer()
        }
    }

    // MARK: Timer

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let t = Self.now()
        // Clamp the delta so waking from sleep doesn't fire a thousand steps.
        let dt = min(0.25, max(0, t - lastTick))
        lastTick = t
        guard running else { return }
        beat += dt * bpm / 60.0
        displayBeat = beat

        for i in lanes.indices {
            let lane = lanes[i]
            guard lane.enabled, !lane.pads.isEmpty, lane.perBeat > 0 else { continue }
            let current = Int(floor(max(0, beat - lane.phase) * lane.perBeat))
            if nextStep[i] < current - 2 { nextStep[i] = current }
            var s = nextStep[i]
            var fired = 0
            while s >= 0, due(lane, step: s) <= beat, fired < 8 {
                fire(lane, laneIndex: i, step: s, at: t)
                s += 1
                fired += 1
            }
            nextStep[i] = s
        }
    }

    /// When step `s` of this lane is due, in beats. Odd steps get pushed late
    /// by the swing amount — a fraction of a step, so swing means the same
    /// thing whatever rate the lane is running at.
    private func due(_ lane: PlanLane, step s: Int) -> Double {
        let late = (s % 2 == 1) ? swing * 0.5 : 0
        return lane.phase + (Double(s) + late) / lane.perBeat
    }

    private func fire(_ lane: PlanLane, laneIndex: Int, step: Int, at t: Double) {
        let n = lane.pads.count
        let accented = lane.accentEvery <= 1 || step % lane.accentEvery == 0
        // A little unevenness in the velocities keeps a long cycle from
        // reading as a machine. Deterministic, so a figure you like comes back.
        let jitter = humanize * (ArpPattern.hash01(laneIndex &+ 31, step) - 0.5) * 0.55
        var v = lane.level * masterLevel * (accented ? 1.0 : 0.58) * (1.0 + jitter)
        v = min(1.0, max(0.02, v))

        if lane.pattern == .chord {
            let spread = min(1.0, 0.85 / Double(n).squareRoot())
            for p in lane.pads { engine.pluck(pad: p, velocity: v * spread) }
            lanePad[laneIndex] = Int32(lane.pads[0])
        } else {
            let pad = lane.pads[lane.pattern.index(step: step, count: n, seed: laneIndex)]
            engine.pluck(pad: pad, velocity: v)
            lanePad[laneIndex] = Int32(pad)
        }
        laneFlash[laneIndex] = t
    }
}
