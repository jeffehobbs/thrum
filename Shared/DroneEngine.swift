import Foundation
import AVFoundation

/// Thrum's sound.
///
/// Thirty-two independent drone voices, one per grid pad. A voice is not a
/// note — it has no decay and no note-off in the usual sense. It swells in over
/// seconds, holds forever, and can be ridden up and down while it holds.
///
/// Every voice is built from up to fourteen partials, and *every partial is two
/// oscillators* offset by a fraction of a hertz. The offsets are in Hz rather
/// than cents on purpose: a 0.3 Hz detune beats three times every ten seconds
/// whether it is on the fundamental or the eleventh harmonic, so the whole
/// spectrum breathes at the same slow rate instead of the top going ragged.
///
/// Nothing in here repeats. Each voice's drift, tremolo, filter and pan run off
/// LFOs whose periods are distinct primes in seconds — 11, 13, 17, 19, 23…
/// A voice with a 41-second drift and a 67-second filter sweep returns to the
/// same state every 2,747 seconds; two such voices, effectively never.
public final class DroneEngine {
    public static let voiceCount = Harmony.padCount   // 32
    private static let maxPartials = TimbreCatalog.maxPartials
    private static let maxFrames = 8192
    private static let controlChunk = 64
    private static let tableSize = 4096
    private static let tableMask = 4095
    private static let combSize = 8192
    private static let maxSampleRate = 192_000.0

    /// Distinct primes, in seconds. Indexed with mutually prime strides so no
    /// two voices ever share a modulation period.
    private static let primes: [Double] = [
        11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71,
        73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151,
    ]

    /// Per-partial beat offsets in Hz — irrational-ish so the partials never
    /// line up into a single audible pulse.
    private static let beatOffsets: [Double] = [
        0.104, 0.171, 0.233, 0.317, 0.139, 0.191, 0.281, 0.373,
        0.157, 0.211, 0.293, 0.347, 0.127, 0.401,
    ]

    // MARK: - Parameters (written from the UI thread, read per block)

    public var timbreIndex: Int32 = 0
    public var masterVolume: Float = 0.85
    /// Seconds for a tone to bloom to full. 0.5 … 40.
    public var swellSeconds: Double = 7
    /// Seconds for a tone to disappear. 0.5 … 60.
    public var fadeSeconds: Double = 11
    /// 0…1 → up to ~1.1 Hz of detune between each partial's oscillator pair.
    public var beating: Float = 0.5
    /// 0…1 → up to ±9 cents of slow independent pitch drift per voice.
    public var drift: Float = 0.45
    /// 0…1 → depth of the slow filter, tremolo and pan movement.
    public var motion: Float = 0.55
    /// 0…1 → voice lowpass from 320 Hz to 9 kHz.
    public var brightness: Float = 0.52
    /// 0…1 → low shelf at 160 Hz, up to +7 dB.
    public var warmth: Float = 0.55
    /// 0…1 → dip at 3.2 kHz, up to −7 dB. The anti-fatigue control.
    public var presenceCut: Float = 0.6
    /// 0…1 → high shelf at 9 kHz, −3…+5 dB.
    public var air: Float = 0.4
    /// 0…1 → gentle tanh saturation before the reverb.
    public var drive: Float = 0.28
    public var reverbDecay: Double = 14
    public var reverbMix: Float = 0.42
    public var reverbDamp: Float = 0.45
    public var reverbSize: Float = 1.15
    /// 0…2 mid/side width. 1 = untouched.
    public var width: Float = 1.25
    /// 0…1 depth of the 97-second rotation of the reverb field.
    public var spatialDrift: Float = 0.5
    /// 0…1 master swell, rides everything that is sounding at once.
    public var globalSwell: Float = 1.0
    /// Rise time of an arpeggiated accent, in seconds. Kept soft by default —
    /// this is still a drone, and a hard edge on a stack of pure partials
    /// clicks.
    public var pluckAttack: Double = 0.035
    /// Time for an accent to fall away to silence, in seconds. Long enough to
    /// overlap the next one is where it stops sounding like a sequencer.
    public var pluckDecay: Double = 1.4

    // MARK: - Metering (render thread writes, UI reads; benign race on Floats)

    public let meters: UnsafeMutablePointer<Float>   // voiceCount + 1 (master peak)

