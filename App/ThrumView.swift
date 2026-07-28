import SwiftUI

// MARK: - Palette

enum Ink {
    static let bg = Color(red: 0.043, green: 0.039, blue: 0.058)
    static let bgDeep = Color(red: 0.021, green: 0.019, blue: 0.031)
    static let panel = Color.white.opacity(0.038)
    static let panelEdge = Color.white.opacity(0.075)
    static let text = Color.white.opacity(0.93)
    static let dim = Color.white.opacity(0.50)
    static let faint = Color.white.opacity(0.28)
    static let amber = Color(red: 0.98, green: 0.72, blue: 0.36)
    static let sitar = Color(red: 0.83, green: 0.52, blue: 0.95)

    static func mode(_ hue: Double, _ brightness: Double = 0.85, _ sat: Double = 0.62) -> Color {
        Color(hue: hue, saturation: sat, brightness: brightness)
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(Ink.faint)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.panelEdge))
    }
}

// MARK: - Root

struct ThrumView: View {
    @ObservedObject var model: ThrumModel
    @ObservedObject var launchControl: LaunchControlController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Ink.panelEdge)
            HStack(alignment: .top, spacing: 14) {
                harmonyColumn.frame(width: 230)
                centerColumn.frame(minWidth: 470, maxWidth: .infinity)
                parameterColumn.frame(width: 304)
            }
            .padding(14)
            statusBar
        }
        .background(
            LinearGradient(colors: [Ink.bg, Ink.bgDeep], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .foregroundStyle(Ink.text)
        .frame(minWidth: 1120, idealWidth: 1460, minHeight: 820, idealHeight: 960)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("THRUM")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .tracking(6)
                    .foregroundStyle(Ink.amber)
                Text("drone instrument")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(Ink.faint)
            }

            Divider().frame(height: 34).overlay(Ink.panelEdge)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.harmony.title)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(Ink.mode(model.harmony.mode.hue, 0.95, 0.35))
                Text(model.harmony.subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Ink.dim)
            }

            Spacer()

            FlowButton(model: model)

            RenderLoad(model: model)
            OutputMeter(model: model)

            HStack(spacing: 8) {
                DevicePill(name: "Launchpad X", on: model.launchpadConnected)
                DevicePill(name: "Launch Control", on: model.launchControlConnected)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: Harmony column

    private var harmonyColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                Panel(title: "Key") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                        ForEach(0..<12, id: \.self) { pc in
                            Button {
                                model.setKey(pc)
                            } label: {
                                Text(Pitch.name(pc))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .frame(maxWidth: .infinity, minHeight: 26)
                            }
                            .buttonStyle(Chip(active: model.harmony.keyPitchClass == pc))
                        }
                    }
                    HStack(spacing: 8) {
                        Stepper2(label: "Octave", value: "\(model.harmony.rootOctave)",
                                 down: { model.nudgeOctave(-1) }, up: { model.nudgeOctave(1) })
                        Button {
                            model.toggleReference()
                        } label: {
                            Text("A\(Int(model.harmony.a4))")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity, minHeight: 26)
                        }
                        .buttonStyle(Chip(active: model.harmony.a4 != 440))
                    }
                }

                Panel(title: "Mode · Chord") {
                    ForEach(ModeCatalog.all) { mode in
                        Button {
                            model.setMode(mode.id)
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Ink.mode(mode.hue)).frame(width: 6, height: 6)
                                Text(mode.name)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                Spacer(minLength: 4)
                                Text(mode.chordName)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Ink.faint)
                            }
                            .frame(maxWidth: .infinity, minHeight: 22)
                        }
                        .buttonStyle(Chip(active: model.harmony.modeIndex == mode.id, tight: true))
                    }
                }

                Panel(title: "Temperament") {
                    ForEach(TuningSystem.allCases) { t in
                        Button {
                            model.setTuning(t)
                        } label: {
                            HStack {
                                Text(t.name)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                Spacer(minLength: 4)
                                Text(t.short)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Ink.faint)
                            }
                            .frame(maxWidth: .infinity, minHeight: 22)
                        }
                        .buttonStyle(Chip(active: model.harmony.tuning == t, tight: true))
                    }
                    Text(model.harmony.tuning.blurb)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, Self.scrollTail)
        }
    }

    // MARK: Center

    /// Room under the last panel in every scrolling column. Without it the
    /// bottom of a column sits behind the Dock and can't be scrolled clear of it.
    static let scrollTail: CGFloat = 96

    private var centerColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 12) {
            Panel(title: "Timbre") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(TimbreCatalog.all) { t in
                        Button {
                            model.setTimbre(t.id)
                        } label: {
                            Text(t.name)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 26)
                        }
                        .buttonStyle(Chip(active: model.timbreIndex == t.id, hue: t.hue))
                    }
                }
                Text(TimbreCatalog.all[model.timbreIndex].blurb)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ToneGrid(model: model)

            PulsePanel(model: model)

            SpatialPanel(model: model)

            Panel(title: "Voicings") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(ThrumModel.Voicing.allCases) { v in
                        Button { model.apply(v) } label: {
                            Text(v.rawValue)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(Chip(active: false))
                        .help(v.detail)
                    }
                }
                HStack(spacing: 8) {
                    Button { model.fadeAll() } label: {
                        Label("Let go", systemImage: "wind")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(Chip(active: false))
                    Button { model.panic() } label: {
                        Label("Silence", systemImage: "xmark.circle")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(Chip(active: false, hue: 0.0))
                }
            }
        }
        .padding(.bottom, Self.scrollTail)
        }
    }

    // MARK: Parameters

    private var parameterColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                ForEach(ParamGroup.allCases) { group in
                    Panel(title: group.rawValue) {
                        ForEach(ThrumModel.specs.filter { $0.group == group }, id: \.param) { spec in
                            ParamSlider(model: model, spec: spec, launchControl: launchControl)
                        }
                    }
                }
                Panel(title: "Launch Control") {
                    Text(model.launchControlConnected
                         ? "Knobs are bound in the order shown above. Click a parameter name to re-learn it."
                         : "Not connected. When one is plugged in its knobs bind automatically, in the order shown above; until then every control lives here.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    if let learning = launchControl.learning {
                        Text("Learning \(ThrumModel.spec(learning).name) — move a knob")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.amber)
                    }
                    HStack(spacing: 6) {
                        Button { launchControl.cancelLearning() } label: {
                            Text("Cancel learn")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 24)
                        }
                        .buttonStyle(Chip(active: false))
                        Button { launchControl.clearMapping() } label: {
                            Text("Reset map")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 24)
                        }
                        .buttonStyle(Chip(active: false))
                    }
                }
            }
            .padding(.bottom, Self.scrollTail)
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Ink.mode(model.harmony.mode.hue))
                .frame(width: 5, height: 5)
            Text(model.status)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Ink.dim)
                .lineLimit(1)
            Spacer()
            Text("\(model.padOn.filter { $0 }.count) tones holding")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.28))
    }
}

