import Foundation

/// A jazz mode plus the chord it implies. Thrum treats these as one object:
/// picking "Dorian" is the same act as picking "m7" — the chord is what the
/// drone holds, the mode is what the soloist gets to explore over it.
public struct Mode: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let chordName: String
    /// Semitone offsets from the tonal center, one octave's worth.
    public let degrees: [Int]
    /// Which of those offsets are chord tones (lit bright on the grid).
    public let chordSemitones: [Int]
    /// Grid/UI hue, 0–1.
    public let hue: Double

    public static func == (a: Mode, b: Mode) -> Bool { a.id == b.id }
}

public enum ModeCatalog {
    /// Two banks of eight, matching the eight pads of the Launchpad's bottom row.
    public static let all: [Mode] = [
        // Bank A — the diatonic core
        Mode(id: 0,  name: "Ionian",           chordName: "maj7",     degrees: [0, 2, 4, 5, 7, 9, 11],      chordSemitones: [0, 4, 7, 11], hue: 0.13),
        Mode(id: 1,  name: "Dorian",           chordName: "m7",       degrees: [0, 2, 3, 5, 7, 9, 10],      chordSemitones: [0, 3, 7, 10], hue: 0.52),
        Mode(id: 2,  name: "Phrygian",         chordName: "m7♭9",     degrees: [0, 1, 3, 5, 7, 8, 10],      chordSemitones: [0, 3, 7, 10], hue: 0.78),
        Mode(id: 3,  name: "Lydian",           chordName: "maj7♯11",  degrees: [0, 2, 4, 6, 7, 9, 11],      chordSemitones: [0, 4, 7, 11], hue: 0.30),
        Mode(id: 4,  name: "Mixolydian",       chordName: "7",        degrees: [0, 2, 4, 5, 7, 9, 10],      chordSemitones: [0, 4, 7, 10], hue: 0.07),
        Mode(id: 5,  name: "Aeolian",          chordName: "m7",       degrees: [0, 2, 3, 5, 7, 8, 10],      chordSemitones: [0, 3, 7, 10], hue: 0.62),
        Mode(id: 6,  name: "Locrian",          chordName: "m7♭5",     degrees: [0, 1, 3, 5, 6, 8, 10],      chordSemitones: [0, 3, 6, 10], hue: 0.86),
        Mode(id: 7,  name: "Harmonic Minor",   chordName: "mMaj7",    degrees: [0, 2, 3, 5, 7, 8, 11],      chordSemitones: [0, 3, 7, 11], hue: 0.94),
        // Bank B — the color modes
        Mode(id: 8,  name: "Lydian Dominant",  chordName: "7♯11",     degrees: [0, 2, 4, 6, 7, 9, 10],      chordSemitones: [0, 4, 7, 10], hue: 0.10),
        Mode(id: 9,  name: "Altered",          chordName: "7alt",     degrees: [0, 1, 3, 4, 6, 8, 10],      chordSemitones: [0, 4, 6, 10], hue: 0.98),
        Mode(id: 10, name: "Phrygian Dominant", chordName: "7♭9♭13",  degrees: [0, 1, 4, 5, 7, 8, 10],      chordSemitones: [0, 4, 7, 10], hue: 0.04),
        Mode(id: 11, name: "Melodic Minor",    chordName: "mMaj7",    degrees: [0, 2, 3, 5, 7, 9, 11],      chordSemitones: [0, 3, 7, 11], hue: 0.57),
        Mode(id: 12, name: "Whole Tone",       chordName: "7♯5",      degrees: [0, 2, 4, 6, 8, 10],         chordSemitones: [0, 4, 8, 10], hue: 0.44),
        Mode(id: 13, name: "Diminished H–W",   chordName: "7♭9",      degrees: [0, 1, 3, 4, 6, 7, 9, 10],   chordSemitones: [0, 4, 7, 10], hue: 0.72),
        Mode(id: 14, name: "Minor Pentatonic", chordName: "m7",       degrees: [0, 3, 5, 7, 10],            chordSemitones: [0, 3, 7, 10], hue: 0.48),
        Mode(id: 15, name: "Bebop Dominant",   chordName: "7",        degrees: [0, 2, 4, 5, 7, 9, 10, 11],  chordSemitones: [0, 4, 7, 10], hue: 0.17),
    ]