    /// Fraction of the render deadline the last blocks actually consumed, as a
    /// decaying peak. Above 1.0 means the callback ran longer than the audio it
    /// produced, which is a dropout. Worth watching: a Debug build sits near 0.5
    /// with six voices and above 2 with a full grid, and that is what crackle
    /// sounds like from the outside.
    public private(set) var renderLoad: Float = 0
    /// Blocks that missed the deadline since launch. Should stay at zero.
    public private(set) var renderOverruns: Int32 = 0
    /// Voices currently sounding, including ones still fading out.
    public private(set) var activeVoices: Int32 = 0

    private var loadPeak: Float = 0
    private let timebaseScale: Double   // mach ticks → nanoseconds

    public let events = EventQueue<DroneEvent>()

    // MARK: - Voice state

    private struct Voice {
        var active = false
        var gate = false
        var level: Float = 0        // where the player wants it
        var env: Float = 0          // where it actually is
        var freq = 0.0
        var targetFreq = 0.0
        var sitar: Float = 0
        var sitarSm: Float = 0
        /// The arpeggiator's accent envelope. Entirely separate from `env`:
        /// it is *added* to whatever the drone is already holding, so a
        /// plucked tone that is also being held swells out of the drone and
        /// falls back into it rather than replacing it.
        var pluck: Float = 0
        var pluckPeak: Float = 0
        var pluckRising = false
        /// Combined gain with a slow release, so a 20 Hz repaint still catches
        /// the flash of a fast arpeggio on the pads and the LEDs.
        var meter: Float = 0
        var partialCount: Int32 = 0
        var lpL1: Float = 0, lpL2: Float = 0
        var lpR1: Float = 0, lpR2: Float = 0
        var combIdx: Int32 = 0
        var combLP: Float = 0
        var jawariHP: Float = 0
        var releaseScale: Float = 1
    }

    private let voices: UnsafeMutablePointer<Voice>
    private let table: UnsafeMutablePointer<Float>

    // Flat per-voice-per-partial arrays: index = voice * maxPartials + p
    private let phaseA: UnsafeMutablePointer<Double>
    private let phaseB: UnsafeMutablePointer<Double>
    private let incA: UnsafeMutablePointer<Double>
    private let incB: UnsafeMutablePointer<Double>
    private let gAL: UnsafeMutablePointer<Float>
    private let gAR: UnsafeMutablePointer<Float>
    private let gBL: UnsafeMutablePointer<Float>
    private let gBR: UnsafeMutablePointer<Float>

    /// Four allpass stages × (x1, y1) × two channels, per voice.
    private let apState: UnsafeMutablePointer<Float>
    private let combBuf: UnsafeMutablePointer<Float>

    // The timbre catalog, flattened at init. Reading `TimbreCatalog.all` on the
    // render thread would mean ARC traffic on the render thread, which is how
    // you get dropouts under load; these are plain C buffers.
    private let timbreCount: Int
    private let tbRatio: UnsafeMutablePointer<Double>   // timbre * maxPartials + p
    private let tbAmp: UnsafeMutablePointer<Float>      // already loudness-normalized
    private let tbPartials: UnsafeMutablePointer<Int32>
    private let tbCutoff: UnsafeMutablePointer<Double>
    private let tbBeat: UnsafeMutablePointer<Double>
    private let tbSitarBias: UnsafeMutablePointer<Float>
    private let tbSwell: UnsafeMutablePointer<Double>
    /// Per-partial pan fan and beat offsets, precomputed.
    private let partialFan: UnsafeMutablePointer<Double>
    private let beatOffset: UnsafeMutablePointer<Double>
    /// Six modulation periods per voice, resolved from the prime table at init:
    /// drift A, drift B, tremolo, filter, pan, sitar sweep.
    private let voicePeriod: UnsafeMutablePointer<Double>

    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>

    private var sampleRate = 44100.0
    private var timeSamples: Double = 0

    // Master chain
    private let cathedral = Cathedral()
    private var shelfLoL = Biquad(), shelfLoR = Biquad()
    private var dipL = Biquad(), dipR = Biquad()
    private var shelfHiL = Biquad(), shelfHiR = Biquad()
    private var eqDirty = true
    private var lastWarmth: Float = -1, lastPresence: Float = -1, lastAir: Float = -1
    private var limiterEnv: Float = 0
    private var limiterGain: Float = 1
    private var volumeSmoothed: Float = 0
    private var swellSmoothed: Float = 1
    private var widthSmoothed: Float = 1
    private var driveSmoothed: Float = 0

