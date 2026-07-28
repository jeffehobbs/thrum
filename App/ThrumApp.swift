import SwiftUI
import AVFoundation

/// Drives one engine render per audio cycle from many render callbacks.
///
/// Spatial mode has seventeen source nodes — sixteen mono buses and the wet bed
/// — and every one of them gets its own callback, but the engine must render the
/// block exactly once. The first callback to arrive with a new sample time does
/// the work; the rest copy their slice out of it. Keying on the timestamp rather
/// than nominating a "leader" node matters, because callback order between
/// inputs of a mixer is not guaranteed.
///
/// Deliberately not `@MainActor` and holding no Swift collections: this is
/// touched from the render thread.
private final class SpatialPump {
    let engine: DroneEngine
    private var lastSampleTime: Double = -1

    init(engine: DroneEngine) { self.engine = engine }

    @inline(__always)
    func renderIfNeeded(_ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: Int) {
        let t = timestamp.pointee.mSampleTime
        if t != lastSampleTime {
            lastSampleTime = t
            engine.renderSpatial(frameCount: frames)
        }
    }
}

/// Hosts the drone engine on a local AVAudioEngine. Thrum is a standalone
/// instrument — the point is to fill a room while other people play over it,
/// not to sit on a DAW track.
@MainActor
final class ThrumHost: ObservableObject {
    let engine = DroneEngine()
    let model: ThrumModel
    let launchpad: LaunchpadController
    let launchControl: LaunchControlController

    private let audio = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // Spatial graph, built up front — *before* the engine starts.
    //
    // This was originally built lazily on first use, on the assumption that
    // sixteen HRTF instances convolving silence would be worth avoiding.
    // Measured, that assumption was wrong: the whole HRTF stage costs about
    // 0.2% of one core (Tools/spatial). What it bought instead was attaching and
    // connecting seventeen nodes to a *running* AVAudioEngine every time the
    // mode was switched, which is exactly the kind of live reconfiguration that
    // glitches the render thread. Building it before `start()` makes switching
    // modes a boolean and nothing more.
    private let environment = AVAudioEnvironmentNode()
    private var busNodes: [AVAudioSourceNode] = []
    private var wetNode: AVAudioSourceNode?
    private var pump: SpatialPump?
    private var sampleRate: Double = 48000
    private var spatialBuilt = false

    init() {
        // Read once and keep it. The rate gets frozen into eighteen source-node
        // formats below, and moving it afterwards without rebuilding all of them
        // would leave the synth computing phase increments for one rate while the
        // graph plays them at another — a transposed drone. So the engine stays at
        // whatever it started at and the mixer's converter absorbs any difference
        // with the hardware, which is the cheaper of the two mistakes.
        var sr = audio.outputNode.outputFormat(forBus: 0).sampleRate
        if sr < 8000 { sr = 48000 }
        sampleRate = sr
        engine.setSampleRate(sr)

        let model = ThrumModel(engine: engine)
        self.model = model
        launchpad = LaunchpadController(model: model)
        launchControl = LaunchControlController(model: model)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
        let kernel = engine
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            // Spatial mode renders through its own path; going silent here is
            // how the two modes swap without rebuilding the graph.
            if kernel.spatialEnabled {
                let list = UnsafeMutableAudioBufferListPointer(abl)
                for buffer in list {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }
            kernel.render(frameCount: Int(frameCount), out: abl)
            return noErr
        }
        sourceNode = node
        audio.attach(node)
        audio.connect(node, to: audio.mainMixerNode, format: format)
        audio.mainMixerNode.outputVolume = 1.0

        model.onSpatialChange = { [weak self] on in self?.setSpatial(on) }
        model.onFieldChange = { [weak self] in self?.scheduleFieldUpdate() }
        // Negated, and that is the whole ballgame. Measured with Tools/axis:
        // `AVAudio3DAngularOrientation` treats positive yaw and roll as turning
        // the listener *clockwise* — yaw +90° moves a source that was ahead into
        // the left ear — whereas CoreMotion's attitude is right-handed, so a head
        // turning left reports positive yaw. Passed straight through, the field
        // swings the wrong way and reads as "head tracking, but not right".
        //
        // The listener has to rotate the same way the head does for world-fixed
        // sources to stay put, so the two conventions have to be reconciled here.
        model.head.onOrientation = { [weak self] yaw, pitch, roll in
            self?.environment.listenerAngularOrientation =
                AVAudio3DAngularOrientation(yaw: Float(-yaw), pitch: Float(-pitch), roll: Float(-roll))
        }

        // Both land on the same place; the route changes on its own when the
        // system output moves, the mode changes when the user overrides it.
        model.route.onChange = { [weak self] in
            self?.applyRenderMode()
            self?.announceRoute()
        }
        model.onRenderModeChange = { [weak self] in self?.applyRenderMode() }

        buildSpatialGraph()

        do {
            try audio.start()
        } catch {
            model.show("Audio engine failed to start: \(error.localizedDescription)")
        }
        applyField()
        applyRenderMode()
        announceRoute()
        watchAudio()
    }

