import Foundation

/// What the listener actually likes.
///
/// Flow chooses freely — a key, a mode, a temperament, a timbre, a voicing and two
/// dozen sliders, all drifting on unrelated clocks. That is the right default and
/// it is also indiscriminate: it has no idea that this person loves the Gyütö
/// voicing in 19-TET and cannot stand Glass Choir. Two buttons fix that, and this
/// file is what sits behind them.
///
/// **The hard part is not storing the votes, it is deciding what they were about.**
/// A thumbs-up arrives with no explanation. At that moment perhaps thirty things
/// are true of the drone at once, and the listener liked *some* of them. So a vote
/// is not recorded against "the drone" — there is no such object to keep — but
/// spread across every quality that was audible when it was cast. One vote
/// therefore says almost nothing. Fifty of them say a great deal, because the
/// qualities that keep turning up in liked drones accumulate and the ones that
/// happened to be along for the ride appear on both sides of the ledger and cancel.
/// That is the whole mechanism: no vote is ever interpreted, and the noise is left
/// to average itself out.
///
/// Three consequences worth stating, because each is a decision that could have
/// gone the other way:
///
/// - **Nothing is ever ruled out.** A disliked timbre becomes rare, not
///   unreachable — every weight has a floor. Thrum's whole premise is that
///   nothing repeats, and a catalogue pruned down to a favourite handful is a
///   worse instrument even if every remaining item scores well. It also leaves
///   the door open to changing your mind, which a hard exclusion cannot: a trait
///   that can never be chosen can never be re-rated.
/// - **An untaught Taste is invisible.** Every weight is 1.0 and every roam band
///   comes back exactly as it went in, so a fresh install behaves identically to
///   the app before this existed. The feature has to earn its influence.
/// - **Old votes fade.** Taste in a drone is not a fact about a person, it is
///   where they are this year. A 150-day half-life means a strong old opinion
///   still counts for something and can still be overturned by a handful of
///   recent ones.
/// `@MainActor` to match `ThrumModel`, which owns it and whose `ParamSpec` curves
/// this needs to normalize through. Only the file write leaves the main thread.
@MainActor
public final class Taste: ObservableObject {

    public enum Vote: String, Sendable {
        case up, down
    }

    /// The qualities a vote can be about. Deliberately only the *discrete* ones —
    /// the continuous controls are handled separately below, because "you like
    /// Brightness" is meaningless and "you like Brightness around here" is not.
    public enum TraitKind: String, CaseIterable, Codable, Sendable {
        case key, mode, tuning, timbre, voicing

        /// For the one line of text that tells the listener what has been learned.
        /// Without it the database is a black box that quietly changes the music,
        /// which is indistinguishable from the app drifting for no reason.
        public func label(_ index: Int) -> String {
            switch self {
            case .key:     return Pitch.name(index)
            case .mode:    return index < ModeCatalog.all.count ? ModeCatalog.all[index].name : "?"
            case .tuning:  return TuningSystem(rawValue: index)?.name ?? "?"
            case .timbre:  return index < TimbreCatalog.all.count ? TimbreCatalog.all[index].name : "?"
            case .voicing:
                let all = ThrumModel.Voicing.allCases
                return index < all.count ? all[index].rawValue : "?"
            }
        }
    }

    /// Everything that was true of the drone when a button was pressed.
    public struct Snapshot: Sendable {
        /// A discrete quality and how much of the vote it may take.
        public struct Trait: Sendable {
            public let value: Int
            /// 0…1. Below one for a quality that has only just arrived — see
            /// `Taste.credit(dwell:)`.
            public let credit: Double
            public init(value: Int, credit: Double) {
                self.value = value
                self.credit = credit
            }
        }

        public var traits: [TraitKind: Trait] = [:]
        /// Continuous controls, normalized 0…1 *through their own curve*, so an
        /// exponential control like Decay is learned in the space its slider
        /// actually moves in rather than in seconds.
        public var params: [Param: Double] = [:]

        public init() {}
    }

    // MARK: - Stored form

    /// Up and down weight for one discrete value, plus when it was last touched
    /// so it can be decayed lazily rather than swept.
    private struct Tally: Codable {
        var up: Double = 0
        var down: Double = 0
        var updated: Double = 0
    }

    /// One continuous control's history: where the liked drones sat, how tightly,
    /// and where the disliked ones sat.
    ///
    /// Weighted running mean and variance (West's algorithm), which is what lets
    /// this be a fixed twenty-odd bytes per control instead of a list of every
    /// vote ever cast — and lets decay be a multiplication rather than a re-scan.
    private struct Field: Codable {
        var upWeight: Double = 0
        var upMean: Double = 0.5
        var upM2: Double = 0
        var downWeight: Double = 0
        var downMean: Double = 0.5
        var updated: Double = 0
    }

