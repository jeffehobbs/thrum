import Foundation
import Combine

/// Novation Launch Control / Launch Control XL / Launch Control XL 3.
///
/// Nothing is asked of the player: plug in, and the knobs land on Thrum's
/// parameters in a sensible default order (the same order the app shows them).
/// Anything you'd rather have somewhere else, you re-learn from the app.
///
/// Three details that matter live:
///  * **Soft takeover.** A knob does nothing until it passes through the
///    parameter's current value, so grabbing a knob never jumps the sound.
///  * **Templates.** These devices ship several templates with different CCs.
///    The defaults below are the factory template; learn overrides them and
///    persists, so a different template is one pass through the panel away.
///  * **Generations differ.** Not just in CC numbers — the XL 3 also renames its
///    ports past recognition and sends CC where the others send note-on.
@MainActor
final class LaunchControlController: ObservableObject {
    private unowned let model: ThrumModel
    private var surface: MIDISurface!

    /// CC number → parameter.
    @Published private(set) var mapping: [Int: Param] = [:]
    /// Parameter waiting to be bound to the next knob that moves.
    @Published var learning: Param?

    /// Knobs that haven't yet passed through their parameter's value.
    private var takenOver: Set<Int> = []
    private var lastKnob: [Int: Double] = [:]
    /// Set on connect — the XL 3 needs a different CC map *and* a different
    /// button convention from its predecessors.
    private var isXL3 = false

    private static let defaultsKey = "ThrumLaunchControlMap"

    /// Factory-template CCs, in physical order: knob rows top to bottom, then
    /// the faders. Every generation numbers them differently.
    private static let xlCCs: [Int] = Array(13...20) + Array(29...36) + Array(49...56) + Array(77...84)
    private static let miniCCs: [Int] = Array(21...28) + Array(41...48)
    /// XL 3, measured from the hardware 2026-08-24 rather than taken from the
    /// docs: its knob rows are contiguous (13–36, where the older XL skipped to
    /// 49–56 for the third row) and its faders sit *below* the knobs at 5–12.
    private static let xl3CCs: [Int] = Array(13...20) + Array(21...28) + Array(29...36) + Array(5...12)
    /// The XL 3's buttons send CC at value 127, not note-on like every earlier
    /// model, so they need routing into the pad handler by hand. Kept to the
    /// range actually measured: a CC that lands here fires a voicing — or the
    /// panic — so guessing wide would risk phantom presses from some control
    /// this has never seen. Widen it if more buttons turn up.
    private static let xl3ButtonCCs = 37...47

    /// The order knobs get assigned in — matches how the app groups them, so
    /// the top row of the hardware is the top group on screen.
    private static let assignOrder: [Param] = [
        .swell, .fade, .beating, .drift, .motion, .sitarDepth, .padLevel, .globalSwell,
        .brightness, .warmth, .presence, .air, .drive, .width, .spatialDrift, .masterVolume,
        .reverbDecay, .reverbMix, .reverbDamp, .reverbSize,
        .tempo, .pluckAttack, .pluckDecay, .arpLevel, .swing, .humanize,
        .fieldRadius, .fieldLift,
    ]