// MARK: - Tone grid

private struct ToneGrid: View {
    @ObservedObject var model: ThrumModel

    var body: some View {
        Panel(title: "Tones — \(model.harmony.mode.name) across four octaves") {
            ZStack {
                Halo(model: model)
                VStack(spacing: 6) {
                    // Row 3 (highest) at the top, matching the Launchpad.
                    ForEach((0..<Harmony.rows).reversed(), id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<Harmony.cols, id: \.self) { col in
                                TonePad(model: model, pad: row * Harmony.cols + col)
                            }
                        }
                    }
                }
            }
            Text("Click to swell in · drag up and down to ride the level · ⌥-click for jawari")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Ink.faint)
        }
    }
}

/// The slow-moving glow behind the pads — the same envelopes that drive the
/// Launchpad LEDs, so the screen and the hardware breathe together.
private struct Halo: View {
    @ObservedObject var model: ThrumModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: model.isIdle)) { _ in
            Canvas { ctx, size in
                let cw = size.width / CGFloat(Harmony.cols)
                let ch = size.height / CGFloat(Harmony.rows)
                for pad in 0..<Harmony.padCount {
                    let env = CGFloat(model.engine.meters[pad])
                    guard env > 0.006 else { continue }
                    let row = Harmony.rows - 1 - pad / Harmony.cols
                    let col = pad % Harmony.cols
                    let center = CGPoint(x: (CGFloat(col) + 0.5) * cw, y: (CGFloat(row) + 0.5) * ch)
                    let r = cw * (0.75 + 1.5 * env)
                    let color = Color(hue: model.harmony.mode.hue, saturation: 0.75, brightness: 1.0)
                    ctx.fill(
                        Circle().path(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [color.opacity(Double(env) * 0.40), color.opacity(0)]),
                            center: center, startRadius: 0, endRadius: r))
                }
            }
            .blur(radius: 14)
            .allowsHitTesting(false)
        }
    }
}