    private struct Book: Codable {
        var version = 1
        /// Keyed `"mode/5"` — a string rather than a nested dictionary so the file
        /// stays readable and adding a trait kind cannot invalidate the old ones.
        var traits: [String: Tally] = [:]
        /// Keyed by `Param.slug`, which is spelled out by hand for exactly this
        /// reason: `Param` is an `Int` enum and reordering its cases would
        /// otherwise silently reassign every learned preference to a different
        /// control.
        var params: [String: Field] = [:]
        var ups = 0
        var downs = 0
    }

    private var book = Book()

    // MARK: - Constants

    /// Additive smoothing on the discrete score. This is the number that decides
    /// how loud one vote is: at 2.5, a single thumbs-up scores 0.29 and lifts that
    /// trait's odds by about 45% — noticeable in a session, nowhere near decisive.
    private static let smoothing = 2.5

    /// Score → weight is `exp(score · strength)`. At full ±1 that is a 3.5× and a
    /// 0.29×, which against a twelve-item catalogue is a strong lean and not a
    /// verdict.
    private static let strength = 1.3

    /// No weight ever goes below this, whatever the score. See the note at the top
    /// about never ruling anything out.
    private static let weightFloor = 0.18
    private static let weightCeiling = 3.4

    /// How long a strong opinion takes to lose half its say.
    public static let halfLife: Double = 150 * 86_400

    /// A quality that changed less than this long ago has probably not finished
    /// arriving — Flow's ramps are 20–90 seconds and its glides 7.5 — so it takes
    /// only partial credit for what you just reacted to.
    private static let settleSeconds: Double = 12
    private static let minimumCredit = 0.35

    // MARK: - Published surface

    @Published public private(set) var ups = 0
    @Published public private(set) var downs = 0
    /// One line naming the strongest leanings, or empty until there is something
    /// honest to say.
    @Published public private(set) var summary = ""

    public var isEmpty: Bool { ups == 0 && downs == 0 }

    // MARK: - Life

    private let store: URL?
    private let now: () -> Double
    private let io = DispatchQueue(label: "com.jeffhobbs.thrum.taste", qos: .utility)

    /// - Parameters:
    ///   - store: where to keep the file, or `nil` for a database that lives only
    ///     as long as the process. **`nil` is the default on purpose**: a model
    ///     built by the offline harnesses must not read the real listener's taste,
    ///     or `Tools/flow` stops measuring Flow and starts measuring Flow plus
    ///     whatever was liked last Tuesday. The app hosts opt in explicitly.
    ///   - now: injectable clock, so decay is testable in a second rather than
    ///     over five months.
    public init(store: URL? = nil, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store
        self.now = now
        load()
    }

