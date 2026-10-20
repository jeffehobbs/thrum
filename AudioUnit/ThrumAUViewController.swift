import AudioToolbox
import Combine
import CoreAudioKit
import SwiftUI

/// The extension's principal class: makes the audio unit, and its window.
public final class ThrumAUViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: ThrumAudioUnit?
    private var embedded = false

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: ThrumAUView.size.width, height: ThrumAUView.size.height))
        preferredContentSize = ThrumAUView.size
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try ThrumAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = au
        DispatchQueue.main.async { [weak self] in self?.embedIfReady() }
        return au
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        embedIfReady()
    }

    private func embedIfReady() {
        guard isViewLoaded, let au = audioUnit, let tree = au.parameterTree, !embedded else { return }
        embedded = true
        let host = NSHostingView(rootView: ThrumAUView(
            bank: ParamBank(tree: tree), meters: VoiceMeters(engine: au.kernel.engine)))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

// MARK: - Model

/// The parameter tree as SwiftUI sees it. Values come back through the tree's
/// observer when anyone else sets them — the host's generic controls, a preset,
/// a restored project — and through a slow poll for automation, which the
/// kernel applies on the render thread and the tree never hears about.
final class ParamBank: ObservableObject {
    private let tree: AUParameterTree
    private var token: AUParameterObserverToken?
    private var timer: Timer?
    @Published private(set) var values: [Double]

    init(tree: AUParameterTree) {
        self.tree = tree
        values = ThrumParamSpec.all.map { Double(tree.parameter(withAddress: $0.param.rawValue)?.value ?? 0) }
        token = tree.token(byAddingParameterObserver: { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit {
        timer?.invalidate()
        if let token { tree.removeParameterObserver(token) }
    }

    private func refresh() {
        let fresh = ThrumParamSpec.all.map { Double(tree.parameter(withAddress: $0.param.rawValue)?.value ?? 0) }
        if fresh != values { values = fresh }
    }

    subscript(_ p: ThrumParam) -> Double {
        get { values[Int(p.rawValue)] }
        set {
            values[Int(p.rawValue)] = newValue
            tree.parameter(withAddress: p.rawValue)?.setValue(AUValue(newValue), originator: token)
        }
    }
}

/// The thirty-two voices' levels, read off the engine twenty times a second —
/// the same benign race on Floats the app's grid repaints from.
final class VoiceMeters: ObservableObject {
    private let engine: DroneEngine
    private var timer: Timer?
    @Published private(set) var levels = [Float](repeating: 0, count: DroneEngine.voiceCount)

    init(engine: DroneEngine) {
        self.engine = engine
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fresh = (0..<DroneEngine.voiceCount).map { self.engine.meters[$0] }
            if fresh != self.levels { self.levels = fresh }
        }
    }

    deinit { timer?.invalidate() }
}

// MARK: - View

private enum Ink {
    static let bg = Color(red: 0.043, green: 0.039, blue: 0.058)
    static let panel = Color.white.opacity(0.038)
    static let panelEdge = Color.white.opacity(0.075)
    static let text = Color.white.opacity(0.93)
    static let dim = Color.white.opacity(0.50)
    static let faint = Color.white.opacity(0.28)
    static let amber = Color(red: 0.98, green: 0.72, blue: 0.36)
}

struct ThrumAUView: View {
    static let size = NSSize(width: 1040, height: 452)

    @ObservedObject var bank: ParamBank
    @ObservedObject var meters: VoiceMeters

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            harmony
            HStack(alignment: .top, spacing: 12) {
                Panel(title: "Voice") { sliders([.swell, .fade, .velocity, .beating, .drift, .motion, .sitar]) }
                Panel(title: "Tone") { sliders([.brightness, .warmth, .presence, .air, .drive, .output]) }
                Panel(title: "Space") { sliders([.decay, .wet, .damping, .size, .width, .fieldDrift]) }
                Panel(title: "Time") {
                    sliders([.accentAttack, .accentDecay, .glide, .morph])
                    Spacer(minLength: 0)
                    flowControls
                }
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Ink.bg)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("THRUM")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .tracking(5)
                .foregroundStyle(Ink.amber)
            HStack(spacing: 5) {
                ForEach(Array(TimbreCatalog.all.enumerated()), id: \.offset) { i, t in
                    Button { bank[.timbre] = Double(i) } label: {
                        Text(t.name)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .frame(height: 24)
                    }
                    .buttonStyle(Chip(active: Int(bank[.timbre].rounded()) == i,
                                      hue: t.hue))
                }
            }
            Spacer(minLength: 0)
            VoiceDots(levels: meters.levels)
        }
    }

    /// The switch, and the mode Flow is in — which it moves by itself, and which
    /// can be stepped by hand.
    private var flowControls: some View {
        let on = bank[.flow] > 0.5
        let mode = Int(bank[.mode].rounded())
        let count = ModeCatalog.all.count
        return HStack(spacing: 3) {
            Button { bank[.flow] = on ? 0 : 1 } label: {
                Text("Flow")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: 52, height: 24)
            }
            .buttonStyle(Chip(active: on))
            Button { bank[.mode] = Double((mode + count - 1) % count) } label: {
                Text("‹").frame(width: 18, height: 24)
            }
            .buttonStyle(Chip(active: false, tight: true))
            Text(ModeCatalog.all[min(max(mode, 0), count - 1)].name)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(on ? Ink.text : Ink.dim)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Button { bank[.mode] = Double((mode + 1) % count) } label: {
                Text("›").frame(width: 18, height: 24)
            }
            .buttonStyle(Chip(active: false, tight: true))
        }
    }

    private var harmony: some View {
        HStack(spacing: 14) {
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { pc in
                    Button { bank[.key] = Double(pc) } label: {
                        Text(Pitch.name(pc))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(Chip(active: Int(bank[.key].rounded()) == pc, tight: true))
                }
            }
            HStack(spacing: 3) {
                ForEach(TuningSystem.allCases) { t in
                    Button { bank[.tuning] = Double(t.rawValue) } label: {
                        Text(t.short)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .frame(width: 38, height: 24)
                    }
                    .buttonStyle(Chip(active: Int(bank[.tuning].rounded()) == t.rawValue, tight: true))
                    .help(t.name)
                }
            }
            HStack(spacing: 3) {
                ForEach(Array(["Drone", "Accent"].enumerated()), id: \.offset) { i, name in
                    Button { bank[.articulation] = Double(i) } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .frame(width: 58, height: 24)
                    }
                    .buttonStyle(Chip(active: Int(bank[.articulation].rounded()) == i))
                }
            }
            ParamSlider(bank: bank, spec: .spec(.a4)).frame(width: 118)
        }
    }

    @ViewBuilder
    private func sliders(_ params: [ThrumParam]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(params, id: \.rawValue) { ParamSlider(bank: bank, spec: .spec($0)) }
        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.panelEdge))
    }
}

