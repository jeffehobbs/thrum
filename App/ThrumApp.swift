import SwiftUI
import AVFoundation

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

    init() {
        var sr = audio.outputNode.outputFormat(forBus: 0).sampleRate
        if sr < 8000 { sr = 48000 }
        engine.setSampleRate(sr)

        let model = ThrumModel(engine: engine)
        self.model = model
        launchpad = LaunchpadController(model: model)
        launchControl = LaunchControlController(model: model)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
        let kernel = engine
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            kernel.render(frameCount: Int(frameCount), out: abl)
            return noErr
        }
        sourceNode = node
        audio.attach(node)
        audio.connect(node, to: audio.mainMixerNode, format: format)
        audio.mainMixerNode.outputVolume = 1.0
        do {
            try audio.start()
        } catch {
            model.show("Audio engine failed to start: \(error.localizedDescription)")
        }
    }

    func shutdown() {
        launchpad.shutdown()
        model.pulse.stop()
        audio.stop()
    }
}

@main
struct ThrumApp: App {
    @StateObject private var host = ThrumHost()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Thrum") {
            ThrumView(model: host.model, launchControl: host.launchControl)
                .onDisappear { host.shutdown() }
        }
        .defaultSize(width: 1460, height: 960)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Drone") {
                Button("Let Go") { host.model.fadeAll() }
                    .keyboardShortcut(".", modifiers: [.command])
                Button("Cut Short") { host.model.fadeAll(quick: true) }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Silence") { host.model.panic() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Divider()
                ForEach(ThrumModel.Voicing.allCases) { v in
                    Button(v.rawValue) { host.model.apply(v) }
                }
                Divider()
                Button("Next Timbre") { host.model.cycleTimbre() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("Next Temperament") { host.model.cycleTuning() }
                    .keyboardShortcut("y", modifiers: [.command])
            }
            CommandMenu("Pulse") {
                Button(host.model.pulseRunning ? "Stop Pulse" : "Start Pulse") {
                    host.model.togglePulse()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Tap Tempo") { host.model.tapTempo() }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Realign Lanes") { host.model.realignPulse() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                ForEach(PulsePreset.all) { p in
                    Button(p.name) { host.model.applyPulsePreset(p.id) }
                }
                Divider()
                Button("All Lanes Off") { host.model.allLanesOff() }
            }
        }
    }
}
