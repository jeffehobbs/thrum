import AudioToolbox
import Foundation

/// Thrum played from a keyboard instead of a grid.
///
/// The engine is the app's, untouched: thirty-two voices that swell in and
/// hold. What the audio unit adds is the part the grid used to do — deciding
/// which voice a note gets and what pitch that is — and it does it on the
/// render thread, from the MIDI the host hands over in the render call. Nothing
/// here allocates, locks against the UI, or touches a Swift collection once
/// `init` has returned.
///
/// Tuning works as it does in the app: the key's pitch class sits at concert
/// pitch, and every other note is placed by the temperament's own interval
/// above it. So in D just intonation, F♯ is a pure 5:4 over D and A a 3:2 —
/// play the keyboard in D and the drone locks. Play it in E♭ and it doesn't,
/// which is what just intonation is.
///
/// With Flow on, a second player shares the voices: `FlowCore` holds pads on
/// the app's grid, and each one it sounds takes a voice exactly as a held note
/// does. The two never take each other's voices, so you can play over Flow.
final class ThrumKernel {
    let engine = DroneEngine()
    private static let voices = DroneEngine.voiceCount
    private static let maxSlice = 4096
    /// Pitch-glide time while Flow is driving, as in the app: a fifth arriving
    /// over seven and a half seconds is a modulation, in half a second a lurch.
    private static let flowGlide = 7.5

    // MARK: Control values (UI or host writes, render reads; benign races on scalars)

    /// Every parameter's current value, by address — the tree's backing store.
    private let values: UnsafeMutablePointer<Double>
    private let paramCount = ThrumParam.allCases.count

    // MARK: Render-thread state

    /// Cents above the tonal center, `tuning * 12 + pitchClass`. Read from
    /// `TuningSystem` once at init: its tables are Swift arrays, and some of
    /// them are computed on every access.
    private let cents: UnsafeMutablePointer<Double>
    private let tuningCount = TuningSystem.allCases.count

    /// The MIDI note each voice was last given, or −1. A voice keeps its note
    /// through its release, so a note struck again while it fades swells back
    /// up out of its own tail rather than starting a second copy of itself.
    private let voiceNote: UnsafeMutablePointer<Int16>
    private let voiceDown: UnsafeMutablePointer<Bool>
    private let voiceSustained: UnsafeMutablePointer<Bool>
    private let voiceStamp: UnsafeMutablePointer<UInt64>
    /// The grid pad a voice is holding for Flow, or −1 for a played note.
    private let voiceFlowPad: UnsafeMutablePointer<Int8>
    /// The other direction: which voice each of Flow's pads is sounding on.
    private let padVoice: UnsafeMutablePointer<Int8>
    private var clock: UInt64 = 0

    private var sustainPedal = false
    private var modWheel = 0.0
    private var bendSemitones = 0.0
    private var bendDirty = false

    /// What the voices were last tuned for, so a change from either side can be
    /// noticed at the top of a block and glided into.
    private var appliedKey = -1
    private var appliedTuning = -1
    private var appliedA4 = 0.0
    private var appliedMode = -1
    private var appliedSitar = -1.0
    private var flowRunning = false

    private(set) var sampleRate = 48_000.0
    private(set) lazy var flow = FlowCore(kernel: self)

    private let slice: UnsafeMutableAudioBufferListPointer
    private var ownL: UnsafeMutablePointer<Float>?
    private var ownR: UnsafeMutablePointer<Float>?
    private var ownFrames = 0

    init() {
        values = .allocate(capacity: ThrumParam.allCases.count)
        values.initialize(repeating: 0, count: ThrumParam.allCases.count)

        cents = .allocate(capacity: TuningSystem.allCases.count * 12)
        for (t, system) in TuningSystem.allCases.enumerated() {
            for pc in 0..<12 { cents[t * 12 + pc] = system.cents(semitone: pc) }
        }

        let n = Self.voices
        voiceNote = .allocate(capacity: n); voiceNote.initialize(repeating: -1, count: n)
        voiceDown = .allocate(capacity: n); voiceDown.initialize(repeating: false, count: n)
        voiceSustained = .allocate(capacity: n); voiceSustained.initialize(repeating: false, count: n)
        voiceStamp = .allocate(capacity: n); voiceStamp.initialize(repeating: 0, count: n)
        voiceFlowPad = .allocate(capacity: n); voiceFlowPad.initialize(repeating: -1, count: n)
        padVoice = .allocate(capacity: Harmony.padCount)
        padVoice.initialize(repeating: -1, count: Harmony.padCount)

        slice = AudioBufferList.allocate(maximumBuffers: 2)

        for s in ThrumParamSpec.all { set(s.param.rawValue, s.defaultValue) }
        // Built now rather than on first use, which would be on the render thread.
        _ = flow
    }

