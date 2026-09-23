import Foundation
import AVFoundation
import Accelerate
import Combine
import MediaPlayer
import OSLog
import os
import UIKit
import simd

/// The television host. Flow plays the instrument into the room's speakers, the
/// wash shows what it is doing, and play/pause on the remote is the only
/// control there is.
///
/// **No settings, on purpose.** The phone has two switches and a tip jar; the
/// television has none. What the listener has taught Flow arrives from the phone
/// through iCloud (`TasteCloud`) and is adopted read-only. There is nothing to
/// configure because there is nothing the room can tell us that the route does
/// not already: how many channels it has.
///
/// **5.1 is the point.** If the HDMI sink offers six or more channels, the
/// engine's sixteen spatial buses are rendered by an `AVAudioEnvironmentNode`
/// into a six-channel format — tonic in the centre speaker, the mode wrapping
/// round through L/R to the surrounds, the two octave tiers above and below.
/// `Tools/surround` measured the mapping offline before any of this was written:
/// ahead lands 22 dB in front, behind lands 31 dB in the surrounds, nothing goes
/// to the LFE. Three things that harness established and this file depends on:
///
/// - **HRTF and HRTFHQ render to a stereo pair only.** At a 5.1 output the node
///   lists `soundField` and `auto` as applicable — and `soundField` renders
///   *silence*. `.auto` is the algorithm that actually distributes a point
///   source across six channels, so every bus uses it.
/// - **The main mixer must be connected to the output in six channels explicitly.**
///   Left implicit, AVAudioEngine wires it in stereo whatever the hardware has,
///   and folds the environment's 5.1 down to L/R before the output node sees it.
///   It does not go silent; it just quietly becomes a stereo app.
/// - **The reverb's wet pair are two more buses**, parked wide and a little
///   behind (±110°), rather than a stereo node into the mixer whose channel
///   mapping into a 5.1 layout would be a guess. The harness puts them in Ls/Rs.
///
/// Over a stereo sink — the television's own speakers, most ARC soundbars — the
/// same stereo path the Mac plays over speakers is used. The route decides; the
/// listener does not have to.
@MainActor
final class TVHost: ObservableObject {
    enum Transport { case idle, playing }

    static let fps = 60

    let engine = DroneEngine()
    let model: ThrumModel

    private let audio = AVAudioEngine()
    private var environment = AVAudioEnvironmentNode()
    private var sourceNode: AVAudioSourceNode?
    private var busNodes: [AVAudioSourceNode] = []
    private var wetNodes: [AVAudioSourceNode] = []
    private var wetScratch: [UnsafeMutablePointer<Float>] = []
    private var pump: SurroundPump?
    private let taste: Taste
    private let cloud = TasteCloud(role: .subscriber)
    private let idleGuard = IdleGuard()
    private var observers: [NSObjectProtocol] = []
    private var captionTimer: Timer?
    private var captionedSubtitle = ""
    private var lastToggle: CFAbsoluteTime = 0
    private var fieldDirty = false
    private var placedField = SpatialField()
    private var placedFieldValid = false
    private var harmonyWatch: AnyCancellable?
    private var levelSums: UnsafeMutablePointer<Float>?
    /// `running`, readable off the main actor — the level tap's queue needs it.
    private let playing = OSAllocatedUnfairLock(initialState: false)

    @Published private(set) var transport: Transport = .idle
    @Published private(set) var caption = ""
    @Published private(set) var captionVisible = false
    @Published private(set) var channels = 2
    @Published private(set) var routeName = ""
    @Published private(set) var lastError: String?
    private(set) var sampleRate: Double = 48_000
    /// The EDR headroom UIScreen *reports*, for the log. Informational only:
    /// tvOS gives a Metal layer no way to use it (see `WashView`), so the
    /// picture is SDR whatever this says.
    private(set) var headroom: Float = 0
    // The wash smoother's state — see `fillWash`.
    private var smoothLevel = [Float](repeating: 0, count: DroneEngine.voiceCount)
    private var smoothMaster: Float = 0
    private var smoothHue: Float = 0.62
    private var lastWashTime = CFAbsoluteTimeGetCurrent()

