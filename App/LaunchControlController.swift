import Foundation
import Combine

/// Novation Launch Control / Launch Control XL.
///
/// The hardware isn't here yet, so this is written to need nothing from the
/// player when it does arrive: plug it in, and its knobs land on Thrum's
/// parameters in a sensible default order (the same order the app shows them).
/// Anything you'd rather have somewhere else, you re-learn from the app.
///
/// Two details that matter live:
///  * **Soft takeover.** A knob does nothing until it passes through the
///    parameter's current value, so grabbing a knob never jumps the sound.
///  * **Templates.** Both devices ship several templates with different CCs.
///    The defaults below are the factory template; learn overrides them and
///    persists, so a different template is one pass through the panel away.
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

    private static let defaultsKey = "ThrumLaunchControlMap"

    /// Factory-template CCs, in physical order.
    private static let xlCCs: [Int] = Array(13...20) + Array(29...36) + Array(49...56) + Array(77...84)
    private static let miniCCs: [Int] = Array(21...28) + Array(41...48)

    /// The order knobs get assigned in — matches how the app groups them, so
    /// the top row of the hardware is the top group on screen.
    private static let assignOrder: [Param] = [
        .swell, .fade, .beating, .drift, .motion, .sitarDepth, .padLevel, .globalSwell,
        .brightness, .warmth, .presence, .air, .drive, .width, .spatialDrift, .masterVolume,
        .reverbDecay, .reverbMix, .reverbDamp, .reverbSize,
        .tempo, .pluckAttack, .pluckDecay, .arpLevel, .swing, .humanize,
    ]

    init(model: ThrumModel) {
        self.model = model
        surface = MIDISurface(
            clientName: "ThrumLC", deviceName: "Launch Control",
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
        guard mapping.isEmpty else { return }  // a learned map wins
        // Both models report "Launch Control"; the XL appends " XL", and it has
        // twice the knobs on entirely different CCs.
        let isXL = surface.connectedName.localizedCaseInsensitiveContains("XL")
        let ccs = isXL ? Self.xlCCs : Self.miniCCs
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
