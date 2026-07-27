import Foundation

/// Tuning systems Thrum can render a mode in.
///
/// The tonal center itself is always placed at concert pitch — a drone has to
/// agree with the horn player in the room. Every interval *above* the center
/// comes from the system's own cents table, so "just" really is just: the
/// fifth is 701.955¢, not 700¢, and the major third is a beatless 386.31¢.
public enum TuningSystem: Int, CaseIterable, Identifiable, Sendable {
    case just5Limit
    case just7Limit
    case pythagorean
    case quarterComma
    case twelveTET
    case nineteenTET
    case thirtyOneTET
    case harmonicSeries

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .just5Limit:    return "Just — 5-limit"
        case .just7Limit:    return "Just — 7-limit"
        case .pythagorean:   return "Pythagorean"
        case .quarterComma:  return "¼-comma Meantone"
        case .twelveTET:     return "12-TET"
        case .nineteenTET:   return "19-TET"
        case .thirtyOneTET:  return "31-TET"
        case .harmonicSeries: return "Harmonic Series"
        }
    }

    public var short: String {
        switch self {
        case .just5Limit:    return "JI5"
        case .just7Limit:    return "JI7"
        case .pythagorean:   return "PYTH"
        case .quarterComma:  return "MEAN"
        case .twelveTET:     return "12"
        case .nineteenTET:   return "19"
        case .thirtyOneTET:  return "31"
        case .harmonicSeries: return "HARM"
        }
    }

    public var blurb: String {
        switch self {
        case .just5Limit:
            return "Small whole-number ratios — 3:2, 5:4, 6:5. Thirds and fifths lock and stop beating."
        case .just7Limit:
            return "Adds the septimal 7:4 and 7:6. Blue, slightly flat sevenths that sit under a horn."
        case .pythagorean:
            return "Stacked pure fifths. Wide, singing thirds with a bright medieval edge."
        case .quarterComma:
            return "Pure 5:4 thirds bought with narrowed fifths. Sweet and old."
        case .twelveTET:
            return "The neutral reference. Everything beats a little, nothing is out of place."
        case .nineteenTET:
            return "63.2¢ steps. Flat fifths, gorgeous thirds, a distinct minor/augmented split."
        case .thirtyOneTET:
            return "38.7¢ steps — near-perfect meantone with usable septimal intervals."
        case .harmonicSeries:
            return "Each degree snaps to the nearest partial 16–32 of the root. Overtone-locked."
        }
    }

    /// Cents above the tonal center for a semitone offset. Handles any integer,
    /// negative or beyond an octave, by folding to a pitch class plus octaves.
    public func cents(semitone: Int) -> Double {
        let oct = Int(floor(Double(semitone) / 12.0))
        let pc = semitone - oct * 12
        return Double(oct) * 1200.0 + table[pc]
    }

    /// Frequency ratio above the tonal center.
    public func ratio(semitone: Int) -> Double {
        pow(2.0, cents(semitone: semitone) / 1200.0)
    }

    /// How far this system's version of a degree sits from 12-TET, in cents.
    public func deviation(semitone: Int) -> Double {
        cents(semitone: semitone) - Double(semitone) * 100.0
    }

    private var table: [Double] {
        switch self {
        case .just5Limit:   return Self.just5
        case .just7Limit:   return Self.just7
        case .pythagorean:  return Self.pyth
        case .quarterComma: return Self.meantone
        case .twelveTET:    return Self.twelve
        case .nineteenTET:  return Self.et(19)
        case .thirtyOneTET: return Self.et(31)
        case .harmonicSeries: return Self.harmonic
        }
    }

    // MARK: - Tables

    @inline(__always)
    private static func c(_ num: Double, _ den: Double) -> Double {
        1200.0 * log2(num / den)
    }

    /// 1/1 16/15 9/8 6/5 5/4 4/3 45/32 3/2 8/5 5/3 9/5 15/8
    private static let just5: [Double] = [
        0, c(16, 15), c(9, 8), c(6, 5), c(5, 4), c(4, 3),
        c(45, 32), c(3, 2), c(8, 5), c(5, 3), c(9, 5), c(15, 8),
    ]

    /// Septimal shading: 8/7 whole tone, 7/6 subminor third, 7/5 tritone, 7/4 seventh.
    private static let just7: [Double] = [
        0, c(15, 14), c(8, 7), c(7, 6), c(5, 4), c(4, 3),
        c(7, 5), c(3, 2), c(14, 9), c(5, 3), c(7, 4), c(15, 8),
    ]

    /// Stacked 3:2s, reduced into one octave (Ab..C#).
    private static let pyth: [Double] = [
        0, c(256, 243), c(9, 8), c(32, 27), c(81, 64), c(4, 3),
        c(729, 512), c(3, 2), c(128, 81), c(27, 16), c(16, 9), c(243, 128),
    ]

    /// ¼-comma meantone: fifth = 696.578¢, third = pure 386.314¢.
    private static let meantone: [Double] = {
        let fifth = 1200.0 * log2(pow(5.0, 0.25))  // 696.5784¢
        func fold(_ steps: Int) -> Double {
            var v = Double(steps) * fifth
            while v < 0 { v += 1200 }
            while v >= 1200 { v -= 1200 }
            return v
        }
        // semitone -> position in the circle of fifths (C=0, G=1, D=2, ... F=-1)
        let circle = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]
        return circle.map { fold($0) }
    }()

    private static let twelve: [Double] = (0..<12).map { Double($0) * 100.0 }

    /// Nearest step of an n-tone equal temperament to each 12-TET semitone.
    private static func et(_ n: Int) -> [Double] {
        let step = 1200.0 / Double(n)
        return (0..<12).map { i in
            (Double(i) * 100.0 / step).rounded() * step
        }
    }

    /// Nearest partial of the root in the 16…32 band (one octave of the series).
    private static let harmonic: [Double] = (0..<12).map { i in
        let target = Double(i) * 100.0
        var best = 16.0
        var bestErr = Double.greatestFiniteMagnitude
        for h in 16...32 {
            let cents = 1200.0 * log2(Double(h) / 16.0)
            let err = abs(cents - target)
            if err < bestErr { bestErr = err; best = Double(h) }
        }
        return 1200.0 * log2(best / 16.0)
    }
}

public enum Pitch {
    public static let names = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    /// Concert-pitch frequency of a pitch class in a scientific octave.
    public static func frequency(pitchClass: Int, octave: Int, a4: Double) -> Double {
        let midi = 12 * (octave + 1) + pitchClass
        return a4 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    public static func name(_ pitchClass: Int) -> String {
        names[((pitchClass % 12) + 12) % 12]
    }
}
