import Foundation

/// Starting points, because a good drone is a specific chord voicing and not
/// just "the notes of the chord". Most of these are borrowed from traditions
/// that have been holding drones for a very long time — what is worth
/// stealing from each is not its scale, which Thrum already has, but *which
/// intervals it leaves out and in which register it puts the rest*.
public enum DroneVoicing: String, CaseIterable, Identifiable {
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

    /// Voicings Flow will open with or move to. Weighted to the sustained ones —
    /// these are the ones that hold up for minutes without asking anything.
    /// Here rather than in Flow because the audio unit's Flow uses it too.
    public static let flowOpenings: [DroneVoicing] = [
        .tanpura, .openFifths, .pedalRoot, .modalSpread, .aitake,
        .hardanger, .guqin, .launeddas, .highland, .gyuto, .didgeridoo, .uilleann,
    ]

    /// Modes Flow will move between. The tense ones — Locrian, Altered,
    /// Diminished, Whole Tone — are left out: they are good to play *over* and
    /// wearing to sit *inside* for an hour.
    public static let flowModes = [0, 1, 3, 4, 5, 11, 14, 8]

    /// The pads this voicing sounds in `harmony`'s mode, and how loud — one entry
    /// per pad, in pad order. Pure: the key and temperament change what a pad
    /// sounds like, never which pads a voicing picks.
    public func pads(in harmony: Harmony) -> [(pad: Int, level: Double)] {
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

        switch self {
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
        return levels.keys.sorted().map { (pad: $0, level: levels[$0]!) }
    }
}
