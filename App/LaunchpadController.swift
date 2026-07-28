import Foundation
import CoreMIDI
import Combine

/// Novation Launchpad X, programmer mode, every key in use.
///
/// ```
///   ◀KEY KEY▶ ◀OCT OCT▶ BANK TIMB TUNE PANIC     ← top row (CC 91–98)
///  ┌───────────────────────────────────────┐ ▓   ← right column (CC 89…19)
///  │ 8  tones — octave +3                  │ ▓      is a master-level ladder
///  │ 7  tones — octave +2                  │ ▓
///  │ 6  tones — octave +1                  │ ▓
///  │ 5  tones — octave  0  (lowest)        │ ▓
///  │ 4  timbre  1…8                        │ ▓
///  │ 3  tuning  1…8                        │ ▓
///  │ 2  sitar swell bloom air drift wide … │ ▓
///  │ 1  mode  1…8  (of the current bank)   │ ▓
///  └───────────────────────────────────────┘
/// ```
///
/// Tone pads: tap toggles the tone in or out; press *into* the pad and its
/// aftertouch rides that tone's level. Row 2 pads are all hold-and-press
/// modifiers — they push a parameter while held and restore it on release —
/// except SITAR, which turns tone pads into jawari toggles while held.
///
/// **Hold BANK** and the whole board becomes the arpeggiator page. Nothing is
/// taken away to make room for it: tapping BANK still cycles the mode bank,
/// and it only cycles if you let go without having pressed anything else.
///
/// ```
///   BPM− BPM+ BPM−5 BPM+5 [BANK] TAP SWING PANIC
///  ┌────────────────────────────────────────────┐
///  │ 8  lane 4 — rate ×½ … ×6                   │
///  │ 7  lane 3 — rate                           │
///  │ 6  lane 2 — rate                           │
///  │ 5  lane 1 — rate  (press the lit one = off)│
///  │ 4  pattern ×4 · register ×4                │
///  │ 3  offset  ×4 · source   ×4                │
///  │ 2  tap run off align ÷2 ×2 swing unsteady  │
///  │ 1  presets 1…8                             │
///  └────────────────────────────────────────────┘
/// ```
@MainActor
final class LaunchpadController {
    private unowned let model: ThrumModel
    private var surface: LaunchpadSurface!
    private var cancellable: AnyCancellable?
    private var repaintTimer: Timer?

    private var lastToneMessage: [UInt8]?
    private var lastControlMessage: [UInt8]?
    private var lastButtonMessage: [UInt8]?

    // Row 2 modifiers, left to right.
    private enum Modifier: Int, CaseIterable {
        case sitar = 21, swell = 22, bloom = 23, air = 24
        case drift = 25, wide = 26, drive = 27, letGo = 28

        var label: String {
            switch self {
            case .sitar: return "Jawari — tap a tone to arm its sitar"
            case .swell: return "Swell ride — press to bring the whole drone up"
            case .bloom: return "Bloom — press to open the reverb"
            case .air:   return "Air — press to brighten"
            case .drift: return "Drift — press for more wander"
            case .wide:  return "Wide — press to open the field"
            case .drive: return "Saturate — press for more overtones"
            case .letGo: return "Let go (tap) / cut short (press) / hold + tap a tone to drop just that one"
            }
        }
        var hue: Double {
            switch self {
            case .sitar: return 0.86
            case .swell: return 0.12
            case .bloom: return 0.55
            case .air:   return 0.48
            case .drift: return 0.72
            case .wide:  return 0.60
            case .drive: return 0.04
            case .letGo: return 0.00
            }
        }
    }

    private enum Top: Int, CaseIterable {
        case keyDown = 91, keyUp = 92, octaveDown = 93, octaveUp = 94
        case bank = 95, timbre = 96, tuning = 97, panic = 98
    }

    /// Right-hand column, top (loudest) to bottom (silent).
    private static let ladder = [89, 79, 69, 59, 49, 39, 29, 19]
    private static let logo = 99

