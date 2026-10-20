import AudioToolbox
import Foundation

/// Every control the audio unit exposes to its host, in one table.
///
/// Addresses are the saved identity of a parameter — a Logic project stores
/// automation and patch state against them — so they are append-only. A new
/// control goes on the end with the next number, never in the middle.
///
/// Fractions the engine holds as 0…1 are published as 0…100 percent. That is
/// the unit Logic knows how to draw and how to type into, and the kernel does
/// the one division on the way in.
enum ThrumParam: AUParameterAddress, CaseIterable {
    case timbre = 0, tuning, key, a4, articulation
    case swell, fade, velocity, beating, drift, motion, sitar
    case brightness, warmth, presence, air, drive
    case decay, wet, damping, size, width, fieldDrift
    case accentAttack, accentDecay, glide, morph, output
    case flow, mode
}

struct ThrumParamSpec {
    let param: ThrumParam
    let identifier: String
    let name: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let unit: AudioUnitParameterUnit
    /// Seconds and hertz are spread logarithmically on the slider: 0.4 s and
    /// 40 s both need to be reachable, and on a linear track the first tenth
    /// would hold everything under four seconds.
    var exponential = false
    /// Indexed parameters: the names, one per integer value from zero.
    var values: [String]? = nil

    static let all: [ThrumParamSpec] = [
        .init(param: .timbre, identifier: "timbre", name: "Timbre", range: 0...Double(TimbreCatalog.all.count - 1),
              defaultValue: 0, unit: .indexed, values: TimbreCatalog.all.map(\.name)),
        .init(param: .tuning, identifier: "tuning", name: "Tuning", range: 0...Double(TuningSystem.allCases.count - 1),
              defaultValue: 0, unit: .indexed, values: TuningSystem.allCases.map(\.name)),
        .init(param: .key, identifier: "key", name: "Key", range: 0...11,
              defaultValue: 2, unit: .indexed, values: Pitch.names),
        .init(param: .a4, identifier: "a4", name: "A4", range: 415...466,
              defaultValue: 440, unit: .hertz),
        .init(param: .articulation, identifier: "articulation", name: "Articulation", range: 0...1,
              defaultValue: 0, unit: .indexed, values: ["Drone", "Accent"]),

        .init(param: .swell, identifier: "swell", name: "Swell", range: 0.4...40,
              defaultValue: 7, unit: .seconds, exponential: true),
        .init(param: .fade, identifier: "fade", name: "Fade", range: 0.4...60,
              defaultValue: 11, unit: .seconds, exponential: true),
        .init(param: .velocity, identifier: "velocity", name: "Velocity", range: 0...100,
              defaultValue: 50, unit: .percent),
        .init(param: .beating, identifier: "beating", name: "Beating", range: 0...100,
              defaultValue: 50, unit: .percent),
        .init(param: .drift, identifier: "drift", name: "Drift", range: 0...100,
              defaultValue: 45, unit: .percent),
        .init(param: .motion, identifier: "motion", name: "Motion", range: 0...100,
              defaultValue: 55, unit: .percent),
        .init(param: .sitar, identifier: "sitar", name: "Sitar", range: 0...100,
              defaultValue: 0, unit: .percent),

        .init(param: .brightness, identifier: "brightness", name: "Brightness", range: 0...100,
              defaultValue: 52, unit: .percent),
        .init(param: .warmth, identifier: "warmth", name: "Warmth", range: 0...100,
              defaultValue: 55, unit: .percent),
        .init(param: .presence, identifier: "presence", name: "Presence Cut", range: 0...100,
              defaultValue: 60, unit: .percent),
        .init(param: .air, identifier: "air", name: "Air", range: 0...100,
              defaultValue: 40, unit: .percent),
        .init(param: .drive, identifier: "drive", name: "Saturation", range: 0...100,
              defaultValue: 28, unit: .percent),

        .init(param: .decay, identifier: "decay", name: "Decay", range: 1...32,
              defaultValue: 14, unit: .seconds, exponential: true),
        .init(param: .wet, identifier: "wet", name: "Wet", range: 0...100,
              defaultValue: 42, unit: .percent),
        .init(param: .damping, identifier: "damping", name: "Damping", range: 0...100,
              defaultValue: 45, unit: .percent),
        .init(param: .size, identifier: "size", name: "Size", range: 0.6...1.7,
              defaultValue: 1.15, unit: .generic),
        .init(param: .width, identifier: "width", name: "Width", range: 0...2,
              defaultValue: 1.25, unit: .generic),
        .init(param: .fieldDrift, identifier: "fieldDrift", name: "Field Drift", range: 0...100,
              defaultValue: 50, unit: .percent),

        .init(param: .accentAttack, identifier: "accentAttack", name: "Accent Attack", range: 0.005...0.5,
              defaultValue: 0.035, unit: .seconds, exponential: true),
        .init(param: .accentDecay, identifier: "accentDecay", name: "Accent Decay", range: 0.1...8,
              defaultValue: 1.4, unit: .seconds, exponential: true),
        .init(param: .glide, identifier: "glide", name: "Glide", range: 0.05...10,
              defaultValue: 0.55, unit: .seconds, exponential: true),
        .init(param: .morph, identifier: "morph", name: "Morph", range: 0.5...30,
              defaultValue: 14, unit: .seconds, exponential: true),
        .init(param: .output, identifier: "output", name: "Output", range: 0...100,
              defaultValue: 85, unit: .percent),

        // Flow: the instrument playing itself. Mode is what it moves between —
        // played notes don't use it, since a keyboard already says which notes.
        .init(param: .flow, identifier: "flow", name: "Flow", range: 0...1,
              defaultValue: 0, unit: .indexed, values: ["Off", "On"]),
        .init(param: .mode, identifier: "mode", name: "Mode", range: 0...Double(ModeCatalog.all.count - 1),
              defaultValue: 1, unit: .indexed, values: ModeCatalog.all.map(\.name)),
    ]