    deinit {
        values.deallocate()
        cents.deallocate()
        voiceNote.deallocate(); voiceDown.deallocate()
        voiceSustained.deallocate(); voiceStamp.deallocate()
        voiceFlowPad.deallocate(); padVoice.deallocate()
        free(slice.unsafeMutablePointer)
        ownL?.deallocate(); ownR?.deallocate()
    }

    // MARK: - Lifecycle (not the render thread)

    func prepare(sampleRate: Double, maxFrames: Int) {
        self.sampleRate = sampleRate
        engine.setSampleRate(sampleRate)
        if maxFrames > ownFrames {
            ownL?.deallocate(); ownR?.deallocate()
            ownL = .allocate(capacity: maxFrames)
            ownR = .allocate(capacity: maxFrames)
            ownFrames = maxFrames
        }
    }

    /// The host's reset. It can arrive on any thread and the voice table belongs
    /// to the render thread, so this only asks; the next render does it.
    func requestReset() { resetRequested = true }
    private var resetRequested = false

    /// Hard stop: silence now, tails cleared, every note forgotten. Flow, if it
    /// is on, stays on and finds a fresh voicing to swell back in with.
    private func reset() {
        engine.panic()
        for v in 0..<Self.voices {
            voiceNote[v] = -1; voiceDown[v] = false; voiceSustained[v] = false
            voiceFlowPad[v] = -1
        }
        for p in 0..<Harmony.padCount { padVoice[p] = -1 }
        sustainPedal = false
        bendSemitones = 0
        flow.voicesLost()
    }

    // MARK: - Parameters

    func get(_ address: AUParameterAddress) -> Double {
        Int(address) < paramCount ? values[Int(address)] : 0
    }

    /// A value from outside — the window, the host's own controls, automation,
    /// a preset. Callable from any thread. Whoever set it now owns it, so Flow
    /// lets go of any slide it had open on the same control.
    func set(_ address: AUParameterAddress, _ raw: Double) {
        flow.cancelRamp(address)
        store(address, raw)
    }

    /// Each engine control is a scalar the engine reads once a block, as in the
    /// app; the harmony controls are only stored here and picked up by the
    /// render thread, which owns the voices. Flow writes through here directly.
    func store(_ address: AUParameterAddress, _ raw: Double) {
        guard let p = ThrumParam(rawValue: address) else { return }
        let s = ThrumParamSpec.spec(p)
        let v = min(max(raw, s.range.lowerBound), s.range.upperBound)
        values[Int(address)] = v
        let f = Float(v / 100)
        switch p {
        case .timbre:       engine.timbreIndex = Int32(v.rounded())
        case .tuning, .key, .a4, .articulation, .velocity, .sitar, .glide, .flow, .mode: break
        case .swell:        engine.swellSeconds = v
        case .fade:         engine.fadeSeconds = v
        case .beating:      engine.beating = f
        case .drift:        engine.drift = f
        case .motion:       engine.motion = f
        case .brightness:   engine.brightness = f
        case .warmth:       engine.warmth = f
        case .presence:     engine.presenceCut = f
        case .air:          engine.air = f
        case .drive:        engine.drive = f
        case .decay:        engine.reverbDecay = v
        case .wet:          engine.reverbMix = f
        case .damping:      engine.reverbDamp = f
        case .size:         engine.reverbSize = Float(v)
        case .width:        engine.width = Float(v)
        case .fieldDrift:   engine.spatialDrift = f
        case .accentAttack: engine.pluckAttack = v
        case .accentDecay:  engine.pluckDecay = v
        case .morph:        engine.timbreSeconds = v
        case .output:       engine.masterVolume = f
        }
    }