private struct TonePad: View {
    @ObservedObject var model: ThrumModel
    let pad: Int
    @State private var dragStart: Double?

    private var tone: GridTone { model.tones[pad] }

    var body: some View {
        let level = model.padLevel[pad]
        let on = model.padOn[pad]
        let jawari = model.padSitar[pad] > 0.01
        let hue = model.harmony.mode.hue
        // Jawari desaturates rather than recolouring, so it stays readable in
        // whichever mode happens to be magenta.
        let fill = on ? Color(hue: hue, saturation: jawari ? 0.18 : 0.55, brightness: 0.30 + 0.42 * level)
                      : (tone.isChordTone ? Color.white.opacity(0.055) : Color.white.opacity(0.022))

        return VStack(spacing: 1) {
            Text(tone.degreeLabel)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? Ink.text : (tone.isChordTone ? Ink.text.opacity(0.8) : Ink.faint))
            Text("\(tone.noteName)\(tone.octave)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(on ? Ink.text.opacity(0.75) : Ink.faint)
            Text(abs(tone.deviation) < 0.5 ? "—" : String(format: "%+.0f¢", tone.deviation))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Ink.faint.opacity(0.85))
            LevelBar(level: level, on: on, hue: hue)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(jawari ? Ink.sitar.opacity(0.85)
                              : (on ? Color(hue: hue, saturation: 0.5, brightness: 1).opacity(0.65)
                                    : (tone.isRoot ? Ink.amber.opacity(0.45) : Ink.panelEdge)),
                              lineWidth: jawari ? 1.6 : (tone.isRoot ? 1.4 : 1))
        )
        .overlay(alignment: .topTrailing) {
            if model.padSitar[pad] > 0.01 {
                Circle().fill(Ink.sitar).frame(width: 5, height: 5).padding(4)
            }
        }
        .contentShape(Rectangle())
        // Tap and ride are separate gestures: the drag's minimum distance keeps
        // them from fighting, and a plain click always lands as a tap.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) {
                model.toggleSitar(pad: pad)
            } else {
                model.toggle(pad: pad)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { g in
                    let start = dragStart ?? (model.padOn[pad] ? model.padLevel[pad] : model.defaultLevel)
                    dragStart = start
                    model.setLevel(pad: pad, start - Double(g.translation.height) / 140.0)
                }
                .onEnded { _ in
                    dragStart = nil
                    if model.padLevel[pad] < 0.03 { model.release(pad: pad) }
                }
        )
        .help("\(tone.noteName)\(tone.octave) · \(tone.degreeLabel) · \(Int(tone.frequency.rounded())) Hz")
    }
}