    init(model: ThrumModel) {
        self.model = model
        surface = MIDISurface(
            clientName: "ThrumLC",
            deviceNames: ["Launch Control", "LCXL", "Launchpad Control XL"],
            portHint: "MIDI",
            onConnect: { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    self.model.launchControlConnected = ok
                    if ok {
                        self.buildDefaultMapping()
                        self.takenOver.removeAll()
                        self.model.show("\(self.surface.connectedName) connected — \(self.mapping.count) knobs mapped")
                    }
                }
            },
            onMessage: { [weak self] messages in
                Task { @MainActor in
                    for m in messages { self?.handle(m) }
                }
            })
        loadMapping()
    }

    // MARK: - Mapping

    private func buildDefaultMapping() {
        // The generation has to be read even when a learned map wins, because it
        // also decides how the buttons are decoded.
        let name = surface.connectedName
        // The older models report "Launch Control" and the XL appends " XL", but
        // the XL 3 reports neither — it names its ports "LCXL3 1 MIDI Out".
        isXL3 = name.localizedCaseInsensitiveContains("LCXL3")
            || name.localizedCaseInsensitiveContains("XL 3")
        guard mapping.isEmpty else { return }  // a learned map wins
        let ccs: [Int]
        if isXL3 {
            ccs = Self.xl3CCs
        } else if name.localizedCaseInsensitiveContains("XL") {
            ccs = Self.xlCCs
        } else {
            ccs = Self.miniCCs
        }
        for (i, param) in Self.assignOrder.enumerated() where i < ccs.count {
            mapping[ccs[i]] = param
        }
    }

    func beginLearning(_ param: Param) {
        learning = param
        model.show("Move a knob to bind it to \(ThrumModel.spec(param).name)")
    }

    func cancelLearning() { learning = nil }

    func clearMapping() {
        mapping.removeAll()
        takenOver.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        buildDefaultMapping()
        model.show("Launch Control map reset to the factory layout")
    }

    private func saveMapping() {
        let dict = mapping.reduce(into: [String: Int]()) { $0["\($1.key)"] = $1.value.rawValue }
        UserDefaults.standard.set(dict, forKey: Self.defaultsKey)
    }

    private func loadMapping() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Int] else { return }
        for (k, v) in dict {
            if let cc = Int(k), let p = Param(rawValue: v) { mapping[cc] = p }
        }
    }

    // MARK: - Input

    private func handle(_ m: MIDISurface.Message) {
        switch m.kind {
        case .control:
            // XL 3 buttons arrive as CC. Learning still comes first, so a button
            // can be bound deliberately, but otherwise they act as pads.
            if isXL3, learning == nil, Self.xl3ButtonCCs.contains(m.data1) {
                if m.data2 > 0 { pad(note: m.data1 - Self.xl3ButtonCCs.lowerBound) }
                return
            }
            knob(cc: m.data1, value: m.data2)
        case .noteOn:
            pad(note: m.data1)
        default:
            break
        }
    }

    private func knob(cc: Int, value: Int) {
        let x = Double(value) / 127.0

        if let param = learning {
            mapping = mapping.filter { $0.value != param }  // one knob per parameter
            mapping[cc] = param
            learning = nil
            takenOver.insert(cc)
            saveMapping()
            model.show("\(ThrumModel.spec(param).name) → CC \(cc)")
            return
        }

        guard let param = mapping[cc] else { return }
        let spec = ThrumModel.spec(param)
        let current = spec.normalized(model.value(param))

        // Soft takeover: ignore the knob until it crosses where the value is.
        if !takenOver.contains(cc) {
            if let previous = lastKnob[cc] {
                let crossed = (previous - current) * (x - current) <= 0
                if crossed || abs(x - current) < 0.02 {
                    takenOver.insert(cc)
                } else {
                    lastKnob[cc] = x
                    return
                }
            } else {
                lastKnob[cc] = x
                if abs(x - current) < 0.02 { takenOver.insert(cc) } else { return }
            }
        }

        lastKnob[cc] = x
        model.setNormalized(param, x)
    }

    /// The pads/buttons trigger voicings — the things you actually want a
    /// button for mid-performance.
    private func pad(note: Int) {
        let voicings = ThrumModel.Voicing.allCases
        // Factory template pads are contiguous per row; fold whatever arrives
        // into the first six voicings plus the two ways out. Capped at six on
        // purpose — there are fifteen voicings now, and letting them fill all
        // eight pads would cost the panic button, which has to stay reachable.
        let slot = note % 8
        switch slot {
        case 6: model.fadeAll()
        case 7: model.panic()
        default:
            if slot < voicings.count { model.apply(voicings[slot]) }
        }
    }

    /// What the app shows next to each parameter.
    func ccLabel(for param: Param) -> String? {
        guard let cc = mapping.first(where: { $0.value == param })?.key else { return nil }
        return "CC \(cc)"
    }
}