    static func spec(_ p: ThrumParam) -> ThrumParamSpec { all[Int(p.rawValue)] }

    // MARK: Slider mapping

    func normalized(_ v: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        guard hi > lo else { return 0 }
        let x = min(max(v, lo), hi)
        return exponential && lo > 0 ? log(x / lo) / log(hi / lo) : (x - lo) / (hi - lo)
    }

    func value(fromNormalized n: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        let t = min(max(n, 0), 1)
        let v = exponential && lo > 0 ? lo * pow(hi / lo, t) : lo + (hi - lo) * t
        return values != nil ? v.rounded() : v
    }

    func display(_ v: Double) -> String {
        if let values { return values[min(max(Int(v.rounded()), 0), values.count - 1)] }
        switch unit {
        case .percent: return "\(Int(v.rounded()))%"
        case .hertz:   return String(format: "%.1f Hz", v)
        case .seconds:
            return v < 0.1 ? "\(Int((v * 1000).rounded())) ms"
                 : v < 10 ? String(format: "%.2f s", v) : String(format: "%.1f s", v)
        default:       return String(format: "%.2f", v)
        }
    }

    // MARK: Tree

    static func makeTree() -> AUParameterTree {
        let params = all.map { s -> AUParameter in
            var flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
            if s.exponential { flags.insert(.flag_DisplayLogarithmic) }
            if s.values == nil { flags.insert(.flag_CanRamp) }
            let p = AUParameterTree.createParameter(
                withIdentifier: s.identifier, name: s.name, address: s.param.rawValue,
                min: AUValue(s.range.lowerBound), max: AUValue(s.range.upperBound),
                unit: s.unit, unitName: nil, flags: flags,
                valueStrings: s.values, dependentParameters: nil)
            p.value = AUValue(s.defaultValue)
            return p
        }
        return AUParameterTree.createTree(withChildren: params)
    }
}

/// Factory presets: one per timbre, everything else at home. The timbre is most
/// of the character, and a preset that also moved twenty other controls would
/// be hard to hear the timbre in. Tanpura gets a second, accented reading —
/// a tanpura is plucked, and played from an arpeggiator that is the version of
/// it that sounds like one.
enum ThrumPresets {
    struct Preset {
        let name: String
        let values: [ThrumParam: Double]
    }

    static let all: [Preset] = {
        var out = TimbreCatalog.all.map { Preset(name: $0.name, values: [.timbre: Double($0.id)]) }
        if let tanpura = TimbreCatalog.all.firstIndex(where: { $0.name == "Tanpura" }) {
            out.append(Preset(name: "Tanpura — Plucked", values: [
                .timbre: Double(tanpura), .articulation: 1, .accentDecay: 3.2, .sitar: 45,
            ]))
        }
        out.append(Preset(name: "Flow", values: [.flow: 1]))
        return out
    }()
}