private struct LevelBar: View {
    let level: Double
    let on: Bool
    let hue: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(Color(hue: hue, saturation: 0.55, brightness: 1))
                    .frame(width: geo.size.width * (on ? level : 0))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 8)
        .padding(.top, 3)
    }
}

// MARK: - Pulse

/// Four arpeggiators over the drone, and the clock they divide.
private struct PulsePanel: View {
    @ObservedObject var model: ThrumModel

    var body: some View {
        Panel(title: "Pulse — arpeggios over the drone") {
            HStack(spacing: 8) {
                Button { model.tapTempo() } label: {
                    Text("TAP")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(1.4)
                        .frame(width: 52, height: 30)
                }
                .buttonStyle(Chip(active: false))
                .help("Tap four times in time with the room. The last tap is the downbeat.")

                Text(String(format: "%.0f", model.tempo))
                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Ink.amber)
                    .frame(minWidth: 42, alignment: .trailing)
                Text("bpm")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.faint)

                Stepper2(label: "Tempo", value: "",
                         down: { model.nudgeTempo(-1) }, up: { model.nudgeTempo(1) })

                BeatDots(model: model)

                Spacer(minLength: 4)

                Menu {
                    ForEach(PulsePreset.all) { p in
                        Button("\(p.name) — \(p.detail)") { model.applyPulsePreset(p.id) }
                    }
                    Divider()
                    Button("All lanes off") { model.allLanesOff() }
                    Button("Realign lanes") { model.realignPulse() }
                } label: {
                    Text(model.pulsePreset.map { PulsePreset.all[$0].name } ?? "Presets")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .frame(width: 84, height: 26)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.panelEdge))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button { model.togglePulse() } label: {
                    Label(model.pulseRunning ? "Stop" : "Run",
                          systemImage: model.pulseRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 72, height: 30)
                }
                .buttonStyle(Chip(active: model.pulseRunning, hue: 0.36))
            }

            ForEach(0..<PulseCore.laneCount, id: \.self) { i in
                LaneStrip(model: model, index: i, hue: PulseCore.laneHues[i])
            }

            Text("Every lane draws from the mode and chord already loaded. Rates are ratios, not note values — ×1 against ×1½ takes six beats to come back around, and that drift is the point.")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LaneStrip: View {
    @ObservedObject var model: ThrumModel
    let index: Int
    let hue: Double

    var body: some View {
        let lane = model.lanes[index]
        HStack(spacing: 5) {
            Button { model.toggleLane(index) } label: {
                HStack(spacing: 4) {
                    LaneDot(model: model, index: index, hue: hue)
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .frame(width: 34, height: 24)
            }
            .buttonStyle(Chip(active: lane.enabled, hue: hue))
            .help(model.describe(lane: index))

            MenuChip(title: lane.source.rawValue, width: 58, enabled: lane.enabled) {
                ForEach(ArpSource.allCases) { s in
                    Button("\(s.rawValue) — \(s.detail)") { model.setLaneSource(index, s) }
                }
            }
            MenuChip(title: lane.pattern.rawValue, width: 74, enabled: lane.enabled) {
                ForEach(ArpPattern.allCases) { p in
                    Button("\(p.rawValue) — \(p.detail)") { model.setLanePattern(index, p) }
                }
            }
            MenuChip(title: lane.division.name, width: 44, enabled: lane.enabled) {
                ForEach(Division.all) { d in
                    Button("\(d.name) — \(d.detail)") { model.setLaneDivision(index, d.id) }
                }
            }
            MenuChip(title: lane.span.name, width: 44, enabled: lane.enabled) {
                ForEach(RowSpan.all) { s in
                    Button("Octave \(s.name)") { model.setLaneSpan(index, s.id) }
                }
            }
            Button { model.nudgeLanePhase(index) } label: {
                Text(lane.phase == 0 ? "—" : "\(Int(lane.phase * 4))/4")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(Chip(active: lane.phase != 0, hue: hue))
            .help("Shove this lane a quarter beat later, so it chases the others instead of locking to them.")

            NormalizedSlider(
                position: Binding(get: { model.lanes[index].level },
                                  set: { model.setLaneLevel(index, $0) }),
                hue: hue)
                .opacity(lane.enabled ? 1 : 0.35)
        }
    }
}

/// A menu styled to match the chips around it.
private struct MenuChip<Content: View>: View {
    let title: String
    let width: CGFloat
    var enabled = true
    @ViewBuilder var content: Content

    var body: some View {
        // The frame and the chip go *outside* the Menu. A borderless Menu lays
        // its label out to the label's own text, so sizing it from in there
        // makes every chip a different width depending on what is selected —
        // and that walks the lane sliders out of alignment with each other.
        Menu {
            content
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(enabled ? Ink.text.opacity(0.85) : Ink.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: width, height: 24)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.panelEdge))
    }
}

/// Lights when its lane strikes a note. Reads the pulse queue's benign-race
/// timestamps rather than pushing a published change per step — the clock runs
/// at up to eight notes a second and SwiftUI does not need to hear about it.
private struct LaneDot: View {
    @ObservedObject var model: ThrumModel
    let index: Int
    let hue: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !model.pulseRunning)) { _ in
            let age = PulseCore.now() - model.pulse.laneFlash[index]
            let glow = model.lanes[index].enabled ? max(0, 1 - age / 0.3) : 0
            Circle()
                .fill(Color(hue: hue, saturation: 0.65, brightness: 1))
                .opacity(0.16 + 0.84 * glow)
                .frame(width: 7, height: 7)
        }
    }
}