    /// `~/Library/Application Support/Thrum/taste.json` — the container's copy of
    /// it on iOS. A file rather than `UserDefaults` because this is an accumulating
    /// record with a schema, and because it should be possible to look at it.
    public static var defaultStore: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Thrum/taste.json")
    }

    private func load() {
        guard let store, let data = try? Data(contentsOf: store),
              let decoded = try? JSONDecoder().decode(Book.self, from: data) else { return }
        book = decoded
        ups = decoded.ups
        downs = decoded.downs
        rebuildSummary()
    }

    private func persist() {
        guard let store, let data = try? JSONEncoder().encode(book) else { return }
        io.async {
            let folder = store.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: store, options: .atomic)
        }
    }

    /// Start over. A system that silently reshapes the music forever needs a way
    /// back, if only because a few votes cast while testing something are
    /// otherwise permanent.
    public func forget() {
        book = Book()
        ups = 0
        downs = 0
        summary = ""
        persist()
    }

    // MARK: - Recording

    public func record(_ vote: Vote, _ snapshot: Snapshot) {
        let t = now()

        for (kind, trait) in snapshot.traits {
            let key = Self.key(kind, trait.value)
            var tally = book.traits[key] ?? Tally(up: 0, down: 0, updated: t)
            let k = Self.decayFactor(from: tally.updated, to: t)
            tally.up *= k
            tally.down *= k
            let credit = max(0, min(1, trait.credit))
            if vote == .up { tally.up += credit } else { tally.down += credit }
            tally.updated = t
            book.traits[key] = tally
        }

        for (param, value) in snapshot.params {
            let x = max(0, min(1, value))
            var field = book.params[param.slug] ?? Field(updated: t)
            let k = Self.decayFactor(from: field.updated, to: t)
            field.upWeight *= k
            field.upM2 *= k
            field.downWeight *= k
            // A control is always somewhere, and where it is *is* what you heard,
            // so unlike a discrete quality there is no partial credit here.
            if vote == .up {
                field.upWeight += 1
                let delta = x - field.upMean
                field.upMean += delta / field.upWeight
                field.upM2 += delta * (x - field.upMean)
            } else {
                field.downWeight += 1
                field.downMean += (x - field.downMean) / field.downWeight
            }
            field.updated = t
            book.params[param.slug] = field
        }

        if vote == .up { book.ups += 1 } else { book.downs += 1 }
        ups = book.ups
        downs = book.downs
        rebuildSummary()
        persist()
    }

    /// How much of a vote a quality may take, given how long it has been in place.
    ///
    /// Not a fairness rule — a correction for the instrument. Flow's changes arrive
    /// over ramps and glides measured in tens of seconds, so a mode that turned
    /// over four seconds ago is still audibly on its way and is not really what
    /// prompted the button. The floor stops this from discounting the change that
    /// *did* prompt it: a listener who reaches for thumbs-down eight seconds into a
    /// new timbre is very likely reacting to the timbre.
    public static func credit(dwell: Double) -> Double {
        guard dwell.isFinite, dwell > 0 else { return minimumCredit }
        return max(minimumCredit, min(1, dwell / settleSeconds))
    }

    // MARK: - Reading: discrete qualities

    /// −1…1. Zero for anything never voted on, which is what makes an untaught
    /// Taste a no-op rather than a random nudge.
    public func score(_ kind: TraitKind, _ index: Int) -> Double {
        guard let tally = book.traits[Self.key(kind, index)] else { return 0 }
        let k = Self.decayFactor(from: tally.updated, to: now())
        let up = tally.up * k
        let down = tally.down * k
        return (up - down) / (up + down + Self.smoothing)
    }

    /// Total evidence about one value, after decay. Used to tell "disliked" from
    /// "never heard".
    public func evidence(_ kind: TraitKind, _ index: Int) -> Double {
        guard let tally = book.traits[Self.key(kind, index)] else { return 0 }
        let k = Self.decayFactor(from: tally.updated, to: now())
        return (tally.up + tally.down) * k
    }

    /// Multiplier for a weighted draw. 1.0 means "no opinion", and every value
    /// keeps a floor so nothing disappears from the instrument.
    public func weight(_ kind: TraitKind, _ index: Int) -> Double {
        let w = exp(score(kind, index) * Self.strength)
        return max(Self.weightFloor, min(Self.weightCeiling, w))
    }

    public func weights(_ kind: TraitKind, _ indices: [Int]) -> [Double] {
        indices.map { weight(kind, $0) }
    }

    // MARK: - Reading: continuous controls

    /// Narrow a roam band toward where the liked drones sat.
    ///
    /// Bounds go in and come out in the control's own units; the work happens in
    /// normalized space so an exponential control is learned the way its slider
    /// moves. Three properties this has to keep, all checked by `Tools/taste`:
    ///
    /// - With no history it returns `roam` **exactly**, so Flow is untouched until
    ///   taught.
    /// - It never returns a band narrower than a third of the one it was given.
    ///   Flow's promise is that something is always moving; a control learned into
    ///   a single point is a control that has stopped, and thirty of those is a
    ///   patch rather than a drift.
    /// - It stays inside `roam`. Those bounds are the ranges that are *pleasant for
    ///   an hour*, and a hundred thumbs-up cannot make Flow push Presence Cut
    ///   below its anti-fatigue floor.
    public func band(_ p: Param, within roam: (low: Double, high: Double)) -> (low: Double, high: Double) {
        let spec = ThrumModel.spec(p)
        let lo = spec.normalized(min(roam.low, roam.high))
        let hi = spec.normalized(max(roam.low, roam.high))
        guard hi - lo > 1e-6, let field = book.params[p.slug] else { return roam }

        let k = Self.decayFactor(from: field.updated, to: now())
        let upW = field.upWeight * k
        let downW = field.downWeight * k

        var centre: Double
        var confidence: Double
        var spread: Double

        if upW >= 1 {
            centre = field.upMean
            confidence = min(0.85, upW / (upW + 3))
            spread = sqrt(max(0, field.upM2 * k) / upW)
            // Lean away from where the disliked ones sat, but only while the two
            // are close enough for it to mean anything — if liked and disliked
            // cluster in the same place, this control simply is not the reason and
            // the push correctly goes to zero.
            if downW >= 1 {
                let separation = centre - field.downMean
                let overlap = 1 - min(1, abs(separation) / 0.4)
                let push = 0.18 * (downW / (downW + 3)) * overlap
                centre += separation >= 0 ? push : -push
            }
        } else if downW >= 2 {
            // Down votes alone say where *not* to be and nothing about where to go,
            // so the best available guess is the far side — held at low confidence
            // because it is a guess.
            centre = 1 - field.downMean
            confidence = min(0.30, downW / (downW + 6))
            spread = 0.30
        } else {
            return roam
        }

        centre = max(0, min(1, centre))
        let half = max(0.10, min(0.40, spread * 1.4))
        let fullWidth = hi - lo
        let floorWidth = min(fullWidth, max(0.05, fullWidth * 0.35))

        var targetLo = max(lo, centre - half)
        var targetHi = min(hi, centre + half)
        if targetHi - targetLo < floorWidth {
            if centre <= lo {
                targetLo = lo
                targetHi = lo + floorWidth
            } else if centre >= hi {
                targetHi = hi
                targetLo = hi - floorWidth
            } else {
                let mid = min(max(centre, lo + floorWidth / 2), hi - floorWidth / 2)
                targetLo = mid - floorWidth / 2
                targetHi = mid + floorWidth / 2
            }
        }

        // Confidence interpolates between "the whole band" and "the learned band",
        // which is why an early vote moves things a little and fifty move them a lot.
        let newLo = lo + (targetLo - lo) * confidence
        let newHi = hi + (targetHi - hi) * confidence
        return (spec.value(fromNormalized: newLo), spec.value(fromNormalized: newHi))
    }

    // MARK: - Summary

    private func rebuildSummary() {
        var liked: [(String, Double)] = []
        var disliked: [(String, Double)] = []
        for kind in TraitKind.allCases {
            for index in Self.range(kind) {
                guard evidence(kind, index) >= 2 else { continue }
                let s = score(kind, index)
                if s > 0.12 { liked.append((kind.label(index), s)) }
                if s < -0.12 { disliked.append((kind.label(index), -s)) }
            }
        }
        liked.sort { $0.1 > $1.1 }
        disliked.sort { $0.1 > $1.1 }

        var parts: [String] = []
        if !liked.isEmpty {
            parts.append("toward " + liked.prefix(3).map(\.0).joined(separator: ", "))
        }
        if !disliked.isEmpty {
            parts.append("away from " + disliked.prefix(2).map(\.0).joined(separator: ", "))
        }
        summary = parts.isEmpty ? "" : "leaning " + parts.joined(separator: " · ")
    }

    /// The valid indices of each trait kind, for the summary sweep.
    private static func range(_ kind: TraitKind) -> Range<Int> {
        switch kind {
        case .key:     return 0..<12
        case .mode:    return 0..<ModeCatalog.all.count
        case .tuning:  return 0..<TuningSystem.allCases.count
        case .timbre:  return 0..<TimbreCatalog.all.count
        case .voicing: return 0..<ThrumModel.Voicing.allCases.count
        }
    }

    // MARK: - Plumbing

    private static func key(_ kind: TraitKind, _ index: Int) -> String {
        "\(kind.rawValue)/\(index)"
    }

    private static func decayFactor(from: Double, to: Double) -> Double {
        let dt = to - from
        guard dt > 0, dt.isFinite else { return 1 }
        return pow(0.5, dt / halfLife)
    }
}

