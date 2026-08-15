import Foundation

/// A drone timbre is a spectrum recipe, not a preset of knobs. Each one is a
/// list of partials (harmonic number → amplitude) plus a handful of biases that
/// nudge the shared engine: how stretched the overtones are, how much the
/// detuned pairs beat, how hard the saturation leans on it.
public struct Timbre: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let blurb: String
    /// (harmonic ratio, linear amplitude). Ratios below 1 are sub-octaves.
    public let partials: [PartialSpec]
    /// Piano-style stretch: ratio = h·√(1 + B·h²). Tiny values, big effect.
    public let inharmonicity: Double
    /// Multiplies the global brightness cutoff.
    public let cutoffScale: Double
    /// Extra saturation this timbre wants.
    public let drive: Double
    /// Multiplies the global beating rate.
    public let beatScale: Double
    /// Baseline jawari buzz even with the sitar control at zero.
    public let sitarBias: Double
    /// Multiplies the swell time — reeds speak faster than bowed strings.
    public let swellScale: Double
    public let hue: Double

    public struct PartialSpec: Sendable {
        public let h: Double
        public let a: Double
        public init(_ h: Double, _ a: Double) { self.h = h; self.a = a }
    }
}

public enum TimbreCatalog {
    private typealias P = Timbre.PartialSpec

    public static let all: [Timbre] = [
        Timbre(
            id: 0, name: "Harmonium",
            blurb: "Indian reed organ. Warm odd-leaning spectrum, air behind it, a slow shimmer between the reeds.",
            partials: [P(1, 1.0), P(2, 0.62), P(3, 0.50), P(4, 0.29), P(5, 0.25),
                       P(6, 0.15), P(7, 0.12), P(8, 0.075), P(9, 0.055), P(10, 0.035)],
            inharmonicity: 6e-5, cutoffScale: 1.00, drive: 0.34, beatScale: 1.00,
            sitarBias: 0.05, swellScale: 0.75, hue: 0.08),

        Timbre(
            id: 1, name: "Pipe Organ",
            blurb: "A drawn registration: 16′ 8′ 4′ 2⅔′ 2′ 1⅗′. Stable, wide, church-cold at the top.",
            partials: [P(0.5, 0.38), P(1, 1.0), P(2, 0.56), P(3, 0.34), P(4, 0.30),
                       P(5, 0.14), P(6, 0.12), P(8, 0.10), P(10, 0.05), P(12, 0.04)],
            inharmonicity: 0, cutoffScale: 1.18, drive: 0.16, beatScale: 0.65,
            sitarBias: 0.0, swellScale: 1.0, hue: 0.60),

        Timbre(
            id: 2, name: "Shruti Box",
            blurb: "Bellows and free reeds. Dark, thick, and it beats hard — the sound of a room breathing.",
            partials: [P(1, 1.0), P(2, 0.52), P(3, 0.44), P(4, 0.23), P(5, 0.21),
                       P(6, 0.14), P(7, 0.13), P(8, 0.075), P(9, 0.06), P(11, 0.04)],
            inharmonicity: 1.6e-4, cutoffScale: 0.74, drive: 0.44, beatScale: 1.40,
            sitarBias: 0.10, swellScale: 0.85, hue: 0.03),

        Timbre(
            id: 3, name: "Bowed Strings",
            blurb: "A full 1/n series under a soft filter. Rosin and horsehair, endlessly sustained.",
            partials: [P(1, 1.0), P(2, 0.47), P(3, 0.30), P(4, 0.22), P(5, 0.17), P(6, 0.14),
                       P(7, 0.11), P(8, 0.09), P(9, 0.075), P(10, 0.06), P(11, 0.05), P(12, 0.04)],
            inharmonicity: 4e-5, cutoffScale: 0.92, drive: 0.24, beatScale: 0.90,
            sitarBias: 0.0, swellScale: 1.35, hue: 0.53),

        Timbre(
            id: 4, name: "Bagpipe Drone",
            blurb: "Cylindrical bore: odd harmonics dominate, evens barely there. Reedy, nasal, relentless.",
            partials: [P(1, 1.0), P(2, 0.17), P(3, 0.70), P(4, 0.11), P(5, 0.43), P(6, 0.075),
                       P(7, 0.31), P(8, 0.05), P(9, 0.21), P(11, 0.14), P(13, 0.09)],
            inharmonicity: 8e-5, cutoffScale: 1.05, drive: 0.55, beatScale: 1.55,
            sitarBias: 0.14, swellScale: 0.65, hue: 0.35),

        Timbre(
            id: 5, name: "Analog Bloom",
            blurb: "Three-oscillator saw stack under a lazy filter. The 1970s idea of infinity.",
            partials: [P(0.5, 0.30), P(1, 1.0), P(2, 0.50), P(3, 0.333), P(4, 0.25), P(5, 0.20),
                       P(6, 0.167), P(7, 0.143), P(8, 0.125), P(9, 0.111), P(10, 0.10)],
            inharmonicity: 0, cutoffScale: 0.80, drive: 0.30, beatScale: 1.15,
            sitarBias: 0.0, swellScale: 1.15, hue: 0.75),

        Timbre(
            id: 6, name: "Glass Choir",
            blurb: "Stretched, hollow, mostly even partials. Sounds like light through a window.",
            partials: [P(1, 1.0), P(2, 0.46), P(3, 0.18), P(4, 0.36), P(5, 0.13), P(6, 0.10),
                       P(8, 0.17), P(10, 0.07), P(12, 0.055), P(16, 0.03)],
            inharmonicity: 5.5e-4, cutoffScale: 1.42, drive: 0.10, beatScale: 0.80,
            sitarBias: 0.0, swellScale: 1.5, hue: 0.47),

        Timbre(
            id: 7, name: "Tanpura",
            blurb: "Fourteen partials and a jawari bridge. Buzz is not a defect here, it is the instrument.",
            partials: [P(1, 1.0), P(2, 0.70), P(3, 0.56), P(4, 0.45), P(5, 0.40), P(6, 0.32), P(7, 0.28),
                       P(8, 0.24), P(9, 0.19), P(10, 0.15), P(11, 0.12), P(12, 0.10), P(13, 0.08), P(14, 0.06)],
            inharmonicity: 2.2e-4, cutoffScale: 1.10, drive: 0.48, beatScale: 1.20,
            sitarBias: 0.45, swellScale: 0.9, hue: 0.11),
    ]