private struct BeatDots: View {
    @ObservedObject var model: ThrumModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !model.pulseRunning)) { _ in
            let beat = model.pulse.displayBeat
            let inBar = beat - floor(beat / 4) * 4
            let lit = min(3, max(0, Int(inBar)))
            let frac = inBar - floor(inBar)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i == 0 ? Ink.amber : Ink.text)
                        .opacity(model.pulseRunning && i == lit ? 1.0 - 0.72 * frac : 0.14)
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

// MARK: - Flow

/// The yin-yang. One button that hands the instrument to itself.
///
/// It turns slowly while Flow is running — one revolution a minute, which is
/// about the rate the music moves at, and slow enough to sit in peripheral vision
/// for an hour without nagging.
private struct FlowButton: View {
    @ObservedObject var model: ThrumModel
    @ObservedObject var flow: FlowDirector

    init(model: ThrumModel) {
        self.model = model
        self.flow = model.flow
    }

    var body: some View {
        Button { model.flow.toggle() } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !flow.isRunning)) { _ in
                Text("\u{262F}")
                    .font(.system(size: 19))
                    .foregroundStyle(flow.isRunning
                                     ? Ink.mode(model.harmony.mode.hue, 1.0, 0.55)
                                     : Ink.text.opacity(0.55))
                    .rotationEffect(.degrees(flow.isRunning ? flow.elapsed * 6 : 0))
                    .shadow(color: flow.isRunning
                            ? Ink.mode(model.harmony.mode.hue).opacity(0.7) : .clear,
                            radius: 7)
                    .frame(width: 30, height: 26)
            }
        }
        .buttonStyle(.plain)
        .help(flow.isRunning
              ? "Flow is running — voicings, modes, timbres and arpeggios are drifting on their own. Click to take back over; everything stays where it got to."
              : "Flow: hand the instrument to itself. Something is always moving and nothing ever jumps, so you can work through it. Different every time.")
    }
}

// MARK: - Spatial

/// The field, and where your head is pointing in it.
private struct SpatialPanel: View {
    @ObservedObject var model: ThrumModel
    @ObservedObject var head: HeadTracker
    @ObservedObject var route: AudioRoute

