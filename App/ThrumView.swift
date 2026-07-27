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
        }
    }

    // MARK: Center

    private var centerColumn: some View {
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

            Panel(title: "Voicings") {
                HStack(spacing: 6) {
                    ForEach(ThrumModel.Voicing.allCases) { v in
                        Button { model.apply(v) } label: {
                            Text(v.rawValue)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(Chip(active: false))
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
            if hovering {
                Text(spec.detail)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
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
