import SwiftUI
import AVFoundation
import Accelerate
import MediaPlayer
import Combine
import OSLog
import simd

/// A requested IO buffer duration is a hint, not a promise, and the whole
/// battery argument for this app rests on getting a big one — so what the session
/// actually granted is logged rather than assumed.
private let log = Logger(subsystem: "com.jeffhobbs.thrumflow", category: "audio")

/// Thrum on a phone: the engine, Flow, and nothing to play.
///
/// The Mac app is an instrument you perform. This is the same engine left to
/// perform itself — Flow drives it, the screen shows what it is doing, and the
/// only decisions left to a listener are start, stop and how loud.
///
/// **Where the battery actually goes, measured rather than assumed.**
/// `Tools/budget` renders Flow at 78× realtime with the 16-bus HRTF path costing
/// only ~9% more than stereo, which puts the audio thread near 1.3% of one core.
/// Flow also turns out to hold a median of *five* voices out of 32 (p95 of ten),
/// and essentially all of them are audible — 4.3 within 30 dB of the loudest. So
/// there was no honest voice cut to make here: reducing the count would remove
/// music you can hear to save something that was not costing anything. The
/// savings in this file are all in wakeups and pixels instead:
///
/// 1. **A very long IO buffer.** Nothing in this app responds to touch in
///    musical time, so latency is free to spend — and a big buffer means the CPU
///    wakes a few times a second instead of a hundred. This is the single
///    biggest audio-side win available and it costs nothing perceptible.
///    *Asked for on every route, not just at launch* — the flight recorder caught
///    this claim being false on AirPods for the life of the app, which is the one
///    route the spatial path exists for. See `requestLongBuffer`.
/// 2. **Spatial only on headphones.** Not primarily for the 9%: binaural
///    rendering over a phone speaker is actively worse than stereo, for the same
///    reason the Mac app grew `AudioRoute`. Free on both counts.
/// 3. **Idle fade.** After a few minutes untouched the field dims and the frame
///    rate drops to 6. The screen is the dominant drain on a device left running
///    for an hour, and a passive listener is not watching most of that time.
/// 4. **Paused, not throttled, in the background.** Audio continues; the GPU stops.
@MainActor
final class FlowHost: ObservableObject {
    /// One engine for the whole process.
    ///
    /// Needed because CarPlay arrives as a *second* UIScene with its own delegate,
    /// created by the system outside the SwiftUI hierarchy — so it cannot reach a
    /// `@StateObject`. Two `FlowHost`s would mean two audio engines fighting for
    /// the same session, which is the kind of bug that only shows up in a car.
    static let shared = FlowHost()

    static let activeFPS = 20
    static let idleFPS = 6
    /// Untouched for this long and the field fades back. Long enough not to
    /// interrupt someone actually watching it.
    static let idleAfter: TimeInterval = 150

    let engine = DroneEngine()
    let model: ThrumModel

    /// Idle → playing → paused ⇄ playing. There is no way back to `.idle` short of
    /// quitting, and that is deliberate: the ☯ is the invitation to begin, and once
    /// begun there is nothing left for it to invite. A listener who wants silence
    /// wants *pause*, with the drone still there to come back to.
    enum Transport: Equatable { case idle, playing, paused }

    @Published private(set) var transport: Transport = .idle

    /// Kept as the name the rest of the app already uses for "audio is coming out".
    /// Computed from `transport`, which is what publishes, so observers still update.
    var running: Bool { transport == .playing }
    /// True from the first tap onward. What the ☯ is gated on.
    var hasStarted: Bool { transport != .idle }

    @Published private(set) var visualizerRunning = true
    @Published private(set) var idle = false
    /// Why the drone didn't start, shown on screen.
    ///
    /// `start()` originally caught its errors and returned, which on a phone is
    /// indistinguishable from a broken button and leaves nothing to look at — and
    /// reading the device log needs a cable and admin rights. Anything that stops
    /// this app from doing its one job should say so on the screen it already has.
    @Published private(set) var lastError: String?
    /// Shader brightness. Ramped rather than switched — a screen that snaps to
    /// half brightness reads as a glitch.
    @Published private(set) var dim: Float = 1

    var targetFPS: Int { idle ? Self.idleFPS : Self.activeFPS }

    private let audio = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let environment = AVAudioEnvironmentNode()
    private var busNodes: [AVAudioSourceNode] = []
    private var wetNode: AVAudioSourceNode?
    private var pump: SpatialPump?
    private var sampleRate: Double = 48000

    private var lastTouch = Date()
    private var idleTimer: Timer?
    private var artworkTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var harmonyWatch: AnyCancellable?
    private var fieldDirty = false
    /// Set only when an interruption is what paused us, so that when it ends we
    /// resume — and a pause the listener asked for stays paused.
    private var resumeWhenInterruptionEnds = false