// MARK: - Stable names for the controls

extension Param {
    /// A name that outlives a reordering of the enum.
    ///
    /// `Param` is an `Int`-backed enum and its raw values are positional, so
    /// storing preferences under them means inserting one case in the middle
    /// quietly reassigns every learned band to the wrong control — a bug that
    /// would present as "the app forgot, and also got worse". A switch rather than
    /// a dictionary so the compiler refuses to let a new control go unnamed.
    var slug: String {
        switch self {
        case .swell:        return "swell"
        case .fade:         return "fade"
        case .beating:      return "beating"
        case .drift:        return "drift"
        case .motion:       return "motion"
        case .sitarDepth:   return "sitar-depth"
        case .padLevel:     return "pad-level"
        case .brightness:   return "brightness"
        case .warmth:       return "warmth"
        case .presence:     return "presence"
        case .air:          return "air"
        case .drive:        return "drive"
        case .reverbDecay:  return "reverb-decay"
        case .reverbMix:    return "reverb-mix"
        case .reverbDamp:   return "reverb-damp"
        case .reverbSize:   return "reverb-size"
        case .width:        return "width"
        case .spatialDrift: return "spatial-drift"
        case .globalSwell:  return "global-swell"
        case .masterVolume: return "master-volume"
        case .tempo:        return "tempo"
        case .pluckAttack:  return "pluck-attack"
        case .pluckDecay:   return "pluck-decay"
        case .arpLevel:     return "arp-level"
        case .swing:        return "swing"
        case .humanize:     return "humanize"
        case .fieldRadius:  return "field-radius"
        case .fieldLift:    return "field-lift"
        }
    }
}