    init(model: ThrumModel) {
        self.model = model
        self.head = model.head
        self.route = model.route
    }

    var body: some View {
        Panel(title: "Spatial — the drone around you") {
            HStack(alignment: .top, spacing: 12) {
                FieldRadar(model: model)
                    .frame(width: 116, height: 116)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Button { model.spatialEnabled.toggle() } label: {
                            Label(model.spatialEnabled ? "Spatial" : "Stereo",
                                  systemImage: model.spatialEnabled ? "circle.hexagongrid.fill" : "speaker.wave.2")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(width: 94, height: 28)
                        }
                        .buttonStyle(Chip(active: model.spatialEnabled, hue: 0.55))
                        .help("Sixteen mono buses placed around you and rendered binaurally, instead of one stereo mix.")

                        Button { model.headTracking.toggle() } label: {
                            Label("Head", systemImage: "airpodspro")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .frame(width: 76, height: 28)
                        }
                        .buttonStyle(Chip(active: model.headTracking, hue: 0.36))
                        .disabled(!model.spatialEnabled || head.status == .unsupported)
                        .help(head.status.blurb)

                        Button { model.head.recenter() } label: {
                            Label("Recenter", systemImage: "scope")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .frame(width: 92, height: 28)
                        }
                        .buttonStyle(Chip(active: false))
                        .disabled(!model.headTracking)
                        .help("Takes where you are looking now as straight ahead. AirPods yaw drifts, so this is the button you'll actually use.")
                    }

                    if model.headTracking && head.status == .tracking {
                        Text(String(format: "yaw %+.0f°   pitch %+.0f°   roll %+.0f°",
                                    head.yaw, head.pitch, head.roll))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Ink.amber.opacity(0.9))
                    } else {
                        Text(head.status.blurb)
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(head.status == .denied ? Color.red.opacity(0.85) : Ink.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(model.spatialEnabled
                         ? "Columns are compass points with the tonic ahead of you; the low two octaves ring below the ear line and the high two above it. Field Radius and Field Lift are under Space."
                         : "Off. Every tone is placed by its degree and its octave, so an arpeggio walking up a column climbs and a lane walking across the mode orbits.")
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.spatialEnabled {
                        renderRow

                        Text("Set macOS's own Spatial Audio to Off for your AirPods — two lots of HRTF smears it.")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Ink.amber.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Which HRTF target the field is rendered for.
    ///
    /// Worth a control rather than a guess because the wrong choice is audible
    /// and reads as a broken feature: headphone binaural played over a speaker
    /// in a room comes out hollow and phasey, since the ear-to-ear crosstalk it
    /// spent its effort cancelling never happens. The route gets it right for
    /// AirPods and for an interface feeding a PA. It gets it wrong for a
    /// Bluetooth speaker, which looks like AirPods to CoreAudio.
    private var renderRow: some View {
        HStack(spacing: 6) {
            Text("RENDER FOR")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Ink.faint)

            ForEach(ThrumModel.SpatialRender.allCases) { mode in
                Button { model.spatialRender = mode } label: {
                    Text(mode == .auto ? autoLabel : mode.rawValue)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .frame(width: mode == .auto ? 84 : 76, height: 24)
                }
                .buttonStyle(Chip(active: model.spatialRender == mode, hue: 0.55))
                .help(help(for: mode))
            }
        }
    }

    /// Auto says what it resolved to, so the button is a readout as well as a
    /// choice — otherwise the only way to know which way it went is by ear.
    private var autoLabel: String {
        route.environmentOutputType == .headphones ? "Auto · phones" : "Auto · room"
    }

    private func help(for mode: ThrumModel.SpatialRender) -> String {
        switch mode {
        case .auto:
            return "Follows the output device: headphones and Bluetooth get binaural, AirPlay and interfaces get speaker rendering."
        case .headphones:
            return "Force binaural. Right for AirPods; hollow and phasey over a speaker in a room."
        case .speakers:
            return "Force speaker rendering. Right for AirPlay, a PA, or a Bluetooth speaker — anything CoreAudio calls Bluetooth but you can hear across the room."
        }
    }
}

/// Top-down view of the field. Two rings of eight: the inner ring is the low
/// octaves, the outer the high ones, each dot lit by what that bus is actually
/// putting out. Ahead is up.
private struct FieldRadar: View {
    @ObservedObject var model: ThrumModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: model.isIdle)) { _ in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2 - 8
                let inner = outer * 0.58
                let hue = model.harmony.mode.hue

                for r in [inner, outer] {
                    ctx.stroke(Circle().path(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(Ink.panelEdge), lineWidth: 1)
                }
                // A tick where the listener faces.
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: c.x, y: c.y - outer - 6))
                    p.addLine(to: CGPoint(x: c.x, y: c.y - outer - 1))
                }, with: .color(Ink.amber.opacity(0.8)), lineWidth: 1.5)

                // Sum each bus's pads straight off the engine meters.
                var level = [Double](repeating: 0, count: DroneEngine.spatialBusCount)
                for pad in 0..<Harmony.padCount {
                    level[DroneEngine.bus(pad: pad)] += Double(model.engine.meters[pad])
                }

                for bus in 0..<DroneEngine.spatialBusCount {
                    let tier = bus / SpatialField.azimuths
                    let col = bus % SpatialField.azimuths
                    let az = Double(col) / Double(SpatialField.azimuths) * 2 * .pi
                    let r = tier == 0 ? inner : outer
                    // Screen y grows downward, and ahead is up.
                    let p = CGPoint(x: c.x + CGFloat(sin(az)) * r,
                                    y: c.y - CGFloat(cos(az)) * r)
                    let v = min(1.0, level[bus])
                    let d: CGFloat = v > 0.004 ? 5 + CGFloat(v) * 7 : 4
                    let color = v > 0.004
                        ? Color(hue: hue, saturation: 0.7, brightness: 1).opacity(0.35 + 0.65 * v)
                        : Color.white.opacity(0.14)
                    ctx.fill(Circle().path(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                             with: .color(color))
                }

                // Your head, rotated by the tracker.
                let yaw = model.headTracking ? model.head.yaw * .pi / 180 : 0
                ctx.stroke(Path { p in
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + CGFloat(sin(yaw)) * inner * 0.55,
                                          y: c.y - CGFloat(cos(yaw)) * inner * 0.55))
                }, with: .color(Ink.text.opacity(0.65)), lineWidth: 1.5)
                ctx.fill(Circle().path(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)),
                         with: .color(Ink.text.opacity(0.8)))
            }
            .opacity(model.spatialEnabled ? 1 : 0.4)
        }
    }
}