    /// Spatial-path bookkeeping — see `placeListener` and `applyField`.
    private var listenerFacing = (forward: simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))
    private var lastListenerWrite: CFTimeInterval = 0
    private var placedField = SpatialField()
    private var placedFieldValid = false

    /// Flight-recorder counters, sampled and reset by the heartbeat.
    private var motionUpdates = 0
    /// How many of those motion updates got past the dead band and the rate cap to
    /// actually re-point sixteen HRTFs. Logged next to `motionUpdates` because the
    /// ratio is the interesting part: a session where nearly every sample writes is a
    /// session where the input is never still, which is not what a head does.
    private var listenerWrites = 0
    private var lastOverruns: Int32 = 0
    private var heartbeat: Timer?
    private var fadeTimer: Timer?
    /// Clears the filled-in star — see `acknowledge`.
    private var feedbackFlashTimer: Timer?
    /// Watches the real output amplitude for the reported symptom — see `DropoutWatch`.
    private let dropoutWatch = DropoutWatch()
    /// The last five minutes of audio and head, for the "I heard it" gesture.
    private let markBuffer = MarkBuffer()
    private var marksThisSession = 0
    private var dropoutDrain: Timer?
    /// Reused so the artwork pass allocates nothing per refresh.
    private let artScratch = [ShaderVoice](repeating: ShaderVoice(), count: 32)

    init() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback so it keeps going with the screen locked, and does not
            // duck or stop for the silent switch — this is the whole point of a
            // passive drone. Not .mixWithOthers: a 30-second reverb tail layered
            // under someone's podcast is nobody's intention.
            try session.setCategory(.playback, mode: .default, options: [])
            // Before `setActive`, which is when the session configures its IO.
            Self.requestLongBuffer()
            try session.setActive(true)
        } catch {
            // Non-fatal: the engine still runs at whatever the session gives us.
        }

        var sr = session.sampleRate
        if sr < 8000 { sr = 48000 }
        sampleRate = sr
        engine.setSampleRate(sr)

        // The one place the taste database is given somewhere to live. `ThrumModel`
        // defaults to an in-memory one that learns nothing and biases nothing, so
        // the offline harnesses keep measuring Flow rather than Flow-plus-whatever-
        // was-liked-last-week — persistence is a decision a host makes, and this is
        // the host with the buttons.
        model = ThrumModel(engine: engine, taste: Taste(store: Taste.defaultStore))
        // There is no grid on a phone, so nothing but Flow ever sets the key —
        // which without this means the default one, forever, in every session.
        model.flow.picksKeyOnStart = true
        model.onRenderModeChange = { [weak self] in self?.applyRenderMode() }
        // Without this the field is welded in place at whatever `SpatialField`
        // defaults to. Flow's Field gesture ramps Radius and Lift every couple of
        // minutes; on the phone none of it reached the graph, because nothing was
        // listening for the geometry to change — the Mac wires this and iOS never
        // did. Half of "the spatial effect is very subtle" was that.
        model.onFieldChange = { [weak self] in self?.scheduleFieldUpdate() }
        model.route.onChange = { [weak self] in self?.routeChanged() }
        model.head.onOrientation = { [weak self] head in
            self?.placeListener(head)
        }

        buildGraph()
        watchSession()
        configureRemoteCommands()
        watchHarmony()
        updateNowPlaying()
    }

    /// Whether iOS is applying its **own** head-tracked spatialisation on top of ours.
    ///
    /// This is the one thing in the signal path that every instrument in this app is
    /// blind to, and it is blind for a structural reason: it happens *after* the audio
    /// leaves us. `gaps`, `overruns`, `load`, `clamped`, `peak` and the sixteen HRTFs
    /// all describe a stereo pair that has already been handed to the system, and the
    /// 08-13 flight log says every one of them was perfect for forty-two minutes while
    /// a listener was hearing tones drop out.
    ///
    /// Thrum renders its own binaural field. If "Spatialize Stereo" is enabled for the
    /// route — a per-route user setting, reachable by long-pressing the volume slider
    /// in Control Centre — then iOS takes that finished binaural mix and spatialises it
    /// *again*, head-tracked, against its own model of where the head is. Two
    /// head-tracked HRTFs in series, each moving the image as the head turns, is not a
    /// configuration anyone designed; what it sounds like is not predictable from
    /// either one alone, and extreme head angles are exactly where two disagreeing
    /// models disagree most.
    ///
    /// There is no API to refuse it on iOS — `setIntendedSpatialExperience` is
    /// visionOS-only — so this is read and recorded rather than set. A single word in
    /// the log settles a question that four offline harnesses could not.
    private var systemSpatialization: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.isSpatialAudioEnabled }
    }

    /// The same fact, on the screen instead of in a log file.
    ///
    /// It was written to the flight log for three investigations running and read
    /// by nobody at the time it mattered, which is the wrong place for it. Every
    /// heartbeat of the 08-15 session says `system-spatial ON`, and the note left
    /// after the 08-14 one says in as many words to rule it out first — so the one
    /// walk that was supposed to settle whether this is the cause was run with it
    /// on, and cannot. A file that has to be pulled off the phone over USB cannot
    /// remind anyone of anything before a walk; a line on the screen can.
    ///
    /// Only shown when it actually matters — Thrum rendering its own binaural field
    /// into a system that is about to spatialise it again. On speakers, or with the
    /// field off, iOS doing this is not a conflict and the warning would be noise.
    @Published private(set) var systemSpatialConflict = false

    private func refreshSpatialConflict() {
        systemSpatialConflict = engine.spatialEnabled && systemSpatialization
    }

    /// Ask for a long IO buffer — again, because asking once is not enough.
    ///
    /// ~85 ms. Latency is worthless to this app and expensive to hold, so it is traded
    /// straight for fewer wakeups, and the doc comment at the top of this file rests
    /// on getting it. iOS treats the request as a hint, so what it granted is read
    /// back rather than assumed.
    ///
    /// It has to be re-asked on every route change, and that is the defect this was
    /// pulled out of `init` to fix. The preference was set once, at launch, when the
    /// route is whatever the phone was last using — and a preference set against one
    /// route does not survive being moved to another. The flight recorder shows the
    /// result plainly: every built-in-speaker session in the log reads
    ///
    ///     48 kHz · 4080 frames · 85 ms
    ///
    /// and every AirPods session reads
    ///
    ///     48 kHz · 480 frames · 10 ms
    ///
    /// So the one route the spatial path exists for is the one route that never got
    /// the buffer, and the whole graph — engine plus sixteen HRTFs — has been running
    /// at 100 wakeups a second instead of twelve. Whether iOS will grant 85 ms over
    /// Bluetooth at all is its decision and not ours; asking costs nothing, and the
    /// heartbeat reports what actually came back either way.
    ///
    /// Static because it touches only the shared session, which lets `init` call it
    /// before the rest of `self` exists — and the one place the request is certain to
    /// be honoured is before the session is first activated.
    private static func requestLongBuffer() {
        do {
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.085)
        } catch {
            log.error("buffer request refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Graph

    private func buildGraph() {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

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

        // Built up front, exactly as on the Mac and for the same reason: attaching
        // seventeen nodes to a running engine is what glitches the render thread,
        // and the HRTF stage costs ~9% when idle. Switching modes is then a bool.
        let pump = SpatialPump(engine: kernel)
        self.pump = pump
        audio.attach(environment)
        audio.connect(environment, to: audio.mainMixerNode, format: stereo)

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
            busNode.renderingAlgorithm = .HRTF
            busNodes.append(busNode)
        }

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

        applyField()
        applyRenderMode()
        installDropoutTap()
    }

    /// One tap on the main mixer, computing a single RMS per buffer.
    ///
    /// Cheap enough to leave on for a two-hour walk, which is the only kind of run
    /// where this fault has ever been heard: one `vDSP_measqv` per channel per buffer
    /// on a callback that is already happening. No allocation, no logging, no lock.
    private func installDropoutTap() {
        let mixer = audio.mainMixerNode
        let watch = dropoutWatch
        let marks = markBuffer
        let rate = sampleRate
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, when in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n = vDSP_Length(buffer.frameLength)
            var power: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                var p: Float = 0
                vDSP_measqv(data[ch], 1, &p, n)
                power += p
            }
            let db = 10 * log10(max(power, 1e-12))
            watch.observe(db, at: Double(when.sampleTime) / rate)
            marks.record(db, seconds: Float(Double(buffer.frameLength) / rate))
        }
    }

    /// Where the listener is facing.
    ///
    /// Two guards on the way to the graph, and both are about how much work a
    /// rotating listener costs rather than about the angle itself. Moving the
    /// listener invalidates the HRTF for **all sixteen sources at once**, so this is
    /// the single most expensive property in the whole spatial path — and it is
    /// written from the main thread into a graph the render thread is reading.
    ///
    /// - A **dead band**: sub-third-of-a-degree changes are dropped. Standing still
    ///   with AirPods in still produces a continuous jitter of tiny attitude
    ///   updates, and every one of them was recomputing sixteen HRTFs to move the
    ///   image by less than the ear can localise.
    /// - A **rate cap**: at most one write per 45 ms. With an ~85 ms IO buffer the
    ///   render thread only reads this a dozen times a second, so anything faster is
    ///   provably discarded — it costs a lock against the audio thread to write a
    ///   value nothing will ever read. The one-pole smoother in `HeadTracker` is
    ///   what keeps the motion continuous between writes; this only decides how
    ///   often the result is handed over.
    ///
    /// Neither changes what a head turn sounds like. Both cut the traffic on a live
    /// graph by roughly half while walking, and to nearly nothing while still.
    private func placeListener(_ head: HeadOrientation) {
        motionUpdates += 1
        // The handedness reconciliation that used to be three negations here now lives
        // in `HeadSmoother.toListener`, so this only decides how often to hand the
        // result over.
        let want = head.orientation
        let f = simd_float3(want.forward.x, want.forward.y, want.forward.z)
        let u = simd_float3(want.up.x, want.up.y, want.up.z)
        // The dead band, on unit vectors instead of summed Euler angles. Chord length
        // is the rotation angle to well within a rounding error at this size, and it
        // needs no trig; taking the larger of the two axes means a pure roll (which
        // leaves `forward` alone entirely) is measured rather than ignored.
        let moved = max(simd_length(f - listenerFacing.forward),
                        simd_length(u - listenerFacing.up)) * 180 / .pi
        guard moved > 0.3 else { return }
        let now = CACurrentMediaTime()
        guard now - lastListenerWrite > 0.045 else { return }
        lastListenerWrite = now
        listenerWrites += 1
        listenerFacing = (f, u)
        // So a drop detected on the audio thread can say where the head was pointing.
        let gaze = asin(max(-1, min(1, Double(f.y)))) * 180 / .pi
        dropoutWatch.gaze = gaze
        markBuffer.currentGaze = gaze
        markBuffer.currentRaw = model.head.rawTilt
        environment.listenerVectorOrientation = want
    }

    private func applyField() {
        let field = model.field
        // Same reasoning as the listener, one level down: Flow ramps Radius and Lift
        // continuously, and rewriting sixteen source positions for a change of a
        // millimetre is lock traffic against the render thread in exchange for
        // nothing audible. A centimetre and a tenth of a degree are both well under
        // what can be heard at these distances.
        guard abs(field.radius - placedField.radius) > 0.01
                || abs(field.lift - placedField.lift) > 0.1
                || !placedFieldValid else { return }
        placedField = field
        placedFieldValid = true
        for (bus, node) in busNodes.enumerated() { node.position = field.position(bus: bus) }
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    }

    /// Coalesce geometry updates, for the reason the Mac host does: Flow ramps at
    /// 10 Hz and each update rewrites sixteen node positions from the main thread,
    /// straight into a running graph. Mark dirty, apply at most every 40 ms —
    /// geometry is not something you can hear arriving late.
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

    private func applyRenderMode() {
        switch model.spatialRender {
        case .auto:       environment.outputType = model.route.environmentOutputType
        case .headphones: environment.outputType = .headphones
        case .speakers:   environment.outputType = .externalSpeakers
        }
    }

    /// Spatial follows the route rather than a preference.
    ///
    /// On headphones it is the best version of this app. Over the phone's own
    /// speaker it is strictly worse than stereo — a binaural image collapses to a
    /// point at arm's length — so there is nothing to weigh up.
    private func routeChanged() {
        // Before anything else: a new route comes with a new IO buffer, and the
        // preference does not follow it across. See `requestLongBuffer`.
        Self.requestLongBuffer()
        // A route change reconfigures the IO unit, so the output clock restarts. That
        // is not a dropout, and counting it as one would put a gap in the log next to
        // every pair of AirPods going in.
        pump?.resync()
        applyRenderMode()
        let wantSpatial = !model.route.isRoom
        if engine.spatialEnabled != wantSpatial {
            engine.spatialEnabled = wantSpatial
            // Worth recording rather than assuming benign: this swaps the entire
            // signal path — sixteen HRTF buses against one stereo pair — with no
            // crossfade. Rare and inaudible if the route genuinely changed; a
            // sequence of these in the log during a walk would be its own answer.
            FlightRecorder.shared.note("spatial \(wantSpatial ? "ON" : "OFF") — route now \(model.route.name)")
            if wantSpatial {
                placedFieldValid = false
                applyField()
            }
        } else {
            FlightRecorder.shared.note(
                "route → \(model.route.name), system-spatial \(systemSpatialization ? "ON" : "off")")
        }
        refreshSpatialConflict()
        updateHeadTracking()
    }

    /// Head tracking follows the route, exactly as spatial rendering does, and for
    /// the same reason: there is no UI on a phone to turn it on with.
    ///
    /// This was the other half of the subtle field. A head-locked HRTF field is
    /// mostly heard as filtering — it is the drone *staying put while your head
    /// turns* that makes it sit in the room rather than in your ears, and that is
    /// the one cue the phone was never giving. The Mac has a toggle for this and
    /// nothing on iOS ever set it, so it defaulted off for the entire life of the
    /// app on the device the feature was written for.
    ///
    /// Gated on `running` because CoreMotion is not free: reading AirPods
    /// orientation twenty-five times a second to rotate a listener that has
    /// nothing to listen to is exactly the kind of wakeup the rest of this file is
    /// written to avoid. Denied permission, or headphones that don't report
    /// motion, degrade to the head-locked field with nothing to handle here —
    /// `HeadTracker` sorts itself out and reports why.
    private func updateHeadTracking() {
        let want = running && !model.route.isRoom
        if model.headTracking != want {
            model.headTracking = want
            FlightRecorder.shared.note("head tracking \(want ? "ON" : "OFF") — \(model.head.status)")
        }
    }

    /// One line every thirty seconds, which is the whole diagnostic.
    ///
    /// Cheap enough to leave on for a two-hour walk: reading three counters and
    /// appending a formatted line on a utility queue. Deliberately *not* gated on
    /// the screen being awake — the interesting failures happen with the phone in a
    /// pocket, which is exactly when nothing else in this app is observing anything.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        lastOverruns = engine.renderOverruns
        motionUpdates = 0
        // Starting or resuming moves the output clock legitimately; don't bill it as
        // a dropped cycle. Called here because this runs on every start and resume.
        pump?.resync()
        _ = pump?.drainGaps()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        // Drained often, because the value of this line is that it sits next to the
        // moment it happened rather than inside a thirty-second average.
        dropoutDrain?.invalidate()
        dropoutDrain = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let note = self?.dropoutWatch.drain() else { return }
                FlightRecorder.shared.note(note)
            }
        }
    }

    private func beat() {
        var sample = FlightSample()
        sample.load = engine.renderLoad
        sample.overruns = engine.renderOverruns - lastOverruns
        sample.motionUpdates = motionUpdates
        sample.route = model.route.name.isEmpty ? "(no route)" : model.route.name
        sample.spatial = engine.spatialEnabled
        sample.tracking = model.head.status == .tracking
        sample.transport = transportName
        sample.buffer = bufferReport
        let head = model.head.drainDiagnostics()
        sample.peakRate = head.peak
        sample.clampedFrames = head.clamped
        sample.peakTilt = head.peakTilt
        sample.tiltLow = head.tilt.lowest
        sample.tiltHigh = head.tilt.highest
        sample.tiltMedian = head.tilt.median
        sample.rawLow = head.raw.lowest
        sample.rawHigh = head.raw.highest
        sample.rawMedian = head.raw.median
        sample.stalls = head.stalls
        sample.longestStallMilliseconds = head.longestStall * 1000
        sample.tiltAtStall = head.tiltAtStall
        sample.systemSpatial = systemSpatialization
        sample.listenerWrites = listenerWrites
        listenerWrites = 0
        if let gaps = pump?.drainGaps() {
            sample.gaps = gaps.count
            sample.gapMilliseconds = Double(gaps.frames) / sampleRate * 1000
            sample.largestGapMilliseconds = Double(gaps.largest) / sampleRate * 1000
        }
        lastOverruns = engine.renderOverruns
        motionUpdates = 0
        FlightRecorder.shared.note(sample.line)
    }

    // MARK: - Transport

    func start() {
        guard transport == .idle else { return }
        // Before `audio.start()`, and that ordering is the point: a buffer preference
        // is honoured when the IO unit is configured, so asking after the engine is
        // already running gets the request filed for next time rather than applied
        // now. By here the route is known, which it was not at launch.
        Self.requestLongBuffer()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            // A session that was paused and then stopped leaves the mixer turned
            // down. Nothing else restores it, so a fresh start would come up silent
            // and look like the engine had failed.
            fadeTimer?.invalidate()
            fadeTimer = nil
            audio.mainMixerNode.outputVolume = 1
            try audio.start()
        } catch {
            lastError = "Couldn't start audio — \(error.localizedDescription)"
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            FlightRecorder.shared.note("START FAILED — \(error.localizedDescription)")
            return
        }
        lastError = nil
        routeChanged()
        model.flow.start()
        transport = .playing
        // After `running`, not inside the `routeChanged()` above: head tracking is
        // gated on it, and asked a moment too early the answer is always no.
        updateHeadTracking()
        touched()
        startIdleWatch()
        startArtworkRefresh()
        startHeartbeat()
        updateNowPlaying()
        // The version belongs on this line because the log outlives the build that
        // wrote it. Diagnosing the head-tracking warble started by reading a copy that
        // had been pulled off the phone three days earlier, from a build whose
        // heartbeat had different fields — recoverable, but only after noticing.
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        FlightRecorder.shared.note("START — v\(v) (\(b)), \(bufferReport), route \(model.route.name), spatial \(engine.spatialEnabled), system-spatial \(systemSpatialization ? "ON" : "off"), \(model.harmony.subtitle)")
        // The moment worth telling the listener, if it is going to be told at all:
        // they have just started a session and are still looking at the screen.
        refreshSpatialConflict()
        // The key is in here because it is now chosen rather than fixed, and with
        // the controls hidden there is otherwise nothing that says which one a
        // given session got — on a phone, with no console in reach, "it sounds
        // like it's always in D" was the only symptom available.
        log.notice("started — \(self.bufferReport, privacy: .public), route \(self.model.route.name, privacy: .public), spatial \(self.engine.spatialEnabled), head-tracking \(self.model.headTracking), \(self.model.harmony.subtitle, privacy: .public)")
    }

    /// Hold it. The drone is still there, exactly as it was.
    ///
    /// `audio.pause()` rather than `audio.stop()` — pause keeps the render graph and
    /// every node's state intact, so resuming picks the same voices up mid-envelope;
    /// stop tears the graph's state down and comes back to silence that has to be
    /// rebuilt. Flow's clock stops with it, so a fifty-second slide that was
    /// thirty seconds in is still thirty seconds in when the audio returns.
    ///
    /// Deliberately *not* `fadeAll()`. Letting go is what `stop()` does and it is a
    /// different intention: fading every voice out means resuming would have to
    /// swell them all back in, which is a noticeable event at both ends. Pause
    /// should be as close to a held breath as the engine allows.
    func pause() {
        guard transport == .playing else { return }
        transport = .paused
        FlightRecorder.shared.note("PAUSE")
        // The clock stops with the sound, not before it: freezing Flow first would
        // hold the last 180 ms of the drone perfectly still while it faded, which is
        // a subtly different thing to hear than a drone being taken away.
        fade(to: 0, over: Self.fadeOut) { [weak self] in
            guard let self else { return }
            self.model.flow.pause()
            self.audio.pause()
        }
        // Nothing is being placed in a room that has gone quiet.
        updateHeadTracking()
        artworkTimer?.invalidate()
        updateNowPlaying()
    }

    func resume() {
        guard transport == .paused else { return }
        // If the fade-out is still in flight the engine was never actually paused,
        // and `fade` has already cancelled the pending pause — so this becomes a
        // turn back up from wherever it had got to, with no restart at all.
        do {
            // The category as well as the activation, and that is not belt and
            // braces. A session can come back from an interruption, a media-services
            // reset or a CarPlay connect with a category that is no longer ours, and
            // `setActive` on a session configured for something else is exactly the
            // throw that turns a play button into a no-op. Setting it is idempotent
            // when it is already right.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            if !audio.isRunning {
                audio.mainMixerNode.outputVolume = 0
                try audio.start()
            }
        } catch {
            lastError = "Couldn't resume audio — \(error.localizedDescription)"
            log.error("resume failed: \(error.localizedDescription, privacy: .public)")
            // In the log too, not only in OSLog: OSLog needs a cable and a Mac, and
            // this is a failure that happens in a car and is discovered afterwards.
            FlightRecorder.shared.note("RESUME FAILED — \(error.localizedDescription)")
            return
        }
        lastError = nil
        transport = .playing
        FlightRecorder.shared.note("RESUME")
        model.flow.resume()
        fade(to: 1, over: Self.fadeIn)
        updateHeadTracking()
        touched()
        startArtworkRefresh()
        startHeartbeat()
        updateNowPlaying()
    }

    /// Short enough not to feel like a delay, long enough that neither end is a
    /// step. Coming back is slower than going away because it always sounds that
    /// way round — a sound arriving abruptly reads as a fault, a sound leaving
    /// abruptly only reads as a stop.
    private static let fadeOut = 0.18
    private static let fadeIn = 0.28

    /// Ride the mixer's output level, not the model's Output control.
    ///
    /// `mainMixerNode.outputVolume` belongs to the host, so a fade cannot leave the
    /// listener's own volume setting somewhere they didn't put it — which is exactly
    /// what would happen if this rode `masterVolume` and the app were killed
    /// mid-fade. It also keeps the promise that nothing but the listener ever
    /// touches that control.
    ///
    /// Smoothstep rather than linear: a linear amplitude ramp over 180 ms is audible
    /// as a corner at each end, because loudness is not linear in amplitude. Zero
    /// slope at both ends is what makes this read as the sound receding rather than
    /// being turned down.
    ///
    /// Starting a new fade cancels any fade in flight *and its completion*, which is
    /// what makes rapid play/pause safe: the pending `audio.pause()` from a
    /// half-finished fade-out never fires once a fade-in has taken over.
    private func fade(to target: Float, over duration: Double, then finish: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let mixer = audio.mainMixerNode   // read once for the starting value
        let from = mixer.outputVolume
        guard abs(target - from) > 0.001, duration > 0 else {
            mixer.outputVolume = target
            finish?()
            return
        }
        let start = CACurrentMediaTime()
        // The node is reached through `self` inside the tick rather than captured:
        // an `AVAudioMixerNode` is not `Sendable`, and a timer block is.
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let x = min(1, max(0, (CACurrentMediaTime() - start) / duration))
                let e = Float(x * x * (3 - 2 * x))
                self.audio.mainMixerNode.outputVolume = from + (target - from) * e
                guard x >= 1 else { return }
                timer.invalidate()
                self.fadeTimer = nil
                finish?()
            }
        }
    }

    /// The full stop: let go of every voice and end the session. Nothing in the UI
    /// reaches this any more — the transport is play/pause — but shutdown does, and
    /// it is the only correct way to end a journey rather than suspend one.
    func stop() {
        guard transport != .idle else { return }
        model.flow.stop()
        // Let the tail ring out rather than cutting it — this engine's reverb is
        // up to thirty seconds and chopping it is the least graceful thing the
        // app could do.
        model.fadeAll()
        transport = .idle
        // Stops the CoreMotion updates too — nothing is being placed any more.
        updateHeadTracking()
        idleTimer?.invalidate()
        artworkTimer?.invalidate()
        heartbeat?.invalidate()
        dropoutDrain?.invalidate()
        FlightRecorder.shared.note("STOP")
        withAnimation(.easeOut(duration: 0.6)) { dim = 1 }
        idle = false
        updateNowPlaying()
    }

    /// What every play/pause control in the app, on the lock screen and in the car
    /// funnels into. The first press starts a session; every press after that
    /// suspends or resumes one.
    func toggle(from source: String = "screen") {
        switch transport {
        case .idle:    FlightRecorder.shared.note("\(source) ⏯ → start"); start()
        case .playing: FlightRecorder.shared.note("\(source) ⏯ → pause"); pause()
        case .paused:  FlightRecorder.shared.note("\(source) ⏯ → resume"); resume()
        }
    }

    /// What a play button means, from a lock screen or a dashboard.
    ///
    /// Not simply `transport == .idle ? start() : resume()`, which is what this was,
    /// because that has a hole in it big enough to be the reported CarPlay bug. Both
    /// `start()` and `resume()` open with a guard on `transport` and return silently
    /// if it isn't the state they expect — correct for preventing double-starts, and
    /// fatal here. If the app believes it is `.playing` while the engine is not
    /// actually running, `resume()` sees the wrong state and returns, `start()` sees
    /// the wrong state and returns, and the press does nothing at all. No sound, no
    /// error, no line in the log.
    ///
    /// And an engine stopped underneath a transport that still says `.playing` is not
    /// hypothetical: it is what `recoverIfStopped` exists to repair, arriving through
    /// a notification that a CarPlay connect is entirely capable of not delivering —
    /// the app is suspended in a pocket while the car brings up its session.
    ///
    /// So play is asked what the *engine* is doing, not only what we think we
    /// remember, and repairs the disagreement rather than declining to act on it. A
    /// transport button whose press is a no-op should be impossible by construction.
    func play(from source: String) {
        FlightRecorder.shared.note(
            "\(source) — transport \(transport), engine \(audio.isRunning ? "running" : "stopped")")
        switch transport {
        case .idle:
            start()
        case .paused:
            resume()
        case .playing:
            // We think we are playing and a button that means "start playing" was
            // pressed, so whatever the listener is hearing is not what we believe.
            // Trust the graph, not the flag.
            if !audio.isRunning {
                FlightRecorder.shared.note("play pressed while nominally playing — repairing")
                recoverIfStopped()
                fade(to: 1, over: Self.fadeIn)
                updateNowPlaying()
            }
        }
    }

    /// "I heard it just now."
    ///
    /// Writes the last five minutes out to the flight log, backwards from this
    /// moment. Deliberately does nothing else — no sound, no change to Flow, no state
    /// — so that pressing it can never itself be mistaken for the fault, and so it is
    /// safe to press whenever there is any doubt. A false mark costs six hundred lines
    /// in a log file; a fault that goes unmarked costs another walk.
    func markHeard() {
        marksThisSession += 1
        FlightRecorder.shared.note(
            "▼ HEARD IT — mark #\(marksThisSession), last 5 min follow (oldest first)")
        for row in markBuffer.dump() { FlightRecorder.shared.note(row) }
        FlightRecorder.shared.note("▲ end of mark #\(marksThisSession)")
        touched()
    }

    // MARK: - Rating

    /// The thumbs, from wherever they were pressed — the screen, the lock screen,
    /// or a car.
    ///
    /// Counts as a touch, so rating what you are listening to also keeps the field
    /// awake. That is not a nicety: the idle fade is two and a half minutes, and
    /// pressing a button to say you like something and watching the screen dim
    /// immediately afterwards reads as the app disagreeing.
    ///
    /// `from` is for the flight recorder, and it is the only way to tell afterwards
    /// whether a remote control that appeared to do nothing was a command that never
    /// arrived or a vote that landed and was simply inaudible. Every press of every
    /// thumb, everywhere, goes through here — so the log either has the line or the
    /// button is not reaching us.
    func rate(_ vote: Taste.Vote, from source: String = "screen") {
        let verdict = model.flow.rate(vote)
        FlightRecorder.shared.note(
            "rate \(vote.rawValue) — \(source)\(verdict == .corrected ? " (corrected)" : "")")

        // The backstop that closes the correction window in wall-clock time.
        //
        // `FlowDirector` expires a held vote on its own clock, which is the right
        // clock for the offline harness and for a session that is playing — but it
        // stops when Flow does, and a vote cast against the tail of a stopped drone
        // is one `rate` has always accepted. Without this, that vote would be held
        // for ever and never written down. Slightly past the window so the clock
        // path wins whenever there is one.
        voteWindowTimer?.invalidate()
        voteWindowTimer = Timer.scheduledTimer(withTimeInterval: FlowDirector.correctionWindow + 0.2,
                                               repeats: false) { _ in
            Task { @MainActor in self.model.flow.commitVote() }
        }
        touched()
    }

    private var voteWindowTimer: Timer?

    /// Fill a feedback control in, then clear it.
    ///
    /// `MPFeedbackCommand.isActive` is the only acknowledgement the lock screen and
    /// the car will draw for us, and it latches — see `configureRemoteCommands`. Four
    /// seconds is a glance: long enough to catch on a screen that is already lit,
    /// short enough that nobody comes back to a star still lit from a previous drone.
    ///
    /// One timer for both thumbs, because pressing the other one immediately should
    /// move the acknowledgement rather than leave two lit at once, and because the
    /// second press of the *same* thumb should restart the four seconds rather than
    /// inherit the remains of the first.
    private func acknowledge(_ command: MPFeedbackCommand) {
        feedbackFlashTimer?.invalidate()
        for other in [MPRemoteCommandCenter.shared().likeCommand,
                      MPRemoteCommandCenter.shared().dislikeCommand] where other !== command {
            other.isActive = false
        }
        command.isActive = true
        feedbackFlashTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            Task { @MainActor in command.isActive = false }
        }
    }

    /// Start Flow having set a voicing first.
    ///
    /// Order matters: applying the voicing *before* Flow starts means Flow adopts
    /// it as the starting point and drifts from there, rather than gliding away
    /// from whatever was already sounding. One tap, one complete action — which is
    /// what a control at a steering wheel has to be.
    func startWith(_ voicing: ThrumModel.Voicing) {
        // And the key before the voicing, for the same reason one step further
        // back: chosen first it is simply the key this session is in, chosen after
        // the stack is already gated on it would be a pitch glide over the swell.
        if !running { model.flow.chooseFreshKey() }
        model.apply(voicing)
        if !running { start() } else { updateNowPlaying() }
    }

    // MARK: - Idle policy

    func touched() {
        lastTouch = Date()
        if idle {
            idle = false
            withAnimation(.easeOut(duration: 0.8)) { dim = 1 }
        }
    }

    private func startIdleWatch() {
        idleTimer?.invalidate()
        // Once every fifteen seconds is plenty to notice a two-and-a-half minute
        // timeout, and a timer this lazy is itself close to free.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    private func checkIdle() {
        guard running, !idle else { return }
        if Date().timeIntervalSince(lastTouch) > Self.idleAfter {
            idle = true
            withAnimation(.easeInOut(duration: 6)) { dim = 0.22 }
        }
    }

    // MARK: - Session plumbing

    /// The iOS equivalents of the Mac app's configuration-change watchdog.
    ///
    /// Same failure it was written for — something takes the output away and the
    /// engine does not come back on its own — arriving through different
    /// notifications. Interruptions are the new one: a phone call stops the
    /// engine outright and only tells you afterwards.
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
                switch type {
                case .began:
                    // Siri reading a message, a phone call, a timer. iOS has already
                    // taken the session away; what matters is that *we* know it, so
                    // the engine and Flow's clock stop together and the drone comes
                    // back where it left off rather than where it would have drifted
                    // to. Leaving this empty — as it was — meant the graph was still
                    // nominally running through the interruption, so the guard in
                    // `resumeAfterInterruption` saw `audio.isRunning == true` and
                    // declined to restart anything. The drone never came back.
                    FlightRecorder.shared.note("INTERRUPTION began")
                    if self.transport == .playing {
                        self.resumeWhenInterruptionEnds = true
                        self.pause()
                    }
                case .ended:
                    // `.shouldResume` is advisory and is frequently absent — for a
                    // notification read aloud it often simply isn't set. Honouring it
                    // strictly is right for a music player, where the listener may
                    // well have moved on, and wrong for a drone that was deliberately
                    // left running in a room. What decides it here is our own record
                    // of whether the interruption is what stopped us: a pause the
                    // listener asked for is never undone by Siri finishing a sentence.
                    FlightRecorder.shared.note("INTERRUPTION ended — resuming: \(self.resumeWhenInterruptionEnds)")
                    if self.resumeWhenInterruptionEnds {
                        self.resumeWhenInterruptionEnds = false
                        self.resume()
                    }
                default:
                    break
                }
            }
        })

        observers.append(centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverIfStopped() }
        })

        // The user can change this mid-walk from Control Centre, and if it is what
        // causes the dropouts then the moment it is toggled is the most informative
        // line the log will ever contain.
        observers.append(centre.addObserver(
            forName: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                FlightRecorder.shared.note(
                    "SYSTEM SPATIALIZATION now \(self.systemSpatialization ? "ON" : "off")")
                self.refreshSpatialConflict()
            }
        })

        observers.append(centre.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            // AudioRoute is watching this too and will publish the new route;
            // this is here for the engine, which iOS may have stopped underneath us.
            MainActor.assumeIsolated { self?.recoverIfStopped() }
        })
    }

    /// For the failures that are *not* interruptions: a route change or a media
    /// services reset can stop the engine underneath us with no notification that
    /// says so. If we believe we are playing and the graph is not, restart it.
    private func recoverIfStopped() {
        guard transport == .playing, !audio.isRunning else { return }
        // The engine stopped without telling us — a media-services reset, or a route
        // change iOS handled by tearing the graph down. Audible as a gap, and the
        // log is the only way to know afterwards that this is what it was.
        FlightRecorder.shared.note("ENGINE STOPPED underneath us — restarting")
        try? AVAudioSession.sharedInstance().setActive(true)
        try? audio.start()
    }

    /// Lock screen, Control Centre, **CarPlay** and an AirPods stem squeeze.
    ///
    /// For something meant to be left running with the screen off, this is not a
    /// nicety — without it the only way to stop the drone is to find the app.
    ///
    /// This is also the entirety of Thrum's CarPlay support, and deliberately so.
    /// An audio app that sets a `.playback` session and populates
    /// `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` appears on the car's Now
    /// Playing screen with working transport, artwork and metadata, with no
    /// entitlement and no CarPlay-specific code. A *CarPlay app* — an icon on the
    /// car's home screen — needs `com.apple.developer.carplay-audio`, which Apple
    /// grants by review, and even then CarPlay renders only its own templates: no
    /// custom drawing, so the Metal field could never appear there. The template
    /// would be the same shape as every other player's, which is a lot of process
    /// for a screen this app has no content to fill.
    private func configureRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()
        // Play resumes where it was paused; it only starts a fresh journey if there
        // isn't one yet. Pause holds. Neither of them lets go of the drone — the
        // earlier version wired pause straight to `stop()`, which faded every voice
        // and ended the session, so pressing play afterwards began a whole new one
        // in a different key. On a lock screen those two buttons have to mean what
        // they mean everywhere else.
        // Every one of these records that it arrived, for the same reason `rate` does:
        // the difference between a command that never reached the app and one that
        // landed and did nothing is invisible from the driver's seat, and it is the
        // first thing worth knowing about "the play button did nothing". These were
        // the only controls in the app with no line in the log.
        centre.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.play(from: "remote ▶") }
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated {
                FlightRecorder.shared.note("remote ⏸ — transport \(self.transport)")
                self.pause()
            }
            return .success
        }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.toggle(from: "remote ⏯") }
            return .success
        }

        // The thumbs, away from the app's own screen.
        //
        // **What iOS actually draws for these is not a thumb.** `MPFeedbackCommand`
        // is the only rating API Now Playing has, and the system renders `like` as a
        // ★ — while `dislike` gets no slot on the iOS lock screen at all. So this
        // buys exactly one control there, and it is a star meaning "more like this".
        // The car is the better citizen: `CPNowPlayingTemplate` takes the two real
        // thumb glyphs, which is where `iOS/CarPlay.swift` puts them.
        //
        // Getting two labelled thumbs onto the lock screen itself needs a Live
        // Activity with interactive App Intent buttons — a widget extension, a new
        // target and a new signing surface. Worth doing for an app that spends its
        // life behind a locked screen, but it is a separate piece of work and this
        // is what the transport API can honestly give.
        //
        // `isActive` is what fills the star in, and it is a *latch* — set it and the
        // control stays filled until something clears it. Latched is right for "I
        // have liked this song" and wrong here: there is no song, only a drone that
        // has already drifted on, and a star still filled twenty minutes later would
        // be making a claim about music that stopped playing long ago.
        //
        // But leaving it permanently false, as this did, means the one control the
        // lock screen gives us never acknowledges a press at all — and the toast that
        // `rate` shows lives in the app's own window, which is precisely the thing the
        // listener is not looking at. A press into silence reads as a broken button.
        //
        // So: fill it, then clear it. Long enough to be seen on a glance at a locked
        // screen, short enough that it is plainly a receipt for what was just pressed
        // rather than a standing state.
        centre.likeCommand.isEnabled = true
        centre.likeCommand.localizedTitle = "More like this"
        centre.likeCommand.localizedShortTitle = "More"
        centre.likeCommand.isActive = false
        centre.likeCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated {
                self.rate(.up, from: "lock ★")
                self.acknowledge(centre.likeCommand)
            }
            return .success
        }

        // Enabled for CarPlay's sake even though the phone's lock screen will not
        // draw it. Costs nothing, and the car is where it appears.
        centre.dislikeCommand.isEnabled = true
        centre.dislikeCommand.localizedTitle = "Less like this"
        centre.dislikeCommand.localizedShortTitle = "Less"
        centre.dislikeCommand.isActive = false
        centre.dislikeCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated {
                self.rate(.down, from: "lock 👎")
                self.acknowledge(centre.dislikeCommand)
            }
            return .success
        }

        // **⏭ is the other thumb**, since the lock screen will not give us one.
        //
        // A repurposed transport button is normally a bad idea, but the usual
        // objection does not survive contact with this app: there is no next track
        // in a continuous drone, so ⏭ has no honest meaning to displace. What it
        // *does* mean to a listener — "I have had enough of this one, move along" —
        // is precisely what a thumbs-down says, and it is what `rate(.down)` does.
        //
        // An earlier version of this comment argued the opposite, that ⏭ was wrong
        // because cycling a timbre from a steering wheel would click. That objection
        // was about a *raw* cycle. `rate(.down)` doesn't do one: it goes through
        // `FlowDirector.moveOn`, which changes a single quality on that quality's
        // own ramp — the spectrum crossfade, the glide — exactly as the scheduled
        // version does. Nothing reached from here can arrive any more abruptly than
        // Flow's own gestures.
        //
        // What is lost is discoverability, and there is no fixing it from here:
        // `localizedTitle` lives on `MPFeedbackCommand`, not on `MPRemoteCommand`, so
        // a transport button cannot be relabelled at all. It draws as ⏭ and reads as
        // "Next Track" to VoiceOver. That is the price of the mapping, and the reason
        // the car keeps its own labelled 👎 alongside it rather than relying on this.
        centre.nextTrackCommand.isEnabled = true
        centre.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.rate(.down, from: "⏭") }
            return .success
        }

        // Everything else off, so nothing draws a control that does nothing.
        //
        // Skip forward/back matters more than it looks: it is what iOS falls back to
        // for a live stream with no next track, it defaults to *enabled*, and leaving
        // it out of this list put two dead ⏪ ⏩ on the lock screen — a drone has
        // nowhere to seek to. Disabling next/previous is not sufficient on its own.
        // ⏮ stays off deliberately: there is no "previous" quality to go back to,
        // and a thumbs-down that could be undone would need to un-spread a vote
        // across thirty traits.
        for command in [centre.previousTrackCommand,
                        centre.seekForwardCommand, centre.seekBackwardCommand,
                        centre.skipForwardCommand, centre.skipBackwardCommand,
                        centre.changePlaybackPositionCommand,
                        centre.changeRepeatModeCommand, centre.changeShuffleModeCommand,
                        centre.ratingCommand, centre.bookmarkCommand] {
            command.isEnabled = false
        }
    }

    /// Keep the car and lock screen showing what Flow is currently playing.
    ///
    /// Subscribed to `harmony` rather than polled, and that distinction is the
    /// whole reason this is safe to do: Flow moves the mode every few minutes, so
    /// this fires a handful of times an hour. The earlier version deliberately
    /// showed a static title because a lock screen that rewrites itself
    /// constantly wakes the compositor — a subscription costs nothing between
    /// changes and gets the useful behaviour anyway.
    private func watchHarmony() {
        harmonyWatch = model.$harmony
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateNowPlaying() }
            }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            // What Flow is actually playing, which in a car is the only thing
            // worth reading and is genuinely useful — "DmMaj7 / D Melodic Minor"
            // tells you where the drone has drifted to without looking at a phone.
            MPMediaItemPropertyTitle: model.harmony.title,
            MPMediaItemPropertyArtist: "Thrum · \(model.harmony.subtitle)",
            MPMediaItemPropertyAlbumTitle: transportName,
            // Endless by design, so no scrubber and no duration — without this the
            // car draws a progress bar that can never move.
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: running ? 1.0 : 0.0,
        ]
        if let art = artwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // The playback *state* is separate from the info dictionary, and setting
        // only the dictionary is what leaves a lock screen showing a play triangle
        // over audible sound (or a pause bar over silence). iOS decides which glyph
        // to draw from this.
        // `.paused` rather than `.stopped` for a session that has not begun, and this
        // is a CarPlay fix rather than a cosmetic one. `.stopped` is the state that
        // says "this app is finished playing"; a car that reconnects to a launched-but-
        // idle Thrum reads it as nothing to control, and its transport buttons have
        // nowhere to go. Since `nowPlayingInfo` is published from `init` regardless —
        // the app is claiming the slot either way — `.paused` is both the more honest
        // description of a drone waiting to be started and the state in which a play
        // button is live.
        MPNowPlayingInfoCenter.default().playbackState =
            transport == .playing ? .playing : .paused
    }

    private var transportName: String {
        switch transport {
        case .idle:    return "Stopped"
        case .playing: return "Flow"
        case .paused:  return "Paused"
        }
    }

    /// The field, as it is right now — not the app icon.
    ///
    /// CarPlay will not let us draw, but it will show an image, so this is the
    /// only route the visualizer has onto a dashboard. Rendered from the same
    /// voice data and the same ring geometry the shader uses, so the car and the
    /// phone show the same picture of the same chord.
    ///
    /// Falls back to the static icon before anything is sounding, since a black
    /// square looks like a failure to load.
    private var artwork: MPMediaItemArtwork? {
        // A paused drone still has voices held at their levels, so the field is
        // still the honest picture of it — only a session that has never begun
        // falls back to the icon.
        guard hasStarted else { return Self.staticArtwork }
        var scratch = artScratch
        let filled = fillField(&scratch)
        guard filled.count > 0 else { return Self.staticArtwork }
        let image = FieldArtwork.render(voices: scratch, count: Int(filled.count), master: filled.master)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private static let staticArtwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "NowPlayingArt") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    /// Refresh the artwork while Flow runs, so the picture in the car follows the
    /// music instead of freezing on whatever was sounding when it started.
    ///
    /// Thirty seconds, and the interval is a real trade rather than a guess: each
    /// refresh is one small Core Graphics pass plus a Now Playing write, and a
    /// Now Playing write wakes whatever is displaying it. Every few seconds would
    /// animate nicely and undo the battery work; on mode change alone would sit
    /// unchanged for minutes at a time. Thirty seconds visibly moves without being
    /// something you watch.
    private func startArtworkRefresh() {
        artworkTimer?.invalidate()
        artworkTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.updateNowPlaying()
            }
        }
    }

    // MARK: - Scene

    func sceneBecameActive() {
        FlightRecorder.shared.note("foreground")
        visualizerRunning = true
        touched()
    }

    /// Backgrounded: stop drawing entirely. The drone keeps playing.
    func sceneWentBackground() {
        // The moment the interesting failures start. CoreMotion may or may not keep
        // feeding head orientation from here; the heartbeat's `motion` count is what
        // settles it, and it is why the heartbeat is not gated on the screen.
        FlightRecorder.shared.note("background")
        visualizerRunning = false
        // Deliberately *not* committing a held vote here. Backgrounding looks like
        // the end of the moment, but the lock screen and CarPlay can both still
        // cast one — so the second thumb of a correction very often arrives after
        // this, from a screen that is not this one.
    }

    // MARK: - Visualizer feed

    /// Copy the sounding voices into the shader's uniform block.
    ///
    /// Reads `engine.meters`, which the render thread writes and the Mac app's
    /// on-screen meters already read the same way — a benign race on `Float`s.
    /// A torn read costs one frame of slightly wrong brightness.
    ///
    /// Placement reuses `SpatialField`'s geometry so the picture and the HRTF
    /// image agree: angle is scale degree with the tonic straight up, radius is
    /// octave. Only sounding voices are written, and `count` bounds the shader's
    /// loop, so silence is nearly free to draw.
    /// Returns the header values rather than taking them `inout`, so the caller
    /// never has to hand over two overlapping projections of one struct — which
    /// is exactly what tripped Swift's exclusivity checker on the first run.
    func fillField(_ voices: inout [ShaderVoice]) -> (count: Int32, master: Float) {
        let hue = Float(model.harmony.mode.hue)
        var written = 0
        for v in 0..<DroneEngine.voiceCount {
            let level = engine.meters[v]
            if level <= 0.0009 { continue }
            let tier = v / SpatialField.azimuths          // 0 = low octaves, 1 = high
            let col = v % SpatialField.azimuths
            let angle = Double(col) / Double(SpatialField.azimuths) * 2 * Double.pi
            let radius = tier == 0 ? 0.30 : 0.60
            voices[written].position = simd_float2(Float(sin(angle) * radius),
                                                  Float(cos(angle) * radius))
            // Perceptual-ish curve: meters are linear amplitude and a linear map
            // makes quiet voices vanish long before they are inaudible.
            voices[written].level = min(1, powf(level, 0.55) * 1.35)
            voices[written].hue = hue
            written += 1
            if written == 32 { break }
        }
        return (Int32(written), min(1, engine.meters[DroneEngine.voiceCount]))
    }

    func shutdown() {
        // A vote still inside its window is a real opinion that has simply not been
        // written down yet. Losing it because the app was closed five seconds after
        // the press would be a rating button that silently drops presses.
        model.flow.commitVote()
        voteWindowTimer?.invalidate()
        idleTimer?.invalidate()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        model.route.shutdown()
        model.pulse.stop()
        audio.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// What the session actually gave us, for the diagnostics readout — a
    /// requested buffer duration is a hint, not a promise.
    var bufferReport: String {
        let session = AVAudioSession.sharedInstance()
        let frames = Int((session.ioBufferDuration * session.sampleRate).rounded())
        return String(format: "%.0f kHz · %d frames · %.0f ms",
                      session.sampleRate / 1000, frames, session.ioBufferDuration * 1000)
    }
}