    /// Every harmonic number any timbre asks for, once, in order.
    ///
    /// This is what makes one timbre able to *become* another instead of replacing
    /// it. Each voice renders this list rather than a timbre's own partial list, so
    /// slot `k` is the same harmonic in every timbre and always has been — which
    /// means a timbre change is nothing but the amplitude of each slot moving to a
    /// new value. Partials the two timbres share simply change level; ones only the
    /// old timbre had fade to nothing; ones only the new one has rise from it. No
    /// oscillator is ever started, stopped or re-tuned, so there is no phase to
    /// break and no moment at which the change happens.
    ///
    /// The alternative — rendering both timbres at once and cross-mixing them —
    /// costs twice the partials for the whole fade and still has to decide what to
    /// do about the harmonics they have in common (summing two copies of the same
    /// partial at different phases is a comb filter, not a crossfade).
    ///
    /// Currently {0.5, 1…14, 16}: sixteen slots against the fourteen the densest
    /// single timbre uses, so the cost of the whole feature is two oscillator pairs
    /// per voice.
    public static let harmonics: [Double] = {
        var seen = Set<Double>()
        for t in all { for p in t.partials { seen.insert(p.h) } }
        return seen.sorted()
    }()

    /// The slot count every voice renders. Not "the most partials a timbre has" any
    /// more — see `harmonics`.
    public static let maxPartials = harmonics.count
}