    private var held: Set<Int> = []
    private var pressStart: [Int: Date] = [:]
    private var gestured: Set<Int> = []
    /// Set when LET GO was used to drop individual tones, so releasing it
    /// doesn't also let go of everything.
    private var letGoDroppedTones = false
    /// Top-row and right-column buttons currently down.
    private var heldCC: Set<Int> = []
    /// Same idea as `letGoDroppedTones`: BANK only cycles the mode bank if you
    /// let go of it without having used the arp page underneath.
    private var bankUsedAsPage = false
    /// True while BANK is held — the board is showing the arpeggiator.
    private var arpPage: Bool { heldCC.contains(Top.bank.rawValue) }
    /// Base values stashed while a modifier is pushing a parameter.
    private var pushBase: [Param: Double] = [:]

    init(model: ThrumModel) {
        self.model = model
        surface = LaunchpadSurface(
            clientName: "Thrum", deviceName: "Launchpad X", portHint: "MIDI",
            onConnect: { [weak self] ok in
                Task { @MainActor in
                    self?.model.launchpadConnected = ok
                    if ok { self?.model.show("Launchpad X connected — 81 keys live") }
                }
            },
            onMessage: { [weak self] messages in
                Task { @MainActor in
                    for m in messages { self?.handle(m) }
                }
            })

        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.paint() }
            }

        // Tone LEDs follow the actual envelopes, so the grid literally swells
        // with the sound rather than snapping on at the tap.
        repaintTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.paint() }
        }
    }

    deinit {
        repaintTimer?.invalidate()
    }

    /// Hand the hardware back to whatever the player uses next.
    func shutdown() {
        repaintTimer?.invalidate()
        surface.willDisconnect()
    }

    // MARK: - Geometry

    /// Tone pad 0…31 (row 0 = lowest octave) → programmer-mode note.
    private static func toneNote(pad: Int) -> Int {
        let row = pad / Harmony.cols
        let col = pad % Harmony.cols
        return (5 + row) * 10 + col + 1
    }

    private static func pad(forNote note: Int) -> Int? {
        let row = note / 10
        let col = note % 10
        guard (5...8).contains(row), (1...8).contains(col) else { return nil }
        return (row - 5) * Harmony.cols + (col - 1)
    }

    // MARK: - Input

    private func handle(_ m: MIDISurface.Message) {
        switch m.kind {
        case .control:
            handleButton(cc: m.data1, value: m.data2)
        case .noteOn:
            held.insert(m.data1)
            pressStart[m.data1] = Date()
            gestured.remove(m.data1)
            handleGrid(note: m.data1, value: m.data2, phase: .down)
        case .noteOff:
            handleGrid(note: m.data1, value: m.data2, phase: .up)
            held.remove(m.data1)
        case .aftertouch:
            if m.data2 >= 16 { gestured.insert(m.data1) }
            handleGrid(note: m.data1, value: m.data2, phase: .pressure)
        }
    }

    private enum Phase { case down, up, pressure }

    private func isTap(_ note: Int) -> Bool {
        Date().timeIntervalSince(pressStart[note] ?? .distantPast) < 0.45 && !gestured.contains(note)
    }

    private func handleGrid(note: Int, value: Int, phase: Phase) {
        let frac = Double(value) / 127.0

        if arpPage {
            if phase == .down { handleArpGrid(note: note) }
            return
        }

        if let pad = Self.pad(forNote: note) {
            if held.contains(Modifier.sitar.rawValue) {
                if phase == .down { model.toggleSitar(pad: pad) }
                return
            }
            // LET GO as a modifier: an unambiguous per-tone kill that doesn't
            // depend on getting a tap light and quick enough to read as a tap.
            if held.contains(Modifier.letGo.rawValue) {
                if phase == .down {
                    letGoDroppedTones = true
                    if model.padOn[pad] {
                        model.release(pad: pad)
                        model.show("Dropping \(model.tones[pad].noteName)\(model.tones[pad].octave)")
                    }
                }
                return
            }
            switch phase {
            case .down:
                break  // decided on release: tap toggles, press rides
            case .pressure:
                if value >= 16 { model.setLevel(pad: pad, frac) }
            case .up:
                if isTap(note) {
                    model.toggle(pad: pad)
                } else {
                    // Leave it wherever the pressure left it, but never at zero
                    // — a ridden tone that lands on silence should just stop.
                    if model.padLevel[pad] < 0.03 { model.release(pad: pad) }
                }
            }
            return
        }

        let row = note / 10
        let col = note % 10 - 1
        guard (1...4).contains(row), (0...7).contains(col) else { return }

        switch row {
        case 4:
            if phase == .down { model.setTimbre(col) }
        case 3:
            if phase == .down, col < TuningSystem.allCases.count {
                model.setTuning(TuningSystem.allCases[col])
            }
        case 2:
            if let mod = Modifier(rawValue: note) { handleModifier(mod, frac: frac, phase: phase, note: note) }
        case 1:
            if phase == .down {
                let index = model.modeBank * ModeCatalog.bankSize + col
                if index < ModeCatalog.all.count { model.setMode(index) }
            }
        default:
            break
        }
    }

    /// The arpeggiator page, live only while BANK is held. Tone rows are the
    /// four lanes and their eight rates; the control rows are everything else
    /// a lane has, laid out four-and-four so lane N is always column N.
    private func handleArpGrid(note: Int) {
        bankUsedAsPage = true

        if let pad = Self.pad(forNote: note) {
            model.setLaneDivision(pad / Harmony.cols, pad % Harmony.cols)
            return
        }

        let row = note / 10
        let col = note % 10 - 1
        guard (1...4).contains(row), (0...7).contains(col) else { return }

        switch row {
        case 1:
            model.applyPulsePreset(col)
        case 2:
            switch col {
            case 0: model.tapTempo()
            case 1: model.togglePulse()
            case 2: model.allLanesOff()
            case 3: model.realignPulse()
            case 4: model.scaleTempo(0.5)
            case 5: model.scaleTempo(2.0)
            case 6: model.cycleSwing()
            default: model.cycleHumanize()
            }
        case 3:
            if col < 4 { model.nudgeLanePhase(col) } else { model.cycleLaneSource(col - 4) }
        case 4:
            if col < 4 { model.cycleLanePattern(col) } else { model.cycleLaneSpan(col - 4) }
        default:
            break
        }
    }

    private func handleModifier(_ mod: Modifier, frac: Double, phase: Phase, note: Int) {
        /// Push a parameter up from wherever the player left it, then put it back.
        func push(_ param: Param, to target: Double) {
            let base = pushBase[param] ?? model.value(param)
            pushBase[param] = base
            let spec = ThrumModel.spec(param)
            model.set(param, base + (target - base) * frac)
            _ = spec
        }
        func restore(_ params: Param...) {
            for p in params {
                if let base = pushBase[p] { model.set(p, base); pushBase[p] = nil }
            }
        }

        switch (mod, phase) {
        case (.sitar, .down):
            model.show(mod.label)
        case (.sitar, .pressure):
            model.set(.sitarDepth, 0.15 + 0.85 * frac)
        case (.sitar, .up):
            break

        case (.swell, .pressure):
            model.set(.globalSwell, 0.12 + 0.88 * frac)
        case (.swell, .up):
            model.set(.globalSwell, 1.0)
        case (.swell, .down):
            model.show(mod.label)

        case (.bloom, .pressure):
            push(.reverbMix, to: 0.92)
            push(.reverbSize, to: 1.7)
            push(.reverbDecay, to: 30)
        case (.bloom, .up):
            restore(.reverbMix, .reverbSize, .reverbDecay)
        case (.bloom, .down):
            model.show(mod.label)

        case (.air, .pressure):
            push(.brightness, to: 1.0)
            push(.air, to: 0.9)
        case (.air, .up):
            restore(.brightness, .air)
        case (.air, .down):
            model.show(mod.label)

        case (.drift, .pressure):
            push(.drift, to: 1.0)
            push(.motion, to: 1.0)
            push(.beating, to: 0.95)
        case (.drift, .up):
            restore(.drift, .motion, .beating)
        case (.drift, .down):
            model.show(mod.label)

        case (.wide, .pressure):
            push(.width, to: 2.0)
            push(.spatialDrift, to: 1.0)
        case (.wide, .up):
            restore(.width, .spatialDrift)
        case (.wide, .down):
            model.show(mod.label)

        case (.drive, .pressure):
            push(.drive, to: 0.95)
        case (.drive, .up):
            restore(.drive)
        case (.drive, .down):
            model.show(mod.label)

        case (.letGo, .down):
            letGoDroppedTones = false
            model.show(mod.label)
        case (.letGo, .pressure):
            if frac > 0.7 && !letGoDroppedTones { model.fadeAll(quick: true) }
        case (.letGo, .up):
            // Dropping individual tones consumes the press — otherwise lifting
            // off would take the rest of the drone with it.
            if isTap(note) && !letGoDroppedTones { model.fadeAll() }
        }
    }

    private func handleButton(cc: Int, value: Int) {
        // These send 127 down, 0 up. BANK is the one that cares about the
        // release, because holding it is the arp page.
        guard value > 0 else {
            heldCC.remove(cc)
            if cc == Top.bank.rawValue && !bankUsedAsPage { model.cycleModeBank() }
            return
        }
        heldCC.insert(cc)

        if cc == Top.bank.rawValue {
            bankUsedAsPage = false
            model.show("Arp page — rows are lanes, columns are rates")
            return
        }

        if let top = Top(rawValue: cc) {
            if arpPage {
                bankUsedAsPage = true
                switch top {
                case .keyDown:    model.nudgeTempo(-1)
                case .keyUp:      model.nudgeTempo(1)
                case .octaveDown: model.nudgeTempo(-5)
                case .octaveUp:   model.nudgeTempo(5)
                case .timbre:     model.tapTempo()
                case .tuning:     model.cycleSwing()
                case .panic:      model.panic()
                case .bank:       break
                }
                return
            }
            switch top {
            case .keyDown:    model.nudgeKey(-1)
            case .keyUp:      model.nudgeKey(1)
            case .octaveDown: model.nudgeOctave(-1)
            case .octaveUp:   model.nudgeOctave(1)
            case .bank:       break  // handled above
            case .timbre:     model.cycleTimbre()
            case .tuning:     model.cycleTuning()
            case .panic:      model.panic()
            }
            return
        }
        if let step = Self.ladder.firstIndex(of: cc) {
            let level = Double(7 - step) / 7.0
            model.set(.masterVolume, level)
            model.show(level == 0 ? "Muted" : "Output \(Int(level * 100))%")
        }
    }

    // MARK: - LEDs

    private func paint() {
        guard surface.isConnected else { return }
        if arpPage {
            paintArpTones()
            paintArpControls()
        } else {
            paintTones()
            paintControls()
        }
        paintButtons()
    }

    /// Tone block as the arp page: one row per lane, one column per rate.
    private func paintArpTones() {
        var msg: [UInt8] = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x03]
        let now = PulseCore.now()
        for pad in 0..<Harmony.padCount {
            let lane = pad / Harmony.cols
            let col = pad % Harmony.cols
            let l = model.lanes[lane]
            let hue = PulseCore.laneHues[lane]
            let (r, g, b): (UInt8, UInt8, UInt8)
            if l.enabled && l.divisionIndex == col {
                // The selected rate flashes as that lane strikes.
                let hit = max(0, 1 - (now - model.pulse.laneFlash[lane]) / 0.18)
                (r, g, b) = MIDISurface.rgb(hue: hue, brightness: 0.55 + 0.45 * hit)
            } else if l.enabled {
                (r, g, b) = MIDISurface.rgb(hue: hue, brightness: 0.11, saturation: 0.7)
            } else {
                (r, g, b) = (3, 3, 7)
            }
            msg.append(contentsOf: [0x03, UInt8(Self.toneNote(pad: pad)), r, g, b])
        }
        msg.append(0xF7)
        guard msg != lastToneMessage else { return }
        lastToneMessage = msg
        surface.send(msg)
    }

    /// Control rows as the arp page. Lane N is column N throughout, so the
    /// four lanes read as four vertical stripes whichever row you are on.
    private func paintArpControls() {
        var msg: [UInt8] = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x03]

        // Rows 4 and 3 — pattern, register, offset, source. Four and four.
        for (base, brightLeft) in [(41, 0.34), (31, 0.24)] {
            for i in 0..<8 {
                let lane = i % 4
                let hue = PulseCore.laneHues[lane]
                let on = model.lanes[lane].enabled
                let level = (i < 4 ? brightLeft : brightLeft * 0.6) * (on ? 1 : 0.3)
                let (r, g, b) = MIDISurface.rgb(hue: hue, brightness: level)
                msg.append(contentsOf: [0x03, UInt8(base + i), r, g, b])
            }
        }

        // Row 2 — the transport. Run breathes on the beat.
        let beat = model.pulse.displayBeat
        let onBeat = 1.0 - (beat - floor(beat))
        let hues: [Double] = [0.13, 0.36, 0.00, 0.50, 0.60, 0.60, 0.78, 0.86]
        for i in 0..<8 {
            var level = 0.16
            if i == 1 { level = model.pulseRunning ? 0.25 + 0.75 * onBeat : 0.2 }
            if i == 6 && model.swing > 0.01 { level = 0.7 }
            if i == 7 && model.humanize > 0.01 { level = 0.7 }
            let (r, g, b) = MIDISurface.rgb(hue: hues[i], brightness: level)
            msg.append(contentsOf: [0x03, UInt8(21 + i), r, g, b])
        }

        // Row 1 — presets.
        for i in 0..<8 {
            let on = model.pulsePreset == i
            let (r, g, b) = MIDISurface.rgb(hue: 0.09, brightness: on ? 1.0 : 0.12)
            msg.append(contentsOf: [0x03, UInt8(11 + i), r, g, b])
        }

        msg.append(0xF7)
        guard msg != lastControlMessage else { return }
        lastControlMessage = msg
        surface.send(msg)
    }

    private func paintTones() {
        var msg: [UInt8] = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x03]
        let hue = model.harmony.mode.hue
        for pad in 0..<Harmony.padCount {
            let tone = model.tones[pad]
            let env = Double(model.engine.meters[pad])
            let (r, g, b): (UInt8, UInt8, UInt8)
            if env > 0.004 {
                // Sounding: mode colour, brightness tracking the real envelope.
                // Jawari reads as a washed-out version of the same colour rather
                // than a different hue — a hue shift would collide with whichever
                // mode happens to be magenta.
                let sitar = model.padSitar[pad] > 0.01
                (r, g, b) = MIDISurface.rgb(hue: hue, brightness: 0.30 + 0.70 * min(1, env * 1.35),
                                            saturation: sitar ? 0.22 : 0.85)
            } else if tone.isRoot {
                (r, g, b) = (44, 20, 2)
            } else if tone.isChordTone {
                (r, g, b) = (24, 12, 2)
            } else {
                (r, g, b) = (3, 5, 12)
            }
            msg.append(contentsOf: [0x03, UInt8(Self.toneNote(pad: pad)), r, g, b])
        }
        msg.append(0xF7)
        guard msg != lastToneMessage else { return }
        lastToneMessage = msg
        surface.send(msg)
    }

    private func paintControls() {
        var msg: [UInt8] = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x03]

        // Row 4 — timbres.
        for i in 0..<8 {
            let t = TimbreCatalog.all[i]
            let on = i == model.timbreIndex
            let (r, g, b) = MIDISurface.rgb(hue: t.hue, brightness: on ? 1.0 : 0.13)
            msg.append(contentsOf: [0x03, UInt8(41 + i), r, g, b])
        }
        // Row 3 — temperaments.
        let tunings = TuningSystem.allCases
        for i in 0..<8 {
            guard i < tunings.count else {
                msg.append(contentsOf: [0x03, UInt8(31 + i), 0, 0, 0]); continue
            }
            let on = tunings[i] == model.harmony.tuning
            let (r, g, b) = MIDISurface.rgb(hue: 0.50, brightness: on ? 1.0 : 0.10)
            msg.append(contentsOf: [0x03, UInt8(31 + i), r, g, b])
        }
        // Row 2 — modifiers, bright while held.
        for mod in Modifier.allCases {
            let on = held.contains(mod.rawValue)
            let (r, g, b) = MIDISurface.rgb(hue: mod.hue, brightness: on ? 1.0 : 0.14,
                                            saturation: mod == .letGo ? 0.95 : 0.8)
            msg.append(contentsOf: [0x03, UInt8(mod.rawValue), r, g, b])
        }
        // Row 1 — modes in the current bank.
        for i in 0..<8 {
            let index = model.modeBank * ModeCatalog.bankSize + i
            guard index < ModeCatalog.all.count else {
                msg.append(contentsOf: [0x03, UInt8(11 + i), 0, 0, 0]); continue
            }
            let mode = ModeCatalog.all[index]
            let on = index == model.harmony.modeIndex
            let (r, g, b) = MIDISurface.rgb(hue: mode.hue, brightness: on ? 1.0 : 0.12)
            msg.append(contentsOf: [0x03, UInt8(11 + i), r, g, b])
        }

        msg.append(0xF7)
        guard msg != lastControlMessage else { return }
        lastControlMessage = msg
        surface.send(msg)
    }

    private func paintButtons() {
        var msg: [UInt8] = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x03]
        for top in Top.allCases {
            var (r, g, b): (UInt8, UInt8, UInt8)
            switch top {
            case .panic: (r, g, b) = (48, 4, 4)
            case .bank:  (r, g, b) = model.modeBank == 0 ? (10, 14, 30) : (40, 26, 70)
            case .timbre: (r, g, b) = MIDISurface.rgb(hue: TimbreCatalog.all[model.timbreIndex].hue, brightness: 0.35)
            case .tuning: (r, g, b) = (6, 30, 32)
            default: (r, g, b) = (22, 22, 26)
            }
            if arpPage {
                // On the arp page the top row is the tempo, so it says so.
                switch top {
                case .bank:   (r, g, b) = (90, 70, 20)
                case .timbre: (r, g, b) = MIDISurface.rgb(hue: 0.09, brightness: 0.9)   // TAP
                case .tuning: (r, g, b) = MIDISurface.rgb(hue: 0.78, brightness: model.swing > 0.01 ? 0.8 : 0.2)
                case .panic:  break
                default:      (r, g, b) = MIDISurface.rgb(hue: 0.5, brightness: 0.28)
                }
            }
            msg.append(contentsOf: [0x03, UInt8(top.rawValue), r, g, b])
        }
        // Right column: a master-level ladder, lit from the bottom up.
        let level = model.value(.masterVolume)
        for (i, cc) in Self.ladder.enumerated() {
            let stepLevel = Double(7 - i) / 7.0
            let lit = stepLevel <= level + 0.001 && level > 0
            // Green at the bottom, amber at the top — you can read it in the dark.
            let hue = 0.33 - 0.24 * stepLevel
            let (r, g, b) = lit ? MIDISurface.rgb(hue: hue, brightness: 0.85) : (UInt8(3), UInt8(3), UInt8(5))
            msg.append(contentsOf: [0x03, UInt8(cc), r, g, b])
        }
        // The logo breathes with the output.
        let peak = Double(model.engine.meters[DroneEngine.voiceCount])
        let (lr, lg, lb) = MIDISurface.rgb(hue: model.harmony.mode.hue,
                                           brightness: 0.06 + 0.9 * min(1, peak * 1.6))
        msg.append(contentsOf: [0x03, UInt8(Self.logo), lr, lg, lb])
        msg.append(0xF7)
        guard msg != lastButtonMessage else { return }
        lastButtonMessage = msg
        surface.send(msg)
    }
}

/// Puts the Launchpad into programmer mode on connect and takes it out again
/// on teardown. Kept separate so `MIDISurface` stays device-agnostic.
final class LaunchpadSurface: MIDISurface {
    override func didConnect() {
        send([0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x0E, 0x01, 0xF7])
    }
    override func willDisconnect() {
        send([0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x0E, 0x00, 0xF7])
    }
}