// MARK: - Parameter slider

private struct ParamSlider: View {
    @ObservedObject var model: ThrumModel
    let spec: ParamSpec
    @ObservedObject var launchControl: LaunchControlController

    @State private var hovering = false

    var body: some View {
        let value = model.value(spec.param)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Button {
                    launchControl.beginLearning(spec.param)
                } label: {
                    Text(spec.name)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Ink.text.opacity(0.85))
                }
                .buttonStyle(.plain)
                if let cc = launchControl.ccLabel(for: spec.param) {
                    Text(cc)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Ink.faint)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Text(spec.display(value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Ink.amber.opacity(0.9))
            }
            NormalizedSlider(
                position: Binding(
                    get: { spec.normalized(model.value(spec.param)) },
                    set: { model.set(spec.param, spec.value(fromNormalized: $0)) }),
                hue: 0.09)
            // Two lines of room are held open whether or not the text is
            // showing. Adding and removing the label instead reflows every
            // slider below it, so the one you were reaching for moves while
            // you reach for it.
            Text(spec.detail)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(Ink.faint)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .opacity(hovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: hovering)
        }
        .padding(.vertical, 1)
        // The reserved text counts as part of the target, so the label stays up
        // while you read it rather than flickering off at the slider's edge.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A slim, dark slider — AppKit's is too tall and too bright for this window.