    func value(_ p: ThrumParam) -> Double { values[Int(p.rawValue)] }

    private var key: Int { Int(value(.key).rounded()) }
    private var tuning: Int { min(max(Int(value(.tuning).rounded()), 0), tuningCount - 1) }
    private var a4: Double { value(.a4) }
    var mode: Int { min(max(Int(value(.mode).rounded()), 0), ModeCatalog.all.count - 1) }
    private var accented: Bool { value(.articulation) > 0.5 }
    private var sitar: Double { max(value(.sitar) / 100, modWheel) }

    // MARK: - Pitch

    private func frequency(note: Int) -> Double {
        let s = note - key
        let oct = s >= 0 ? s / 12 : -((11 - s) / 12)
        let pc = s - oct * 12
        let center = a4 * pow(2.0, Double(key - 69) / 12.0)
        let c = Double(oct) * 1200 + cents[tuning * 12 + pc] + bendSemitones * 100
        return center * pow(2.0, c / 1200)
    }

    /// The MIDI note a grid pad stands for, in the current key and mode. The
    /// grid sits where the app's does by default: its bottom row an octave
    /// under the nominal root, in octave 2.
    private func note(pad: Int) -> Int {
        36 + key + flow.semitone(mode: mode, pad: pad)
    }

    // MARK: - Voices

    private func sounding(_ v: Int) -> Bool { engine.meters[v] > 0 }

    private func sitar(for v: Int) -> Double {
        let pad = Int(voiceFlowPad[v])
        return pad >= 0 ? max(sitar, flow.padSitar(pad)) : sitar
    }

    /// The voice a new note should take. A voice already holding this note for
    /// the same player first; then whichever silent voice has been silent
    /// longest; then the quietest one on its way out; and only with all
    /// thirty-two held, the oldest held note.
    private func voice(for note: Int, flow: Bool) -> Int {
        for v in 0..<Self.voices where Int(voiceNote[v]) == note {
            // A played note may strike its own voice again even while held; Flow
            // only reuses a voice of that pitch nobody is holding any more.
            if flow ? (!voiceDown[v] && !voiceSustained[v]) : voiceFlowPad[v] < 0 { return v }
        }
        var best = -1
        var bestLevel = Float.greatestFiniteMagnitude
        var bestStamp = UInt64.max
        for v in 0..<Self.voices where !voiceDown[v] && !voiceSustained[v] {
            let level = engine.meters[v]
            if level < bestLevel || (level == bestLevel && voiceStamp[v] < bestStamp) {
                best = v; bestLevel = level; bestStamp = voiceStamp[v]
            }
        }
        if best >= 0 { return best }
        for v in 0..<Self.voices where voiceStamp[v] < bestStamp {
            best = v; bestStamp = voiceStamp[v]
        }
        return best
    }

    /// Point voice `v` at `note`, at once if it was holding something else.
    private func take(_ v: Int, note: Int) {
        // Whoever had it before loses it — a stolen voice can't stay on Flow's books.
        let oldPad = Int(voiceFlowPad[v])
        if oldPad >= 0 { padVoice[oldPad] = -1; voiceFlowPad[v] = -1; flow.padLost(oldPad) }
        if Int(voiceNote[v]) != note {
            // A voice is a pitch, not a note number: taking one over for a
            // different note puts it there at once rather than sliding.
            engine.place(pad: v, frequency: frequency(note: note))
            voiceNote[v] = Int16(note)
        }
        clock &+= 1
        voiceStamp[v] = clock
    }

    private func noteOn(_ note: Int, velocity: Int) {
        let v = voice(for: note, flow: false)
        guard v >= 0 else { return }
        let vel = Double(velocity) / 127
        let sens = value(.velocity) / 100
        let strength = (1 - sens) + sens * pow(vel, 1.3)

        take(v, note: note)
        engine.setSitar(pad: v, depth: sitar)

        if accented {
            // An accent rides on whatever the voice is already holding, exactly
            // as the app's arpeggiator does. Nothing to let go of afterwards.
            engine.pluck(pad: v, velocity: 0.9 * strength)
        } else {
            engine.setLevel(pad: v, level: 0.72 * strength)
            engine.gate(pad: v, on: true)
            voiceDown[v] = true
            voiceSustained[v] = false
        }
    }