/// Drives one engine render per audio cycle from seventeen render callbacks.
///
/// Lifted wholesale from the Mac app, including the reason it is shaped this way:
/// key on the timestamp rather than nominating a leader node, because callback
/// order between a mixer's inputs is not guaranteed. Holds no Swift collections
/// and is not `@MainActor` — the render thread touches it.
private final class SpatialPump {
    let engine: DroneEngine
    private var lastSampleTime: Double = -1

    init(engine: DroneEngine) { self.engine = engine }

    /// Where the output clock should be next cycle, and what happened when it wasn't.
    ///
    /// This is the one thing the flight recorder could not see, and it is on the only
    /// side of the graph where the reported symptom lives.
    ///
    /// `DroneEngine.renderLoad` and `renderOverruns` bracket `renderSpatial` with
    /// `mach_absolute_time` — so they measure *our* DSP and nothing else. Downstream
    /// of that sit sixteen `AVAudioEnvironmentNode` HRTF instances, AVAudioEngine's
    /// own graph lock (which the main thread takes every time `placeListener` writes a
    /// new orientation, sixteen times a second), and the Bluetooth link. A stall in
    /// any of those is a hole in the audio and leaves `overruns 0` in the log, which
    /// is exactly what the 08-11 session shows: load 0.09–0.32, overruns 0, clamped 0,
    /// and a listener hearing notes drop out.
    ///
    /// `mSampleTime` closes that gap. CoreAudio advances it by `frames` every cycle
    /// whether or not we delivered anything, so a jump larger than `frames` is a cycle
    /// that went out without us — a measured gap, whatever its cause. It cannot say
    /// *which* stage stalled, but it settles the question that matters first: whether
    /// the audio left this app intact.
    ///
    /// Legitimately discontinuous at start, resume and route change, so `resync()` is
    /// called at each; a count sitting next to a `RESUME` line in the log is that and
    /// not a fault. Written on the render thread and read from the heartbeat — the same
    /// benign race as `meters` and `renderLoad`, and a lost count is cheaper than a
    /// lock on this thread.
    private var expectedNext: Double = -1
    private var gaps = 0
    private var gapFrames = 0
    private var largestGap = 0

    /// Forget where the clock was, without counting it as a fault.
    func resync() { expectedNext = -1 }

    func drainGaps() -> (count: Int, frames: Int, largest: Int) {
        defer { gaps = 0; gapFrames = 0; largestGap = 0 }
        return (gaps, gapFrames, largestGap)
    }

    @inline(__always)
    func renderIfNeeded(_ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: Int) {
        let t = timestamp.pointee.mSampleTime
        if t != lastSampleTime {
            lastSampleTime = t
            if expectedNext >= 0, t > expectedNext {
                gaps += 1
                let missing = Int(t - expectedNext)
                gapFrames += missing
                if missing > largestGap { largestGap = missing }
            }
            expectedNext = t + Double(frames)
            engine.renderSpatial(frameCount: frames)
        }
    }
}