    var running: Bool { transport == .playing }
    var surround: Bool { channels >= 6 }

    /// tvOS gives an app nowhere durable but ~500 KB of defaults; everything else
    /// is Caches, which the system may reclaim. The book lives there as a
    /// convenience for a launch without iCloud — if it is gone, the next `pull`
    /// brings it back, and an empty book is exactly a fresh install's.
    private static var tasteCache: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Thrum/taste.json")
    }

    init() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback: this is the music in the room, not a notification sound.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            TVLog.note("session: \(error.localizedDescription)")
        }
        var sr = session.sampleRate
        if sr < 8000 { sr = 48_000 }
        sampleRate = sr
        engine.setSampleRate(sr)

        taste = Taste(store: Self.tasteCache)
        model = ThrumModel(engine: engine, taste: taste)
        // There is no grid on a television, so nothing but Flow ever sets the key.
        model.flow.picksKeyOnStart = true
        model.onFieldChange = { [weak self] in self?.scheduleFieldUpdate() }
        model.route.onChange = { [weak self] in self?.routeChanged() }
        cloud.onBook = { [weak self] data in
            guard let self else { return }
            let ok = self.taste.adopt(data)
            TVLog.note("iCloud book \(ok ? "adopted" : "rejected") — \(data.count) bytes, \(self.taste.summary)")
        }
        cloud.pull()

        negotiateChannels()
        buildGraph()
        watchSession()
        registerRemoteCommands()
        harmonyWatch = model.$harmony
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateNowPlaying()
                // Aerial relabels when the scene changes; this relabels when the
                // music does. Flow moves mode and voicing every few minutes, and
                // the one line of text on this screen is for exactly that moment.
                if self.running, self.model.harmony.subtitle != self.captionedSubtitle { self.showCaption() }
            }
        updateNowPlaying()
        TVLog.note("LAUNCH — \(bufferReport), route \(routeName), \(channels) ch, iCloud \(cloud.isAvailable ? "yes" : "no")")
        // `-autostart`: for the simulator, which cannot be given a remote press
        // from a script. Test hook only — and, as the phone learned, a hook that
        // skips the entry point tests everything except whether the app can be
        // started, so the real Select path still has to be tried on the device.
        if ProcessInfo.processInfo.arguments.contains("-autostart") {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.start() } }
        }
    }

    // MARK: - The room

    /// Ask the session for 5.1 when the sink can do it, then read back what it
    /// actually gave us. `maximumOutputNumberOfChannels` is the sink's word (via
    /// EDID over HDMI, through eARC to a receiver); `outputNumberOfChannels` is
    /// the truth after negotiation. Six exactly, not the maximum: 5.1 is the
    /// layout the ring was measured against, and a 7.1 sink still plays it.
    private func negotiateChannels() {
        let session = AVAudioSession.sharedInstance()
        let maximum = session.maximumOutputNumberOfChannels
        let wanted = maximum >= 6 ? 6 : 2
        if session.preferredOutputNumberOfChannels != wanted {
            do {
                try session.setPreferredOutputNumberOfChannels(wanted)
            } catch {
                TVLog.note("preferred channels \(wanted) refused: \(error.localizedDescription)")
            }
        }
        channels = session.outputNumberOfChannels
        routeName = session.currentRoute.outputs.first?.portName ?? ""
        TVLog.note("channels: max \(maximum), asked \(wanted), got \(channels), route \(routeName)")
    }

    /// What the graph renders into. 5.1 — MPEG 5.1 A, L R C LFE Ls Rs — whenever
    /// the sink offers six or more channels, and stereo otherwise.
    ///
    /// Always 5.1, never the hardware's own layout, and this was measured on the
    /// TV Room Apple TV: its output node presents a **twelve-channel** format (a
    /// 7.1.4 bed, tvOS's own spatial pipeline) and the session reports a maximum
    /// of 32. Rendering into that bed would put the high tier in the height
    /// channels and hand tvOS a 7.1.4 mix to encode however its Audio Format
    /// setting says. The brief is 5.1 LPCM, so the graph renders exactly that and
    /// tvOS maps six labelled channels into its bed; the receiver then gets what
    /// the Apple TV's Audio Format setting sends it. `Tools/surround` is the
    /// measurement this layout rests on.
    private func outputFormat() -> AVAudioFormat {
        guard surround else {
            return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    /// For the log: what the hardware side of the output node looks like.
    private var hardwareReport: String {
        let hw = audio.outputNode.outputFormat(forBus: 0)
        let tag = hw.channelLayout.map { String(format: "0x%08X", $0.layoutTag) } ?? "none"
        return "\(hw.channelCount) ch, layout \(tag), \(Int(hw.sampleRate)) Hz"
    }

    /// The port, as a word. The port *name* on an Apple TV is the Apple TV
    /// itself ("TV Room Apple TV (30364)"), which is not what a caption is for.
    private var portWord: String {
        switch AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType {
        case .HDMI?:          return "HDMI"
        case .airPlay?:       return "AirPlay"
        case .bluetoothA2DP?: return "Bluetooth"
        case .headphones?:    return "Headphones"
        case nil:             return ""
        default:              return routeName
        }
    }

    // MARK: - Graph

    private func buildGraph() {
        let out = outputFormat()
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        // First, and explicitly. See the note at the top of the file.
        audio.connect(audio.mainMixerNode, to: audio.outputNode, format: out)

        let kernel = engine
        let node = AVAudioSourceNode(format: stereo) { _, _, frameCount, abl -> OSStatus in
            if kernel.spatialEnabled {
                let list = UnsafeMutableAudioBufferListPointer(abl)
                for buffer in list { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                return noErr
            }
            kernel.render(frameCount: Int(frameCount), out: abl)
            return noErr
        }
        sourceNode = node
        audio.attach(node)
        audio.connect(node, to: audio.mainMixerNode, format: stereo)

        guard surround else {
            engine.spatialEnabled = false
            installLevelTap(channels: 2)
            TVLog.note("graph: stereo")
            return
        }

        let pump = SurroundPump(engine: kernel)
        self.pump = pump
        environment = AVAudioEnvironmentNode()
        audio.attach(environment)
        audio.connect(environment, to: audio.mainMixerNode, format: out)
        environment.outputType = .externalSpeakers
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
        // Thrum brings its own reverb; the node's would be a second room.
        environment.reverbParameters.enable = false

        for bus in 0..<DroneEngine.spatialBusCount {
            let busNode = AVAudioSourceNode(format: mono) { _, timestamp, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let first = list.first, let data = first.mData else { return noErr }
                let n = Int(frameCount)
                guard kernel.spatialEnabled else {
                    memset(data, 0, Int(first.mDataByteSize))
                    return noErr
                }
                pump.renderIfNeeded(timestamp, n)
                kernel.copyBus(bus, n, into: data.assumingMemoryBound(to: Float.self))
                return noErr
            }
            audio.attach(busNode)
            audio.connect(busNode, to: environment, format: mono)
            // `.auto`, not `.soundField` — the one that renders. See the header.
            busNode.renderingAlgorithm = .auto
            busNodes.append(busNode)
        }

        // The wet pair, as two mono buses. `copyWet` fills both channels at once,
        // so each node copies its own side and discards the other into scratch.
        for side in 0..<2 {
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
            scratch.initialize(repeating: 0, count: 8192)
            wetScratch.append(scratch)
            let wet = AVAudioSourceNode(format: mono) { _, timestamp, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let first = list.first, let data = first.mData else { return noErr }
                let n = min(Int(frameCount), 8192)
                guard kernel.spatialEnabled else {
                    memset(data, 0, Int(first.mDataByteSize))
                    return noErr
                }
                pump.renderIfNeeded(timestamp, n)
                let mine = data.assumingMemoryBound(to: Float.self)
                if side == 0 { kernel.copyWet(n, mine, scratch) } else { kernel.copyWet(n, scratch, mine) }
                return noErr
            }
            audio.attach(wet)
            audio.connect(wet, to: environment, format: mono)
            wet.renderingAlgorithm = .auto
            wetNodes.append(wet)
        }

        engine.spatialEnabled = true
        placedFieldValid = false
        applyField()
        installLevelTap(channels: Int(out.channelCount))
        let algorithms = environment.applicableRenderingAlgorithms.map { $0.intValue }
        TVLog.note("graph: surround \(out.channelCount) ch into hardware \(hardwareReport); applicable algorithms \(algorithms)")
    }

    /// One tap on the main mixer: RMS per output channel, accumulated on the
    /// render side and written to the log every fifteen seconds while playing.
    /// This is the only instrument that can answer "is sound leaving the app,
    /// and on which channels" on a television with no console — the question
    /// Jeff asked as "is there music playing?". `vDSP_measqv` per channel per
    /// buffer, no allocation, no lock; the log line is the one thing that is
    /// not free and it happens twice a minute.
    private func installLevelTap(channels: Int) {
        let mixer = audio.mainMixerNode
        mixer.removeTap(onBus: 0)
        let sums = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        sums.initialize(repeating: 0, count: 16)
        levelSums?.deallocate()
        levelSums = sums
        var buffers = 0
        let rate = sampleRate
        let playing = self.playing
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n = vDSP_Length(buffer.frameLength)
            let count = min(Int(buffer.format.channelCount), 16)
            for ch in 0..<count {
                var p: Float = 0
                vDSP_measqv(data[ch], 1, &p, n)
                sums[ch] += p
            }
            buffers += 1
            // ~15 s at 4096-frame buffers (the tap actually delivers ~100 ms ones).
            if Double(buffers) * Double(buffer.frameLength) >= 15 * rate {
                var line: [String] = []
                for ch in 0..<count {
                    let rms = sqrtf(sums[ch] / Float(buffers))
                    line.append(rms > 1e-6 ? String(format: "%.1f", 20 * log10f(rms)) : "-inf")
                    sums[ch] = 0
                }
                buffers = 0
                // Not `MainActor.assumeIsolated` — this runs on AVFoundation's tap
                // queue, and asserting main isolation there is a SIGTRAP fifteen
                // seconds after play, which is exactly how the first build died.
                if playing.withLock({ $0 }) { TVLog.note("levels dBFS [\(count) ch]: \(line.joined(separator: " "))") }
            }
        }
    }

    /// Tear down and rebuild for a different channel count. The engine's voices
    /// live in the kernel, not the graph, so the drone comes back mid-note.
    private func rebuildGraph() {
        let wasPlaying = running
        audio.stop()
        audio.mainMixerNode.removeTap(onBus: 0)
        for n in busNodes + wetNodes { audio.detach(n) }
        busNodes.removeAll(); wetNodes.removeAll()
        if let sourceNode { audio.detach(sourceNode) }
        sourceNode = nil
        if environment.engine != nil { audio.detach(environment) }
        for p in wetScratch { p.deallocate() }
        wetScratch.removeAll()
        pump = nil
        buildGraph()
        if wasPlaying {
            do { try audio.start() } catch { lastError = "Couldn't restart audio — \(error.localizedDescription)" }
            pump?.resync()
        }
    }

    private func applyField() {
        guard surround else { return }
        let field = model.field
        guard abs(field.radius - placedField.radius) > 0.01
                || abs(field.lift - placedField.lift) > 0.1
                || !placedFieldValid else { return }
        placedField = field
        placedFieldValid = true
        for (bus, node) in busNodes.enumerated() { node.position = field.position(bus: bus) }
        // The tail, wide and a little behind, at the ring's own radius.
        let r = Float(max(0.2, field.radius))
        for (side, node) in wetNodes.enumerated() {
            let az = (side == 0 ? -110.0 : 110.0) * Double.pi / 180
            node.position = AVAudio3DPoint(x: r * Float(sin(az)), y: 0.3, z: -r * Float(cos(az)))
        }
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    }

    /// Flow ramps Radius and Lift at 10 Hz; eighteen positions rewritten into a
    /// running graph for a millimetre is lock traffic for nothing audible.
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

    // MARK: - Route and session

    private func routeChanged() {
        let before = channels
        negotiateChannels()
        if channels != before || (surround != engine.spatialEnabled) {
            TVLog.note("route change rebuilt the graph: \(before) → \(channels) ch")
            rebuildGraph()
        } else if running, !audio.isRunning {
            recover()
        }
        pump?.resync()
        if running { showCaption() }
    }

    private func recover() {
        guard running, !audio.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try audio.start()
            pump?.resync()
            TVLog.note("recovered a stopped engine")
        } catch {
            lastError = "Audio stopped — \(error.localizedDescription)"
            TVLog.note("recover failed: \(error.localizedDescription)")
        }
    }

    private func watchSession() {
        let centre = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                // A television has few interruptions; Siri is the one. Stopping is
                // the honest response — the tail rings out and play starts again.
                if type == .began, self.running { self.stop() }
            }
        })
        observers.append(centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildGraph() }
        })
        observers.append(centre.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
        ) { [weak self] _ in
            // The output format may have changed under us (a receiver waking
            // up mid-session is the common case). Re-negotiate; rebuild if the
            // channel count moved, otherwise just restart.
            MainActor.assumeIsolated { self?.routeChanged() }
        })
    }

    // MARK: - Transport

    func start() {
        guard transport == .idle else { return }
        // The phone's last key, if it has said — so the room never opens where
        // the pocket left off. Flow reads this default in `chooseFreshKey`.
        if let key = cloud.lastKey() {
            UserDefaults.standard.set(key, forKey: FlowDirector.lastKeyDefault)
        }
        cloud.pull()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audio.mainMixerNode.outputVolume = 1
            try audio.start()
        } catch {
            lastError = "Couldn't start audio — \(error.localizedDescription)"
            TVLog.note("START FAILED — \(error.localizedDescription)")
            return
        }
        lastError = nil
        pump?.resync()
        model.flow.start()
        transport = .playing
        playing.withLock { $0 = true }
        idleGuard.hold()
        showCaption()
        updateNowPlaying()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        TVLog.note("START — v\(v) (\(b)), \(bufferReport), route \(routeName), \(channels) ch, spatial \(engine.spatialEnabled), reported EDR \(String(format: "%.2f", headroom))×, \(model.harmony.subtitle)")
    }

    /// Let go. The tail is up to thirty seconds and it rings out; the engine
    /// keeps running so that it can.
    func stop() {
        guard running else { return }
        model.flow.stop()
        model.fadeAll()
        transport = .idle
        playing.withLock { $0 = false }
        idleGuard.release()
        hideCaption()
        updateNowPlaying()
        TVLog.note("STOP")
    }

    func toggle(from source: String = "screen") {
        // One physical button can arrive twice — as a UIPress and as a Now
        // Playing command — and two toggles in the same instant are a start
        // followed by a stop, which looks like a button that does nothing.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastToggle < 0.4 {
            TVLog.note("\(source) → ignored (duplicate within 400 ms)")
            return
        }
        lastToggle = now
        TVLog.note("\(source) → \(running ? "stop" : "start")")
        running ? stop() : start()
    }

    /// Home was pressed. Nobody wants a drone under the tvOS home screen, and
    /// tvOS has no background audio for an engine anyway.
    func sceneWentBackground() {
        stop()
        audio.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func sceneBecameActive() {
        cloud.pull()
    }

    // MARK: - Caption

    /// One line, for a few seconds after a start or a route change: what it is
    /// playing and what it is playing into. The only text the screen ever shows
    /// while running, and it fades — this is a thing you leave on.
    /// Also reachable from the remote: a press down shows it, as Aerial does.
    func showCaption() {
        // What the graph renders, not what the session counts: the session on an
        // Apple TV says 32.
        let room = surround ? "5.1" : "Stereo"
        let port = portWord
        captionedSubtitle = model.harmony.subtitle
        caption = "\(model.harmony.subtitle)  ·  \(room)\(port.isEmpty ? "" : "  ·  \(port)")"
        captionVisible = true
        captionTimer?.invalidate()
        // Twenty seconds: long enough to read across a room and look back, and
        // it comes back on its own at the next change. Nine was gone before
        // anyone looked up, which read as "the text is missing".
        captionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.captionVisible = false }
        }
        TVLog.note("caption: \(caption)")
    }

    private func hideCaption() {
        captionTimer?.invalidate()
        captionVisible = false
    }

    // MARK: - Remote

    /// Play/pause on the Siri Remote arrives here as well as through SwiftUI's
    /// `onPlayPauseCommand`, and this is what Control Center and "Hey Siri,
    /// pause" reach.
    private func registerRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()
        func onMain(_ f: @escaping @MainActor () -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            return { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
                return .success
            }
        }
        // Every path logs its name. The play/pause failure was diagnosed from a
        // STOP with no press before it — the one path that did not log — so
        // now none is silent.
        //
        // And the finding those logs produced: once this app is the Now Playing
        // app, tvOS delivers the remote's play/pause button as `pauseCommand`
        // **every time, whatever state we are in** — eleven pauses in a row
        // against a stopped drone, never a `playCommand`, never a toggle. So a
        // pause when nothing is playing means "play": every one of these is
        // the same toggle, and `toggle` is the only decision-maker. The 400 ms
        // debounce there covers a press that arrives by two paths at once.
        centre.playCommand.addTarget(handler: onMain { [weak self] in self?.toggle(from: "now-playing play") })
        centre.pauseCommand.addTarget(handler: onMain { [weak self] in self?.toggle(from: "now-playing pause") })
        centre.stopCommand.addTarget(handler: onMain { [weak self] in
            TVLog.note("now-playing stop"); self?.stop() })
        centre.togglePlayPauseCommand.addTarget(handler: onMain { [weak self] in self?.toggle(from: "now-playing toggle") })
        for command in [centre.nextTrackCommand, centre.previousTrackCommand,
                        centre.skipForwardCommand, centre.skipBackwardCommand,
                        centre.seekForwardCommand, centre.seekBackwardCommand,
                        centre.changePlaybackPositionCommand, centre.likeCommand,
                        centre.dislikeCommand, centre.bookmarkCommand,
                        centre.changeRepeatModeCommand, centre.changeShuffleModeCommand] {
            command.isEnabled = false
        }
    }

    private func updateNowPlaying() {
        // The state property, not just the dictionary — the phone learned that a
        // dictionary alone leaves the system's idea of play/pause stale, and here
        // that idea is what decides which command the button sends.
        MPNowPlayingInfoCenter.default().playbackState = running ? .playing : .paused
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Thrum",
            MPMediaItemPropertyArtist: model.harmony.subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: running ? 1.0 : 0.0,
        ]
    }

    // MARK: - Field for the visualizer

    /// Bridges the engine's meters into the wash shader once per frame — through
    /// a smoother, because the meters are the render thread's per-block peaks and
    /// they flutter. Fed raw, that flutter became the picture's: every wave's
    /// amplitude twitched at block rate, and a voice crossing the audibility
    /// threshold snapped in or out of the normalised sum in one frame. Jeff's
    /// word for it was "jittery".
    ///
    /// So each voice's level is a one-pole with a slow attack and a slower
    /// release (a swell arrives over a second, a voice leaves over two), the
    /// master follows the same way, and the mode's hue turns the shortest way
    /// round the wheel over about eight seconds rather than jumping when Flow
    /// changes mode. Voices stay in the sum until their *smoothed* level has
    /// died, so nothing appears or disappears between two frames. Reads the
    /// meter array as the benign race on `Float`s the phone and Mac use.
    ///
    /// What the shader gets per voice: the scale degree as a position across
    /// (it becomes a wave direction), the octave tier (a wavelength), the
    /// smoothed level and hue, and a seed so no two waves share a phase.
    func fillWash(_ voices: inout [WashVoice]) -> (count: Int32, master: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(min(max(now - lastWashTime, 0), 0.25))
        lastWashTime = now
        // Attack ~0.9 s, release ~2.2 s, hue ~8 s (time to 63%).
        let up = 1 - expf(-dt / 0.9)
        let down = 1 - expf(-dt / 2.2)
        let hueK = 1 - expf(-dt / 8)

        let targetHue = Float(model.harmony.mode.hue)
        var delta = targetHue - smoothHue
        delta -= roundf(delta)                    // shortest way round the wheel
        smoothHue += delta * hueK
        smoothHue -= floorf(smoothHue)

        let rawMaster = min(1, engine.meters[DroneEngine.voiceCount])
        smoothMaster += (rawMaster - smoothMaster) * (rawMaster > smoothMaster ? up : down)

        var written = 0
        for v in 0..<DroneEngine.voiceCount {
            let raw = min(1, powf(max(engine.meters[v], 0), 0.55) * 1.35)
            let s = smoothLevel[v]
            let k = raw > s ? up : down
            smoothLevel[v] = s + (raw - s) * k
            let level = smoothLevel[v]
            if level <= 0.002 { smoothLevel[v] = level < 0.0005 ? 0 : level; continue }
            let bus = DroneEngine.bus(pad: v)
            let tier = bus / SpatialField.azimuths
            let col = bus % SpatialField.azimuths
            let row = v / Harmony.cols
            let x = (Float(col) - 3.5) / 3.5 * 0.82
            var y: Float = tier == 0 ? -0.34 : 0.30
            y += (row % 2 == 0) ? -0.09 : 0.09
            voices[written].anchor = simd_float2(x, y)
            voices[written].lh = simd_float2(level, smoothHue)
            voices[written].sp = simd_float2(fmodf(Float(v) * 0.6180339, 1), Float(tier))
            written += 1
            if written == 32 { break }
        }
        return (Int32(written), smoothMaster)
    }

    /// Called by the renderer once per frame; logs only on change, so the log
    /// records the set switching modes and nothing else.
    func noteHeadroom(_ value: Float) {
        guard abs(value - headroom) > 0.01 else { return }
        let first = headroom == 0
        headroom = value
        TVLog.note("screen reports EDR headroom \(String(format: "%.2f", value))× (unusable by a Metal layer on tvOS; picture is SDR P3)\(first ? "" : " (changed)")")
    }

    var bufferReport: String {
        let session = AVAudioSession.sharedInstance()
        let frames = Int((session.ioBufferDuration * session.sampleRate).rounded())
        return String(format: "%.0f kHz · %d frames · %.0f ms",
                      session.sampleRate / 1000, frames, session.ioBufferDuration * 1000)
    }
}