    public init() {
        let vc = Self.voiceCount
        let mp = Self.maxPartials

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timebaseScale = Double(timebase.numer) / Double(timebase.denom)

        voices = .allocate(capacity: vc)
        voices.initialize(repeating: Voice(), count: vc)

        table = .allocate(capacity: Self.tableSize + 1)
        for i in 0...Self.tableSize {
            table[i] = Float(sin(2.0 * Double.pi * Double(i) / Double(Self.tableSize)))
        }

        func dbuf(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        func fbuf(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }

        phaseA = dbuf(vc * mp)
        phaseB = dbuf(vc * mp)
        incA = dbuf(vc * mp)
        incB = dbuf(vc * mp)
        gAL = fbuf(vc * mp)
        gAR = fbuf(vc * mp)
        gBL = fbuf(vc * mp)
        gBR = fbuf(vc * mp)
        apState = fbuf(vc * 16)
        combBuf = fbuf(vc * Self.combSize)
        scratchL = fbuf(Self.maxFrames)
        scratchR = fbuf(Self.maxFrames)
        meters = fbuf(vc + 1)

        // Flatten the timbre catalog.
        let catalog = TimbreCatalog.all
        timbreCount = catalog.count
        tbRatio = dbuf(timbreCount * mp)
        tbAmp = fbuf(timbreCount * mp)
        tbCutoff = dbuf(timbreCount)
        tbBeat = dbuf(timbreCount)
        tbSwell = dbuf(timbreCount)
        tbSitarBias = fbuf(timbreCount)
        tbPartials = UnsafeMutablePointer<Int32>.allocate(capacity: timbreCount)
        tbPartials.initialize(repeating: 0, count: timbreCount)
        for (ti, t) in catalog.enumerated() {
            let count = min(t.partials.count, mp)
            tbPartials[ti] = Int32(count)
            // Normalize by the amplitude sum so swapping timbres doesn't jump
            // the level, and bake the stretch into the ratio while we're here.
            var sum = 0.0
            for p in 0..<count { sum += t.partials[p].a }
            let norm = Float(0.62 / max(0.001, sum))
            for p in 0..<count {
                let h = t.partials[p].h
                tbRatio[ti * mp + p] = t.inharmonicity > 0
                    ? h * (1.0 + t.inharmonicity * h * h).squareRoot() : h
                tbAmp[ti * mp + p] = Float(t.partials[p].a) * norm
            }
            tbCutoff[ti] = t.cutoffScale
            tbBeat[ti] = t.beatScale
            tbSwell[ti] = t.swellScale
            tbSitarBias[ti] = Float(t.sitarBias)
        }

        // Each voice gets its own set of prime periods. The strides are mutually
        // prime with the table length so no two voices ever share one.
        voicePeriod = dbuf(vc * 6)
        let pc = Self.primes.count
        for v in 0..<vc {
            let strides = [(3, 0), (3, 11), (5, 7), (7, 3), (11, 5), (13, 9)]
            for (j, s) in strides.enumerated() {
                voicePeriod[v * 6 + j] = Self.primes[(v * s.0 + s.1) % pc]
            }
        }

        partialFan = dbuf(mp)
        beatOffset = dbuf(mp)
        for p in 0..<mp {
            // Fundamental dead centre; harmonics fan out alternately.
            partialFan[p] = p == 0 ? 0 : (p % 2 == 0 ? -1.0 : 1.0) * min(1.0, Double(p) / 6.0) * 0.85
            beatOffset[p] = Self.beatOffsets[p % Self.beatOffsets.count]
        }

        // Stagger the starting phases so a fresh chord doesn't stack every
        // partial at zero and thump.
        for v in 0..<vc {
            for p in 0..<mp {
                phaseA[v * mp + p] = Double((v * 7 + p * 13) % 97) / 97.0
                phaseB[v * mp + p] = Double((v * 11 + p * 5) % 89) / 89.0
            }
        }
    }

    deinit {
        voices.deallocate()
        table.deallocate()
        phaseA.deallocate(); phaseB.deallocate(); incA.deallocate(); incB.deallocate()
        gAL.deallocate(); gAR.deallocate(); gBL.deallocate(); gBR.deallocate()
        apState.deallocate(); combBuf.deallocate()
        scratchL.deallocate(); scratchR.deallocate()
        meters.deallocate()
        tbRatio.deallocate(); tbAmp.deallocate(); tbPartials.deallocate()
        tbCutoff.deallocate(); tbBeat.deallocate()
        tbSitarBias.deallocate(); tbSwell.deallocate()
        partialFan.deallocate(); beatOffset.deallocate(); voicePeriod.deallocate()
    }

    public func setSampleRate(_ sr: Double) {
        guard sr > 8000, sr <= Self.maxSampleRate, sr != sampleRate else { return }
        sampleRate = sr
        cathedral.setSampleRate(sr)
        eqDirty = true
        shelfLoL.reset(); shelfLoR.reset()
        dipL.reset(); dipR.reset()
        shelfHiL.reset(); shelfHiR.reset()
    }

    // MARK: - Control surface

    public func gate(pad: Int, on: Bool) {
        events.push(DroneEvent(.gate, pad: pad, value: on ? 1 : 0))
    }

    public func setLevel(pad: Int, level: Double) {
        events.push(DroneEvent(.level, pad: pad, value: level))
    }

    public func setSitar(pad: Int, depth: Double) {
        events.push(DroneEvent(.sitar, pad: pad, value: depth))
    }

    public func retune(pad: Int, frequency: Double) {
        events.push(DroneEvent(.retune, pad: pad, value: frequency))
    }

    /// Strike an accent on a voice. Safe to call from the pulse queue — the
    /// event queue is the only thing it touches.
    public func pluck(pad: Int, velocity: Double) {
        events.push(DroneEvent(.pluck, pad: pad, value: velocity))
    }

    /// Lets everything go. `seconds` overrides the fade time for this gesture.
    public func fadeAll(seconds: Double? = nil) {
        events.push(DroneEvent(.fadeAll, value: (seconds ?? fadeSeconds) / max(0.1, fadeSeconds)))
    }

    public func panic() {
        events.push(DroneEvent(.panic))
    }

    // MARK: - Render

    @inline(__always)
    private func osc(_ ph: Double) -> Float {
        let x = ph * Double(Self.tableSize)
        let i = Int(x) & Self.tableMask
        let f = Float(x - Double(Int(x)))
        let a = table[i]
        return a + (table[i + 1] - a) * f
    }

    @inline(__always)
    private func lfo(_ t: Double, _ period: Double, _ offset: Double) -> Double {
        var ph = t / period + offset
        ph -= floor(ph)
        return Double(osc(ph))
    }

    private func handle(_ e: DroneEvent) {
        guard let kind = DroneEvent.Kind(rawValue: e.kind) else { return }
        let p = Int(e.pad)
        switch kind {
        case .gate:
            guard p >= 0, p < Self.voiceCount else { return }
            let on = e.value > 0.5
            voices[p].gate = on
            voices[p].releaseScale = 1
            if on { voices[p].active = true }
        case .level:
            guard p >= 0, p < Self.voiceCount else { return }
            voices[p].level = Float(min(max(e.value, 0), 1))
        case .sitar:
            guard p >= 0, p < Self.voiceCount else { return }
            voices[p].sitar = Float(min(max(e.value, 0), 1))
        case .retune:
            guard p >= 0, p < Self.voiceCount, e.value > 8, e.value < 20_000 else { return }
            voices[p].targetFreq = e.value
            // Silent voices jump; anything audible — held *or* still ringing
            // from an accent — glides.
            if !voices[p].active || (voices[p].env < 1e-5 && voices[p].pluck < 1e-5) {
                voices[p].freq = e.value
            }
        case .pluck:
            guard p >= 0, p < Self.voiceCount else { return }
            voices[p].pluckPeak = Float(min(max(e.value, 0), 1))
            voices[p].pluckRising = true
            voices[p].active = true
        case .fadeAll:
            let scale = Float(min(max(e.value, 0.02), 4))
            for i in 0..<Self.voiceCount {
                voices[i].gate = false
                voices[i].releaseScale = scale
            }
        case .panic:
            for i in 0..<Self.voiceCount {
                voices[i].active = false
                voices[i].gate = false
                voices[i].env = 0
                voices[i].level = 0
                voices[i].pluck = 0
                voices[i].pluckPeak = 0
                voices[i].pluckRising = false
                voices[i].meter = 0
            }
            combBuf.update(repeating: 0, count: Self.voiceCount * Self.combSize)
            apState.update(repeating: 0, count: Self.voiceCount * 16)
            cathedral.clear()
            shelfLoL.reset(); shelfLoR.reset()
            dipL.reset(); dipR.reset()
            shelfHiL.reset(); shelfHiR.reset()
        }
    }

    public func render(frameCount: Int, out: UnsafeMutablePointer<AudioBufferList>) {
        let n = min(frameCount, Self.maxFrames)
        let startTicks = mach_absolute_time()
        events.drain { handle($0) }

        let abl = UnsafeMutableAudioBufferListPointer(out)
        let byteSize = UInt32(n * MemoryLayout<Float>.size)
        var chL = scratchL
        var chR = scratchR
        if abl.count >= 1 {
            if abl[0].mData == nil { abl[0].mData = UnsafeMutableRawPointer(scratchL) }
            abl[0].mDataByteSize = byteSize
            chL = abl[0].mData!.assumingMemoryBound(to: Float.self)
        }
        if abl.count >= 2 {
            if abl[1].mData == nil { abl[1].mData = UnsafeMutableRawPointer(scratchR) }
            abl[1].mDataByteSize = byteSize
            chR = abl[1].mData!.assumingMemoryBound(to: Float.self)
        } else {
            chR = chL
        }
        let mono = chR == chL
        for i in 0..<n { chL[i] = 0 }
        if !mono { for i in 0..<n { chR[i] = 0 } }
        let outR = mono ? scratchR : chR
        if mono { for i in 0..<n { outR[i] = 0 } }

        renderVoices(n, chL, outR)
        renderMaster(n, chL, outR)
        if mono {
            for i in 0..<n { chL[i] = (chL[i] + outR[i]) * 0.5 }
        }
        timeSamples += Double(n)

        // How much of the deadline did that take? mach_absolute_time is safe
        // to call from a render thread.
        let elapsedNs = Double(mach_absolute_time() - startTicks) * timebaseScale
        let budgetNs = Double(n) / sampleRate * 1e9
        if budgetNs > 0 {
            let load = Float(elapsedNs / budgetNs)
            if load >= 1 { renderOverruns &+= 1 }
            // Decaying peak hold, so a brief spike stays readable on screen.
            loadPeak = max(load, loadPeak * 0.99)
            renderLoad = loadPeak
        }
        var active: Int32 = 0
        for v in 0..<Self.voiceCount where voices[v].active { active += 1 }
        activeVoices = active
    }

    /// Clears the overrun tally after the user has seen it.
    public func resetRenderStats() {
        renderOverruns = 0
        loadPeak = 0
    }

    // MARK: - Voices

    private func renderVoices(_ n: Int, _ chL: UnsafeMutablePointer<Float>, _ chR: UnsafeMutablePointer<Float>) {
        let sr = sampleRate
        let mp = Self.maxPartials
        let ti = Int(min(max(timbreIndex, 0), Int32(timbreCount - 1)))
        let tBase = ti * mp
        let specCount = Int(tbPartials[ti])
        let sitarBias = tbSitarBias[ti]

        let swellTau = max(0.05, swellSeconds * tbSwell[ti] / 3.0)
        let attackCoef = 1.0 - Float(exp(-1.0 / (swellTau * sr)))
        let glideCoef = 1.0 - Float(exp(-1.0 / (0.55 * sr)))

        // Accent envelope. The attack aims a little past its target so it
        // actually gets there in the time asked for; the decay is a −60 dB
        // time, which is what "how long does that note last" means to an ear.
        let pluckAtkCoef = 1.0 - Float(exp(-2.2 / (max(0.001, pluckAttack) * sr)))
        let pluckDecCoef = 1.0 - Float(exp(-6.9 / (max(0.02, pluckDecay) * sr)))

        let beatBase = Double(min(max(beating, 0), 1)) * 1.10 * tbBeat[ti]
        let driftCentsMax = Double(min(max(drift, 0), 1)) * 9.0
        let motionAmt = Double(min(max(motion, 0), 1))
        let cutoffBase = 320.0 * pow(28.0, Double(min(max(brightness, 0), 1))) * tbCutoff[ti]
        let nyquistish = sr * 0.46

        for v in 0..<Self.voiceCount where voices[v].active {
            var vc = voices[v]
            let releaseTau = max(0.05, fadeSeconds * Double(vc.releaseScale) / 3.0)
            let releaseCoef = 1.0 - Float(exp(-1.0 / (releaseTau * sr)))

            // Resolved at init — the prime table is a Swift Array and must not
            // be touched from here.
            let vp = v * 6
            let pDriftA = voicePeriod[vp]
            let pDriftB = voicePeriod[vp + 1]
            let pAmp    = voicePeriod[vp + 2]
            let pFilt   = voicePeriod[vp + 3]
            let pPan    = voicePeriod[vp + 4]
            let pSitar  = voicePeriod[vp + 5]
            let off = Double(v) * 0.6180339887

            let base = v * mp
            var i = 0
            while i < n {
                let count = min(Self.controlChunk, n - i)
                let t = (timeSamples + Double(i)) / sr

                // --- Block-rate modulation -------------------------------
                vc.freq += (vc.targetFreq - vc.freq) * Double(glideCoef) * Double(count)
                if abs(vc.freq - vc.targetFreq) < 0.0005 { vc.freq = vc.targetFreq }

                let driftCents = driftCentsMax
                    * (0.62 * lfo(t, pDriftA, off) + 0.38 * lfo(t, pDriftB, off * 1.7))
                let f0 = vc.freq * pow(2.0, driftCents / 1200.0)

                let ampMod = Float(1.0 - motionAmt * 0.16 * (0.5 - 0.5 * lfo(t, pAmp, off * 2.3)))
                let cutoff = cutoffBase * pow(2.0, motionAmt * 0.75 * lfo(t, pFilt, off * 3.1))
                let lpCoef = 1.0 - Float(exp(-2.0 * Double.pi * min(cutoff, nyquistish) / sr))
                let voicePan = motionAmt * 0.45 * lfo(t, pPan, off * 4.7)

                vc.sitarSm += (min(1, vc.sitar + sitarBias) - vc.sitarSm) * 0.004 * Float(count)
                let sitarAmt = vc.sitarSm
                // The phaser sweep is itself on a prime period, so two sitar
                // voices never swirl together.
                let apG = Float(0.28 + 0.55 * (0.5 + 0.5 * lfo(t, pSitar * 0.11, off * 5.3)))

                var np = 0
                for p in 0..<specCount {
                    let fa = f0 * tbRatio[tBase + p]
                    if fa > nyquistish { continue }
                    let fb = fa + beatBase * beatOffset[p]
                    incA[base + np] = fa / sr
                    incB[base + np] = fb / sr

                    let amp = tbAmp[tBase + p] * ampMod
                    let fan = partialFan[p]
                    let panA = min(1.0, max(-1.0, fan * 0.9 + voicePan - 0.10))
                    let panB = min(1.0, max(-1.0, fan * 0.9 + voicePan + 0.10))
                    gAL[base + np] = amp * sqrtf(Float(0.5 * (1.0 - panA)))
                    gAR[base + np] = amp * sqrtf(Float(0.5 * (1.0 + panA)))
                    gBL[base + np] = amp * sqrtf(Float(0.5 * (1.0 - panB)))
                    gBR[base + np] = amp * sqrtf(Float(0.5 * (1.0 + panB)))
                    if np != p {
                        phaseA[base + np] = phaseA[base + p]
                        phaseB[base + np] = phaseB[base + p]
                    }
                    np += 1
                }
                vc.partialCount = Int32(np)

                // Jawari comb: one period of the fundamental, so it reinforces
                // the harmonic series rather than fighting it.
                let combLen = np > 0
                    ? Int32(min(Double(Self.combSize - 4), max(8.0, sr / max(20.0, f0))))
                    : 8
                let combFb = 0.55 + 0.28 * sitarAmt
                let combLPCoef = 1.0 - Float(exp(-2.0 * Double.pi * 5200.0 / sr))
                let jawariHPCoef = 1.0 - Float(exp(-2.0 * Double.pi * 700.0 / sr))
                let combBase = v * Self.combSize

                // --- Sample loop ------------------------------------------
                let target = vc.gate ? vc.level : 0
                for j in 0..<count {
                    let idx = i + j
                    let coef = target > vc.env ? attackCoef : releaseCoef
                    vc.env += (target - vc.env) * coef

                    if vc.pluckRising {
                        vc.pluck += (vc.pluckPeak * 1.25 - vc.pluck) * pluckAtkCoef
                        if vc.pluck >= vc.pluckPeak {
                            vc.pluck = vc.pluckPeak
                            vc.pluckRising = false
                        }
                    } else if vc.pluck > 1e-6 {
                        vc.pluck -= vc.pluck * pluckDecCoef
                    }

                    var sL: Float = 0
                    var sR: Float = 0
                    for p in 0..<np {
                        let k = base + p
                        let a = osc(phaseA[k])
                        let b = osc(phaseB[k])
                        sL += a * gAL[k] + b * gBL[k]
                        sR += a * gAR[k] + b * gBR[k]
                        var pa = phaseA[k] + incA[k]
                        if pa >= 1.0 { pa -= 1.0 }
                        phaseA[k] = pa
                        var pb = phaseB[k] + incB[k]
                        if pb >= 1.0 { pb -= 1.0 }
                        phaseB[k] = pb
                    }

                    // Two-pole lowpass per side — the "brightness breathing".
                    vc.lpL1 += (sL - vc.lpL1) * lpCoef
                    vc.lpL2 += (vc.lpL1 - vc.lpL2) * lpCoef
                    vc.lpR1 += (sR - vc.lpR1) * lpCoef
                    vc.lpR2 += (vc.lpR1 - vc.lpR2) * lpCoef
                    var oL = vc.lpL2
                    var oR = vc.lpR2

                    if sitarAmt > 0.001 {
                        // Four-stage allpass phaser: the "slight phase".
                        var xL = oL
                        var xR = oR
                        for s in 0..<4 {
                            let sb = v * 16 + s * 4
                            let yL = -apG * xL + apState[sb] + apG * apState[sb + 1]
                            apState[sb] = xL
                            apState[sb + 1] = yL
                            xL = yL
                            let yR = -apG * xR + apState[sb + 2] + apG * apState[sb + 3]
                            apState[sb + 2] = xR
                            apState[sb + 3] = yR
                            xR = yR
                        }
                        let ph = sitarAmt * 0.75
                        oL += (xL - oL) * ph
                        oR += (xR - oR) * ph

                        // Jawari bridge: an expansive odd-order shaper into a
                        // comb tuned to the fundamental. This is the buzz.
                        // x + 0.85·x·|x| is an odd function, so it sheds odd
                        // harmonics only — a real jawari gives the whole series,
                        // so this reads a little hollow beside the real thing.
                        // It also *grows* with level rather than compressing,
                        // which is why the clamp below has to be there.
                        let mono = (oL + oR) * 0.5
                        var rp = vc.combIdx - combLen
                        if rp < 0 { rp += Int32(Self.combSize) }
                        let delayed = combBuf[combBase + Int(rp)]
                        vc.combLP += (delayed - vc.combLP) * combLPCoef
                        let shaped = mono + 0.85 * mono * abs(mono)
                        let fed = shaped + vc.combLP * combFb
                        let clipped = fed > 1.6 ? 1.6 : (fed < -1.6 ? -1.6 : fed)
                        combBuf[combBase + Int(vc.combIdx)] = clipped
                        vc.combIdx += 1
                        if vc.combIdx >= Int32(Self.combSize) { vc.combIdx = 0 }
                        vc.jawariHP += (clipped - vc.jawariHP) * jawariHPCoef
                        let buzz = (clipped - vc.jawariHP) * sitarAmt * 0.30
                        oL += buzz
                        oR += buzz
                    }

                    // The accent rides *on top of* the drone rather than
                    // replacing it, and gets out of the way as the held level
                    // rises so a loud tone doesn't get an absurd spike.
                    let g = vc.env + vc.pluck * (1.0 - 0.6 * vc.env)
                    chL[idx] += oL * g
                    chR[idx] += oR * g
                }

                // Peak-with-slow-release, updated once a control chunk. Falls
                // from full to nothing in about 65 ms, so a fast arpeggio still
                // reads on a 20 Hz repaint instead of strobing.
                vc.meter = max(min(1, vc.env + vc.pluck), vc.meter - 0.015)
                meters[v] = vc.meter
                i += count
            }

            if !vc.gate && vc.env < 2e-5 && vc.pluck < 2e-5 && !vc.pluckRising {
                vc.active = false
                vc.env = 0
                vc.pluck = 0
                vc.meter = 0
                meters[v] = 0
                vc.lpL1 = 0; vc.lpL2 = 0; vc.lpR1 = 0; vc.lpR2 = 0
                vc.combLP = 0; vc.jawariHP = 0
            }
            voices[v] = vc
        }

        for v in 0..<Self.voiceCount where !voices[v].active {
            meters[v] = 0
        }
    }

    // MARK: - Master chain

    private func renderMaster(_ n: Int, _ chL: UnsafeMutablePointer<Float>, _ chR: UnsafeMutablePointer<Float>) {
        let sr = sampleRate

        // Spectral balance: warm bottom, restrained 2–5 kHz, soft air on top.
        if eqDirty || warmth != lastWarmth || presenceCut != lastPresence || air != lastAir {
            let w = Double(min(max(warmth, 0), 1))
            let p = Double(min(max(presenceCut, 0), 1))
            let a = Double(min(max(air, 0), 1))
            shelfLoL.lowShelf(165, -1.0 + w * 8.0, sr); shelfLoR.lowShelf(165, -1.0 + w * 8.0, sr)
            dipL.peaking(3200, -p * 7.0, 0.9, sr);      dipR.peaking(3200, -p * 7.0, 0.9, sr)
            shelfHiL.highShelf(9000, -3.0 + a * 8.0, sr); shelfHiR.highShelf(9000, -3.0 + a * 8.0, sr)
            lastWarmth = warmth; lastPresence = presenceCut; lastAir = air
            eqDirty = false
        }

        let driveTarget = min(max(drive, 0), 1)
        let widthTarget = min(max(width, 0), 2)
        let volTarget = min(max(masterVolume, 0), 1)
        let swellTarget = min(max(globalSwell, 0), 1)
        let limAtk = 1.0 - Float(exp(-1.0 / (0.004 * sr)))
        let limRel = 1.0 - Float(exp(-1.0 / (0.35 * sr)))

        for i in 0..<n {
            driveSmoothed += (driveTarget - driveSmoothed) * 0.0008
            var l = shelfLoL.process(chL[i])
            var r = shelfLoR.process(chR[i])
            l = dipL.process(l);  r = dipR.process(r)
            l = shelfHiL.process(l); r = shelfHiR.process(r)

            if driveSmoothed > 0.001 {
                let pre = 1.0 + driveSmoothed * driveSmoothed * 5.0
                let makeup = 1.0 / (1.0 + driveSmoothed * 0.75)
                l = tanhf(l * pre) * makeup
                r = tanhf(r * pre) * makeup
            }
            chL[i] = l
            chR[i] = r
        }

        cathedral.process(n, chL, chR,
                          decay: reverbDecay, damp: reverbDamp, size: reverbSize,
                          mix: reverbMix, rotate: spatialDrift,
                          time: timeSamples / sr)

        var peak: Float = 0
        for i in 0..<n {
            widthSmoothed += (widthTarget - widthSmoothed) * 0.0008
            volumeSmoothed += (volTarget - volumeSmoothed) * 0.0008
            swellSmoothed += (swellTarget - swellSmoothed) * 0.0015

            // Mid/side width — the fundamental stays put, the field opens up.
            let m = (chL[i] + chR[i]) * 0.5
            let s = (chL[i] - chR[i]) * 0.5 * widthSmoothed
            var l = m + s
            var r = m - s

            let g = volumeSmoothed * swellSmoothed
            l *= g
            r *= g

            let mag = max(abs(l), abs(r))
            limiterEnv += (mag - limiterEnv) * (mag > limiterEnv ? limAtk : limRel)
            let want: Float = limiterEnv > 0.88 ? 0.88 / limiterEnv : 1
            limiterGain += (want - limiterGain) * (want < limiterGain ? limAtk : limRel)
            l *= limiterGain
            r *= limiterGain

            chL[i] = tanhf(l)
            chR[i] = tanhf(r)
            let pk = max(abs(chL[i]), abs(chR[i]))
            if pk > peak { peak = pk }
        }
        meters[Self.voiceCount] = peak
    }
}