private struct NormalizedSlider: View {
    @Binding var position: Double
    var hue: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: [Ink.amber.opacity(0.55), Ink.amber],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, w * position), height: 4)
                Circle()
                    .fill(Ink.amber)
                    .frame(width: 9, height: 9)
                    .shadow(color: Ink.amber.opacity(0.6), radius: 4)
                    .offset(x: max(0, min(w - 9, w * position - 4.5)))
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in position = min(1, max(0, g.location.x / w)) }
            )
        }
        .frame(height: 14)
    }
}

// MARK: - Small parts

private struct Chip: ButtonStyle {
    var active: Bool
    var hue: Double?
    var tight = false

    func makeBody(configuration: Configuration) -> some View {
        let tint = hue.map { Color(hue: $0, saturation: 0.6, brightness: 0.95) } ?? Ink.amber
        configuration.label
            .padding(.horizontal, tight ? 6 : 4)
            .foregroundStyle(active ? Color.black.opacity(0.85) : Ink.text.opacity(0.82))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? tint.opacity(0.92)
                                 : Color.white.opacity(configuration.isPressed ? 0.13 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(active ? Color.clear : Ink.panelEdge)
            )
            .contentShape(Rectangle())
    }
}

private struct Stepper2: View {
    let label: String
    let value: String
    let down: () -> Void
    let up: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: down) { Text("−").frame(width: 22, height: 26) }
                .buttonStyle(Chip(active: false))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(minWidth: 22)
            Button(action: up) { Text("+").frame(width: 22, height: 26) }
                .buttonStyle(Chip(active: false))
        }
        .help(label)
    }
}

private struct DevicePill: View {
    let name: String
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? Color.green.opacity(0.85) : Color.white.opacity(0.18))
                .frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(on ? Ink.text.opacity(0.8) : Ink.faint)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.panelEdge))
    }
}

/// How close the render callback is running to its deadline. Anything at or
/// over 100% is a dropout, and the overrun tally is the thing to watch — it is
/// the difference between "sounds fine to me" and "has not missed a buffer".
private struct RenderLoad: View {
    @ObservedObject var model: ThrumModel

    var body: some View {
        let load = Double(model.renderLoad)
        let over = model.renderOverruns
        Button {
            model.resetRenderStats()
        } label: {
            HStack(spacing: 5) {
                Text("DSP")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Ink.faint)
                Text("\(Int((load * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(load > 0.7 ? Color.red : (load > 0.4 ? Ink.amber : Ink.dim))
                    .frame(minWidth: 26, alignment: .trailing)
                if over > 0 {
                    Text("\(over) drop\(over == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.red.opacity(0.9))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(over > 0 ? Color.red.opacity(0.5) : Ink.panelEdge))
        }
        .buttonStyle(.plain)
        .help(over > 0
              ? "\(over) block(s) missed the render deadline. Click to reset. If this climbs while playing, the engine can't keep up."
              : "Share of the render deadline being used. Click to reset the peak.")
    }
}

private struct OutputMeter: View {
    @ObservedObject var model: ThrumModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: model.isIdle)) { _ in
            let peak = Double(model.engine.meters[DroneEngine.voiceCount])
            HStack(spacing: 2) {
                ForEach(0..<18, id: \.self) { i in
                    let t = Double(i) / 17.0
                    Capsule()
                        .fill(peak > t * 0.95
                              ? (t > 0.85 ? Color.red.opacity(0.9) : Ink.amber.opacity(0.55 + 0.45 * t))
                              : Color.white.opacity(0.08))
                        .frame(width: 3, height: 6 + CGFloat(t) * 12)
                }
            }
            .frame(height: 20, alignment: .bottom)
        }
    }
}