    /// Say something only when the route has a consequence worth knowing about.
    ///
    /// Which is really only latency. Announcing every route change would put
    /// "Out to MacBook Pro Speakers" over the status line every time headphones
    /// come out, which is both obvious and in the way — whereas finding out that
    /// AirPlay has put two seconds between the pad and the sound is much better
    /// learned from a status line than from a stage.
    private func announceRoute() {
        guard let warning = model.route.latencyWarning else { return }
        model.show("\(model.route.name) — \(warning)")
    }

    /// How the HRTF stage renders. Not a graph change — it can happen live, so a
    /// speaker being plugged in mid-drone costs nothing.
    private func applyRenderMode() {
        guard spatialBuilt else { return }
        switch model.spatialRender {
        case .auto:       environment.outputType = model.route.environmentOutputType
        case .headphones: environment.outputType = .headphones
        case .speakers:   environment.outputType = .externalSpeakers
        }
    }

    // MARK: - Spatial graph

    /// Switching modes is now only this: the two sets of source nodes both run
    /// every cycle, and whichever one isn't wanted returns silence.
    private func setSpatial(_ on: Bool) {
        engine.spatialEnabled = on
        if on { applyField() }
    }

    private func buildSpatialGraph() {
        guard !spatialBuilt else { return }
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        let kernel = engine
        let pump = SpatialPump(engine: kernel)
        self.pump = pump

        audio.attach(environment)
        environment.outputType = .headphones
        audio.connect(environment, to: audio.mainMixerNode, format: stereo)

        for bus in 0..<DroneEngine.spatialBusCount {
            let node = AVAudioSourceNode(format: mono) { _, timestamp, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let first = list.first, let data = first.mData else { return noErr }
                let out = data.assumingMemoryBound(to: Float.self)
                let n = Int(frameCount)
                guard kernel.spatialEnabled else {
                    memset(data, 0, Int(first.mDataByteSize))
                    return noErr
                }
                pump.renderIfNeeded(timestamp, n)
                kernel.copyBus(bus, n, into: out)
                return noErr
            }
            audio.attach(node)
            audio.connect(node, to: environment, format: mono)
            node.renderingAlgorithm = .HRTF
            busNodes.append(node)
        }

        // The tail bypasses the environment node entirely. A thirty-second
        // diffuse reverb has no location to be placed at, and spatializing it
        // would collapse it to a point.
        let wet = AVAudioSourceNode(format: stereo) { _, timestamp, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            guard kernel.spatialEnabled, list.count >= 2,
                  let ld = list[0].mData, let rd = list[1].mData else {
                for buffer in list { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                return noErr
            }
            pump.renderIfNeeded(timestamp, n)
            kernel.copyWet(n,
                           ld.assumingMemoryBound(to: Float.self),
                           rd.assumingMemoryBound(to: Float.self))
            return noErr
        }
        wetNode = wet
        audio.attach(wet)
        audio.connect(wet, to: audio.mainMixerNode, format: stereo)

        spatialBuilt = true
    }

    /// Coalesce geometry updates.
    ///
    /// `field` publishes on every increment of a slider drag, and each update
    /// rewrites sixteen node positions — which reaches into the audio graph from
    /// the main thread, dozens of times a second, exactly while SwiftUI is busy
    /// redrawing. That is the same shape as the bug that made dragging the Space
    /// sliders crackle, so it gets the same treatment: mark dirty, apply at most
    /// every 40 ms. Geometry is not something you can hear arriving late.
    private var fieldDirty = false
    private var audioWatchdog: Timer?
    private var terminating = false

    private func scheduleFieldUpdate() {
        guard !fieldDirty else { return }
        fieldDirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.fieldDirty = false
                self.applyField()
            }
        }
    }

    /// Push the ring geometry onto the nodes.
    func applyField() {
        guard spatialBuilt else { return }
        let field = model.field
        for (bus, node) in busNodes.enumerated() {
            node.position = field.position(bus: bus)
        }
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    }

    /// AVAudioEngine stops on an output-device change — plug in headphones, let
    /// AirPods sleep, switch outputs — and posts a configuration-change notice
    /// rather than recovering. Nothing restarts it unless we do. The node formats
    /// stay valid across a rate change because the mixer inserts converters, so
    /// restarting is enough.
    private func watchAudio() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The route has very likely just changed too — this notification
                // and the CoreAudio default-device listener are two views of the
                // same event — so re-read it here rather than relying on which
                // one arrives first.
                self.model.route.refresh()
                self.applyRenderMode()
                self.restartAudioIfNeeded(reason: "output device changed")
            }
        }
        // Belt and braces: anything else that stops it gets picked up within a
        // second or so.
        audioWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restartAudioIfNeeded(reason: nil) }
        }
    }

    private func restartAudioIfNeeded(reason: String?) {
        guard !terminating, !audio.isRunning else { return }
        do {
            try audio.start()
            if let reason { model.show("Audio restarted — \(reason)") }
        } catch {
            // Leave it for the next tick rather than spamming the status line.
        }
    }

    func shutdown() {
        terminating = true
        audioWatchdog?.invalidate()
        launchpad.shutdown()
        model.pulse.stop()
        model.route.shutdown()
        audio.stop()
    }
}