    private func noteOff(_ note: Int) {
        for v in 0..<Self.voices where voiceDown[v] && voiceFlowPad[v] < 0 && Int(voiceNote[v]) == note {
            voiceDown[v] = false
            if sustainPedal {
                voiceSustained[v] = true
            } else {
                engine.gate(pad: v, on: false)
            }
        }
    }

    private func releaseSustained() {
        for v in 0..<Self.voices where voiceSustained[v] {
            voiceSustained[v] = false
            engine.gate(pad: v, on: false)
        }
    }

    /// Played notes only. Hosts send this on every stop, and Flow is a switch
    /// rather than a note — it carries on until it is turned off.
    private func allNotesOff() {
        for v in 0..<Self.voices where (voiceDown[v] || voiceSustained[v]) && voiceFlowPad[v] < 0 {
            voiceDown[v] = false
            voiceSustained[v] = false
            engine.gate(pad: v, on: false)
        }
    }

    // MARK: - Flow's hands

    func flowSound(pad: Int, level: Double) {
        guard pad >= 0, pad < Harmony.padCount else { return }
        var v = Int(padVoice[pad])
        if v < 0 {
            v = voice(for: note(pad: pad), flow: true)
            guard v >= 0 else { return }
            take(v, note: note(pad: pad))
            voiceFlowPad[v] = Int8(pad)
            padVoice[pad] = Int8(v)
        }
        voiceDown[v] = true
        voiceSustained[v] = false
        engine.setLevel(pad: v, level: level)
        engine.setSitar(pad: v, depth: sitar(for: v))
        engine.gate(pad: v, on: true)
    }

    func flowRelease(pad: Int) {
        guard pad >= 0, pad < Harmony.padCount else { return }
        let v = Int(padVoice[pad])
        guard v >= 0 else { return }
        padVoice[pad] = -1
        voiceFlowPad[v] = -1
        voiceDown[v] = false
        engine.gate(pad: v, on: false)
    }

    func flowSitarChanged(pad: Int) {
        let v = Int(padVoice[pad])
        if v >= 0 { engine.setSitar(pad: v, depth: sitar(for: v)) }
    }

    /// Top of every slice: if the key, temperament, mode, reference pitch or bend
    /// has moved since the voices were tuned, retune everything that has a note.
    /// Harmony changes glide, as they do in the app — changing one under a held
    /// chord is a modulation. Bend arrives at once.
    private func syncHarmony() {
        let k = key, t = tuning, a = a4, m = mode
        if k != appliedKey || t != appliedTuning || a != appliedA4 || m != appliedMode {
            let first = appliedKey < 0
            appliedKey = k; appliedTuning = t; appliedA4 = a; appliedMode = m
            for v in 0..<Self.voices where voiceNote[v] >= 0 {
                // A Flow pad is a grid position, not a pitch: a new mode or key
                // moves it to whatever that position now means.
                let pad = Int(voiceFlowPad[v])
                if pad >= 0 { voiceNote[v] = Int16(note(pad: pad)) }
                let f = frequency(note: Int(voiceNote[v]))
                if first { engine.place(pad: v, frequency: f) } else { engine.retune(pad: v, frequency: f) }
            }
            bendDirty = false
        }
        if bendDirty {
            bendDirty = false
            for v in 0..<Self.voices where voiceNote[v] >= 0 && (voiceDown[v] || voiceSustained[v] || sounding(v)) {
                engine.place(pad: v, frequency: frequency(note: Int(voiceNote[v])))
            }
        }
        let s = sitar
        if s != appliedSitar {
            appliedSitar = s
            for v in 0..<Self.voices where voiceNote[v] >= 0 { engine.setSitar(pad: v, depth: sitar(for: v)) }
        }
    }

    /// Flow on, Flow off, and Flow's clock. Ahead of `syncHarmony`, so a mode
    /// Flow picks this slice is glided into this slice.
    private func runFlow(frames n: Int) {
        let want = value(.flow) > 0.5
        if want != flowRunning {
            flowRunning = want
            if want { flow.start() } else { flow.stop() }
        }
        engine.glideSeconds = flowRunning ? Self.flowGlide : value(.glide)
        if flowRunning { flow.advance(by: Double(n) / sampleRate) }
    }