    public static let bankSize = 8
    public static var bankCount: Int { (all.count + bankSize - 1) / bankSize }
}

/// One addressable drone pitch: a pad on the grid and a place in the harmony.
public struct GridTone: Identifiable, Equatable, Sendable {
    public let id: Int          // pad index 0…31
    public let row: Int         // 0 = lowest octave (bottom of the tone block)
    public let col: Int         // 0…7, scale degree within the row
    public let semitone: Int    // from the tonal center, octaves included
    public let isChordTone: Bool
    public let isRoot: Bool
    public let degreeLabel: String
    public let noteName: String
    /// Scientific octave, so the four registers are told apart at a glance.
    public let octave: Int
    public let frequency: Double
    /// Cents away from where 12-TET would put this note.
    public let deviation: Double
}

/// The whole harmonic state: key, register, mode, temperament. Turning this
/// into 32 pitches is the one job it has.
public struct Harmony: Equatable, Sendable {
    public var keyPitchClass: Int = 2      // D — the classic drone key
    public var rootOctave: Int = 3
    public var modeIndex: Int = 1          // Dorian
    public var tuning: TuningSystem = .just5Limit
    public var a4: Double = 440.0

    public static let rows = 4
    public static let cols = 8
    public static let padCount = rows * cols

    public var mode: Mode { ModeCatalog.all[min(modeIndex, ModeCatalog.all.count - 1)] }

    public var rootFrequency: Double {
        Pitch.frequency(pitchClass: keyPitchClass, octave: rootOctave, a4: a4)
    }

    /// The block sits one octave under the nominal root so there's real weight
    /// at the bottom: rows cover rootOctave−1 … rootOctave+2.
    public var baseOctave: Int { rootOctave - 1 }

    public var title: String {
        "\(Pitch.name(keyPitchClass))\(mode.chordName)"
    }

    public var subtitle: String {
        "\(Pitch.name(keyPitchClass)) \(mode.name) · \(tuning.name)"
    }

    /// Semitone offset from the tonal center for a grid position.
    public func semitone(row: Int, col: Int) -> Int {
        let d = mode.degrees
        let k = d.count
        return d[col % k] + 12 * (col / k) + 12 * row
    }

    public func frequency(row: Int, col: Int) -> Double {
        let s = semitone(row: row, col: col)
        let base = Pitch.frequency(pitchClass: keyPitchClass, octave: baseOctave, a4: a4)
        return base * tuning.ratio(semitone: s)
    }

    public func tones() -> [GridTone] {
        var out: [GridTone] = []
        out.reserveCapacity(Self.padCount)
        for row in 0..<Self.rows {
            for col in 0..<Self.cols {
                let s = semitone(row: row, col: col)
                let pc = ((s % 12) + 12) % 12
                let midi = 12 * (baseOctave + 1) + keyPitchClass + s
                out.append(GridTone(
                    id: row * Self.cols + col,
                    row: row,
                    col: col,
                    semitone: s,
                    isChordTone: mode.chordSemitones.contains(pc),
                    isRoot: pc == 0,
                    degreeLabel: Self.degreeLabels[pc],
                    noteName: Pitch.name(keyPitchClass + s),
                    octave: midi / 12 - 1,
                    frequency: frequency(row: row, col: col),
                    deviation: tuning.deviation(semitone: s)
                ))
            }
        }
        return out
    }

    static let degreeLabels = ["1", "♭9", "9", "♭3", "3", "11", "♯11", "5", "♭13", "13", "♭7", "7"]
}