@main
struct ThrumApp: App {
    @StateObject private var host = ThrumHost()
    @StateObject private var updates = UpdateController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Thrum") {
            ThrumView(model: host.model, launchControl: host.launchControl)
                // NOT onDisappear. SwiftUI fires that whenever the view goes
                // away — including when Stage Manager moves the window to an
                // inactive set — and tearing the audio engine down there stops
                // the drone dead with no way back: the app is still running, the
                // window still exists, and there is no sound. Only a real quit
                // should shut anything down.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    host.shutdown()
                }
        }
        .defaultSize(width: 1460, height: 960)
        .commands {
            ThrumCommands(model: host.model)
            UpdateCommands(updates: updates)
        }
    }
}

/// The menu bar.
///
/// This is a `Commands` struct with its own `@ObservedObject` rather than a
/// closure reading `host.model`, and that is load-bearing: the scene observes
/// `ThrumHost`, and SwiftUI does not observe an ObservableObject nested inside
/// another one. Built the other way, every title here freezes at whatever it
/// said when the app launched, and — worse — anything carrying `.disabled` stays
/// disabled forever, so the menu item silently does nothing when clicked.
struct ThrumCommands: Commands {
    @ObservedObject var model: ThrumModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Drone") {
            Button("Let Go") { model.fadeAll() }
                .keyboardShortcut(".", modifiers: [.command])
            Button("Cut Short") { model.fadeAll(quick: true) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Silence") { model.panic() }
                .keyboardShortcut(.delete, modifiers: [.command])
            Divider()
            ForEach(ThrumModel.Voicing.allCases) { v in
                Button(v.rawValue) { model.apply(v) }
            }
            Divider()
            Button("Next Timbre") { model.cycleTimbre() }
                .keyboardShortcut("t", modifiers: [.command])
            Button("Next Temperament") { model.cycleTuning() }
                .keyboardShortcut("y", modifiers: [.command])
        }
        CommandMenu("Pulse") {
            Button(model.pulseRunning ? "Stop Pulse" : "Start Pulse") {
                model.togglePulse()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Tap Tempo") { model.tapTempo() }
                .keyboardShortcut("k", modifiers: [.command])
            Button("Realign Lanes") { model.realignPulse() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            ForEach(PulsePreset.all) { p in
                Button(p.name) { model.applyPulsePreset(p.id) }
            }
            Divider()
            Button("All Lanes Off") { model.allLanesOff() }
        }
        CommandMenu("Flow") {
            Button(model.flow.isRunning ? "Stop Flow" : "Start Flow") { model.flow.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandMenu("Field") {
            Button(model.spatialEnabled ? "Back to Stereo" : "Spatial Field") {
                model.spatialEnabled.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button(model.headTracking ? "Stop Head Tracking" : "Head Tracking") {
                model.headTracking.toggle()
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .disabled(!model.spatialEnabled)
            Button("Recenter") { model.head.recenter() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!model.headTracking)
            Divider()
            Menu("Render Field For") {
                ForEach(ThrumModel.SpatialRender.allCases) { mode in
                    Button(model.spatialRender == mode ? "✓  \(mode.rawValue)" : mode.rawValue) {
                        model.spatialRender = mode
                    }
                }
            }
        }
    }
}