    // MARK: - MIDI

    func handleMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        switch status & 0xF0 {
        case 0x90:
            if d2 == 0 { noteOff(Int(d1)) } else { noteOn(Int(d1), velocity: Int(d2)) }
        case 0x80:
            noteOff(Int(d1))
        case 0xE0:
            let raw = Int(d1) | (Int(d2) << 7)
            bendSemitones = Double(raw - 8192) / 8192 * 2
            bendDirty = true
        case 0xB0:
            switch d1 {
            case 1:
                // The mod wheel opens the sitar — the jawari buzz and the
                // phaser — over whatever the Sitar control is set to.
                modWheel = Double(d2) / 127
            case 11:
                engine.globalSwell = Float(d2) / 127
            case 64:
                let down = d2 >= 64
                if sustainPedal && !down { releaseSustained() }
                sustainPedal = down
            case 120:
                reset()
            case 121:
                modWheel = 0; bendSemitones = 0; bendDirty = true
                engine.globalSwell = 1
            case 123:
                allNotesOff()
            default: break
            }
        default: break
        }
    }

    // MARK: - Render

    /// Renders one host buffer, split at each MIDI and parameter event so a note
    /// lands on its sample rather than at the top of the buffer — which matters
    /// for accents played from an arpeggiator, and not at all for a drone.
    func render(frameCount: Int,
                timestamp: UnsafePointer<AudioTimeStamp>,
                output: UnsafeMutablePointer<AudioBufferList>,
                events: UnsafePointer<AURenderEvent>?) -> AUAudioUnitStatus {
        let abl = UnsafeMutableAudioBufferListPointer(output)
        guard abl.count >= 1, abl.count <= 2 else { return kAudioUnitErr_FormatNotSupported }
        // A host may hand us buffers with no memory behind them and expect ours.
        for i in 0..<abl.count where abl[i].mData == nil {
            guard frameCount <= ownFrames, let own = i == 0 ? ownL : ownR else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
            abl[i].mData = UnsafeMutableRawPointer(own)
        }
        for i in 0..<abl.count { abl[i].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size) }

        if resetRequested { resetRequested = false; reset() }

        let start = Int64(timestamp.pointee.mSampleTime)
        var cursor = 0
        var event = events
        while cursor < frameCount || event != nil {
            // Everything due at or before the cursor happens now.
            var nextAt = frameCount
            while let e = event {
                let head = e.pointee.head
                let t = head.eventSampleTime
                let at = t == AUEventSampleTimeImmediate ? cursor
                    : min(max(Int(t - start), cursor), frameCount)
                if at > cursor { nextAt = at; break }
                apply(e)
                event = UnsafePointer(head.next)
            }
            if event == nil { nextAt = frameCount }
            if cursor >= frameCount { break }
            renderSpan(abl, from: cursor, to: nextAt)
            cursor = nextAt
        }
        return noErr
    }

    private func apply(_ e: UnsafePointer<AURenderEvent>) {
        switch e.pointee.head.eventType {
        case .MIDI:
            let m = e.pointee.MIDI
            if m.length > 0 { handleMIDI(m.data.0, m.length > 1 ? m.data.1 : 0, m.length > 2 ? m.data.2 : 0) }
        case .parameter, .parameterRamp:
            // A ramp jumps to its end value. Every continuous control is already
            // smoothed inside the engine over longer than any automation step.
            let p = e.pointee.parameter
            set(p.parameterAddress, Double(p.value))
        default:
            break
        }
    }

    private func renderSpan(_ abl: UnsafeMutableAudioBufferListPointer, from: Int, to: Int) {
        var at = from
        while at < to {
            let n = min(to - at, Self.maxSlice)
            runFlow(frames: n)
            syncHarmony()
            slice.count = abl.count
            for i in 0..<abl.count {
                let base = abl[i].mData!.assumingMemoryBound(to: Float.self)
                slice[i] = AudioBuffer(mNumberChannels: 1,
                                       mDataByteSize: UInt32(n * MemoryLayout<Float>.size),
                                       mData: UnsafeMutableRawPointer(base + at))
            }
            engine.render(frameCount: n, out: slice.unsafeMutablePointer)
            at += n
        }
    }
}