/// One engine render per audio cycle from eighteen render callbacks. Keys on the
/// timestamp rather than nominating a leader node, because callback order between
/// a mixer's inputs is not guaranteed. Holds no Swift collections and is not
/// `@MainActor` — the render thread touches it.
private final class SurroundPump: @unchecked Sendable {
    let engine: DroneEngine
    private var lastSampleTime: Double = -1

    init(engine: DroneEngine) { self.engine = engine }

    func resync() { lastSampleTime = -1 }

    @inline(__always)
    func renderIfNeeded(_ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: Int) {
        let t = timestamp.pointee.mSampleTime
        if t != lastSampleTime {
            lastSampleTime = t
            engine.renderSpatial(frameCount: frames)
        }
    }
}

/// A flight recorder with one job: say what the room gave us. There is no
/// console within reach of an Apple TV, so `./build.sh tvlog` pulls this off the
/// device — the channel count on the LAUNCH line is the whole verification of
/// "is it really 5.1".
enum TVLog {
    private static let log = Logger(subsystem: "com.jeffhobbs.thrumflow", category: "tv")
    private static let queue = DispatchQueue(label: "com.jeffhobbs.thrum.tvlog", qos: .utility)
    private static let url: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Thrum/tv.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func note(_ line: String) {
        log.notice("\(line, privacy: .public)")
        guard let url else { return }
        let text = "\(stamp.string(from: Date()))  \(line)\n"
        queue.async {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
}