/// Thirty-two voices as the grid they are in the app: four rows of eight.
private struct VoiceDots: View {
    let levels: [Float]

    var body: some View {
        VStack(spacing: 3) {
            ForEach((0..<4).reversed(), id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { col in
                        let l = Double(levels[row * 8 + col])
                        Circle()
                            .fill(l > 0 ? Ink.amber.opacity(0.25 + 0.75 * min(1, l * 1.4))
                                        : Color.white.opacity(0.07))
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
    }
}

private struct ParamSlider: View {
    @ObservedObject var bank: ParamBank
    let spec: ThrumParamSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(spec.name)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Ink.text.opacity(0.85))
                Spacer()
                Text(spec.display(bank[spec.param]))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Ink.amber.opacity(0.9))
            }
            NormalizedSlider(position: Binding(
                get: { spec.normalized(bank[spec.param]) },
                set: { bank[spec.param] = spec.value(fromNormalized: $0) }))
        }
        // Double-click puts a control back where Thrum keeps it.
        .onTapGesture(count: 2) { bank[spec.param] = spec.defaultValue }
    }
}

/// A slim, dark slider — AppKit's is too tall and too bright for this window.
private struct NormalizedSlider: View {
    @Binding var position: Double

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

private struct Chip: ButtonStyle {
    var active: Bool
    var hue: Double?
    var tight = false

    func makeBody(configuration: Configuration) -> some View {
        let tint = hue.map { Color(hue: $0, saturation: 0.6, brightness: 0.95) } ?? Ink.amber
        configuration.label
            .padding(.horizontal, tight ? 0 : 8)
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
