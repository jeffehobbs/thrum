import Foundation
import AVFoundation

/// A flight recorder for the things that only go wrong on a walk.
///
/// This exists because of a specific report — "breaks, hiccups almost, in the
/// head-tracked audio" on a hike — and because there are at least four
/// explanations for it that sound equally plausible from the code and are
/// indistinguishable by ear:
///
/// 1. **Bluetooth dropping**, which is what AirPods do outdoors with a phone in a
///    pocket and a body between the two. Nothing to do with this app.
/// 2. **CoreMotion going quiet** while the app is in the background, which would
///    freeze the field and then jump it when updates resume.
/// 3. **The route flapping**, which toggles the whole spatial path — sixteen HRTF
///    buses against a stereo pair — with no crossfade between them.
/// 4. **The render block actually overrunning** on an A14 with sixteen HRTF
///    sources, which is the only one of the four that is a DSP problem.
///
/// Guessing between those has a poor record in this project: crackle was twice
/// diagnosed confidently from code reasoning and twice disproved by measurement.
/// So rather than pick one and "fix" it, this writes what actually happened to a
/// file in the app container, which survives the walk and can be pulled off
/// afterwards:
///
///     xcrun devicectl device copy from --device <id> \
///       --domain-type appDataContainer --domain-identifier com.jeffhobbs.thrumflow \
///       --source Library/Application\ Support/Thrum/flight.log --destination .
///
/// Everything here is off the main thread's critical path and nowhere near the
/// audio thread: one formatted line appended on a utility queue, plus a heartbeat
/// twice a minute. The whole point is that it can be left on.
final class FlightRecorder {
    static let shared = FlightRecorder()

    /// Beyond this the file is started again from scratch. A hike is a couple of
    /// hundred lines; this is room for weeks of them, and a log that grows without
    /// limit on someone's phone is its own bug.
    private static let sizeLimit = 512 * 1024

    private let queue = DispatchQueue(label: "com.jeffhobbs.thrum.flight", qos: .utility)
    private let url: URL?
    private let started = Date()
    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // Alongside taste.json rather than through `Taste.defaultStore`, which is
        // main-actor isolated and this is not — the recorder has to be reachable
        // from anywhere, including a notification handler.
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Thrum/flight.log")
    }

    func note(_ message: String) {
        guard let url else { return }
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            if size > Self.sizeLimit { try? fm.removeItem(at: url) }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    var path: String { url?.path ?? "(nowhere)" }
}

/// What the heartbeat samples, and why each one is here.
///
/// The four hypotheses above each leave a different fingerprint in these numbers,
/// which is the entire design: one line every thirty seconds should say which of
/// them happened without anyone having to reproduce it on a bench.
///
/// - `overruns` climbing → the render block missed its deadline. That is ours, and
///   it is the only reading here that means the DSP is at fault.
/// - `load` near 1.0 with no overruns → we are close to the edge and a thermal dip
///   would push us over.
/// - `motion` falling to zero while spatial is on → CoreMotion stopped feeding us,
///   so the field froze. Backgrounding is the suspect.
/// - `motion` healthy, `overruns` flat, and the listener still reporting breaks →
///   the audio never reached the ears intact, i.e. Bluetooth. Not ours to fix, but
///   worth knowing before rewriting a working render path.
/// - `peak` rate and `clamped` → added for a fifth report, "a warble when I tilt my
///   head up and down, worst on the higher voices", **and they caught it.** Three
///   offline measurements had already ruled out the obvious DSP explanations:
///   AVAudioEnvironmentNode crossfades its HRTF hand-overs cleanly (boundary
///   roughness 1.00× interior at every frequency from 110 Hz to 5 kHz), it snaps to
///   its filter grid no harder in elevation than in azimuth (9 cliffs across 45° of
///   pitch against 15 of yaw), and a realistic nod moves the high-band wobble only
///   0.18 dB above a still listener's own 2.81 dB. So the render path was not doing
///   it, which left the angles we hand it — and those come from a sensor no harness
///   can fake.
///
///   A head turns at 100–200°/s, so a `peak` in the thousands is a step rather than
///   a movement. On the hike of 2026-08-12 it read up to **8352°/s on yaw and roll
///   simultaneously, matching each other to within 0.02%**, while pitch stayed
///   ordinary and `overruns` and the motion rate were both perfect. That pattern is
///   an Euler singularity, not a sensor fault: pitch is the middle axis of
///   CMAttitude's Z-X-Y decomposition, so near ±90° yaw and roll stop being
///   separable. `clamped` (11–112 per 30 s on the same lines) was the slew limit
///   dutifully spreading a 168° phantom step over half a second, which is what the
///   listener heard.
///
///   **This is now one number, not three, because three was the mistake.** Per-axis
///   rates are a property of the chart rather than of the head; the transport carries
///   a quaternion and reports the geodesic rate, so a high reading here once again
///   means what it always claimed to mean. `clamped` staying at zero through a
///   session that used to warble is the check that the fix took.
struct FlightSample {
    var load: Float = 0
    var overruns: Int32 = 0
    var motionUpdates = 0
    var route = ""
    var spatial = false
    var tracking = false
    var transport = ""
    var buffer = ""
    var peakRate = 0.0
    var clampedFrames = 0
    var listenerWrites = 0
    /// Output cycles that went out without us — see `SpatialPump`. `overruns` is our
    /// DSP missing its deadline; `gaps` is the audio having a hole in it for any reason
    /// at all, including the sixteen HRTFs, AVAudioEngine's graph lock and Bluetooth.
    /// The pair is the whole point: `gaps` high with `overruns 0` means the hole is
    /// below us, which is where three offline measurements have now pointed.
    var gaps = 0
    var gapMilliseconds = 0.0
    var largestGapMilliseconds = 0.0
    /// Where the head was pointing, and whether the sample stream went quiet — see
    /// `HeadTracker.peakTilt`. Added for the 08-13 report, whose one reproducible
    /// clue was an angle ("looking all the way down towards my feet") that nothing in
    /// this line was a function of. `stall` is the gap the aggregate `motion` count
    /// cannot show: half a second of silence from the AirPods is 25 samples out of
    /// 1500 and reads as noise, while being long enough for the field to freeze and
    /// then slew to catch up.
    var peakTilt = 0.0
    /// Where the gaze actually sat, referenced and raw — see `HeadTracker.tiltSpread`.
    var tiltLow = 0.0, tiltMedian = 0.0, tiltHigh = 0.0
    var rawLow = 0.0, rawMedian = 0.0, rawHigh = 0.0
    var stalls = 0
    var longestStallMilliseconds = 0.0
    var tiltAtStall = 0.0
    /// Whether iOS is spatialising our already-binaural output a second time — see
    /// `FlowHost.systemSpatialization`. The only term in this line that describes
    /// something happening *downstream* of the app.
    var systemSpatial = false

    var line: String {
        String(format: "heartbeat  load %.2f  overruns %d  motion %d/30s  %@  spatial %@  tracking %@  %@  %@"
               + "  peak %.0f°/s  clamped %d  writes %d  gaps %d (%.0f ms, worst %.0f)"
               + "  tilt %.0f…%.0f (med %.0f)  raw %.0f…%.0f (med %.0f)"
               + "  stalls %d (worst %.0f ms at %.0f°)  system-spatial %@",
               load, overruns, motionUpdates, route as NSString,
               spatial ? "on" : "off", tracking ? "on" : "off",
               transport as NSString, buffer as NSString,
               peakRate, clampedFrames, listenerWrites,
               gaps, gapMilliseconds, largestGapMilliseconds,
               tiltLow, tiltHigh, tiltMedian, rawLow, rawHigh, rawMedian,
               stalls, longestStallMilliseconds, tiltAtStall,
               (systemSpatial ? "ON" : "off") as NSString)
    }
}

/// Watches the amplitude of what actually leaves the app, and says when it drops.
///
/// The listener's own suggestion, moved onto the device: "can't we look at the synth
/// drone tone volume/amplitude signal and look for sudden drops to zero?" Offline it
/// found nothing — two hours of Flow never fell more than 10.7 dB in 32 ms, and the
/// full chain with a head that looks at its feet thirty times shows no dependence on
/// gaze angle at all. But every one of those runs is a *simulation* of the two things
/// that cannot be simulated: the real CoreMotion stream and the real Bluetooth link.
/// So the same measurement is made here, on the real signal, on the walk.
///
/// **Tapped at the main mixer**, which is deliberate: that is downstream of the
/// engine, the sixteen HRTFs, the environment node and the wet bed — everything the
/// app can be blamed for — so a drop seen here is real regardless of which stage
/// caused it, and a drop *not* seen here did not happen inside this app.
///
/// The detector is a two-timescale comparison rather than a threshold, because a
/// drone's level is always moving: a slow reference that decays gently, and the
/// current block against it. Flow taking a voice away moves both together over its
/// own long ramp and never triggers. A tone that stops moves only the fast one.
///
/// Nothing here allocates, logs or locks on the audio thread — the tap writes numbers
/// into plain fields and a timer on the main actor drains them. The benign race that
/// implies is the same one `meters` and `renderLoad` already rely on, and a lost
/// event is much cheaper than a lock on this thread.
final class DropoutWatch {
    /// How far below the running reference counts as a drop. 12 dB is well beyond
    /// anything the offline harnesses produced from ordinary musical movement, and
    /// far short of what "a tone cut out" sounds like.
    private static let depth: Float = 12
    /// The reference falls this fast, so it tracks the music down but not a cliff.
    ///
    /// **In dB per second, and that is the 08-14 fix.** This was `0.06` applied once
    /// per call and documented as "about 6 dB a second at ~10 ms a block" — but the
    /// tap is installed at 4096 frames and iOS actually hands us ~100 ms buffers, so
    /// the reference was decaying at 0.6 dB/s, ten times slower than intended. The
    /// symptom is in the log: both `AMPLITUDE DROP` lines from that walk are slow
    /// symmetric musical swells, roughly seven seconds down and eight back, which
    /// nothing would call a dropout. Anything falling faster than 0.6 dB/s eventually
    /// accumulates 12 dB of headroom against a reference that cannot follow it, so the
    /// detector was reporting Flow breathing.
    ///
    /// The buffer size is iOS's decision and it has already changed once, so the rate
    /// is now taken against the timestamps rather than against a block count that only
    /// ever agreed with the comment by accident.
    private static let decayPerSecond: Float = 6

    private var reference: Float = -120
    private var lastTime: Double?
    private var inDrop = false
    private var dropStart = 0.0
    private var dropDepth: Float = 0

    /// Written by the host whenever it re-points the listener; read on the audio
    /// thread. A stale value by one block is of no consequence — this only has to say
    /// roughly where the head was pointing when the sound went away.
    var gaze: Double = 0

    /// Drained by the host and logged. Set on the audio thread, cleared on the main.
    private(set) var pending: String?

    func observe(_ level: Float, at time: Double) {
        guard level > -120 else { return }
        // Clamped, because the first call has no predecessor and a resumed engine can
        // hand us a timestamp jump — either would drop the reference through the floor
        // and blind the detector for however long it took to climb back.
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.5))
        lastTime = time
        if level > reference { reference = level } else { reference -= Self.decayPerSecond * dt }

        let below = reference - level
        if !inDrop, below > Self.depth {
            inDrop = true
            dropStart = time
            dropDepth = below
        } else if inDrop {
            dropDepth = max(dropDepth, below)
            if below < Self.depth / 2 {
                inDrop = false
                let held = time - dropStart
                // Anything shorter than a couple of blocks is a transient, not a
                // tone going away.
                if held > 0.03 {
                    pending = String(format: "AMPLITUDE DROP — %.0f dB for %.0f ms, gaze %+.0f°",
                                     dropDepth, held * 1000, gaze)
                }
            }
        }
    }

    func drain() -> String? {
        defer { pending = nil }
        return pending
    }
}

/// A rolling window of what the audio and the head were doing, dumped on request.
///
/// The listener's idea: "what if we put a secret 'I heard the issue' button/gesture
/// in the app UI that you could use for debugging?" It is the right instrument for
/// the one thing five days of measurement has been unable to do — put a timestamp on
/// the symptom. Every automatic detector so far has had to guess what the fault looks
/// like in order to trigger on it, and each guess has been wrong: a threshold tuned
/// for a cut fires on Flow's own slow swells, and one tuned to ignore them may be
/// ignoring the fault. A human ear knows the difference without being told.
///
/// **The window is retroactive, and that is the whole design.** By the time a listener
/// has heard something, decided it was the fault, and got a phone out of a pocket,
/// five to fifteen seconds have gone. A marker that recorded only the moment of the
/// press would point at the wrong part of the walk. So this keeps the last thirty
/// seconds continuously and writes them out *backwards* from the press.
///
/// Fed from the audio tap that is already running rather than from a timer, so it adds
/// no wakeups at all — the cost is one array store per buffer, on a callback that
/// exists anyway, into memory allocated once. The head angles arrive the same way
/// `DropoutWatch.gaze` does: written by the host when it re-points the listener, read
/// here, benign by one buffer.
final class MarkBuffer {
    /// Five minutes, at the ~100 ms buffers the 4096-frame tap actually delivers.
    ///
    /// This was commented "thirty seconds at the 10 ms buffer" — the same units slip as
    /// `DropoutWatch.decayPerSecond`, since the tap runs at its own size rather than the
    /// render block's. The number is left alone on purpose: the window being ten times
    /// deeper than advertised is what made the 08-14 drift visible at all, because a
    /// reference walking 40° over five minutes says nothing in a thirty-second view.
    /// Only the description was wrong.
    private static let capacity = 3000

    private var level = [Float](repeating: -120, count: capacity)
    private var gaze = [Float](repeating: 0, count: capacity)
    private var raw = [Float](repeating: 0, count: capacity)
    private var interval = [Float](repeating: 0.01, count: capacity)
    private var write = 0
    private var filled = 0

    /// Written by the host, read on the audio thread.
    var currentGaze: Double = 0
    var currentRaw: Double = 0

    func record(_ db: Float, seconds: Float) {
        let i = write % Self.capacity
        level[i] = db
        gaze[i] = Float(currentGaze)
        raw[i] = Float(currentRaw)
        interval[i] = seconds
        write += 1
        if filled < Self.capacity { filled += 1 }
    }

    /// The window, oldest first, bucketed for a human reading a log file.
    ///
    /// Half-second buckets: fine enough to show a dropout "lasting a moment or two"
    /// as several distinct rows, coarse enough that one press costs sixty lines
    /// rather than three thousand.
    func dump(bucket: Double = 0.5) -> [String] {
        guard filled > 0 else { return ["  (nothing recorded yet)"] }
        // Walk backwards from the newest sample, accumulating elapsed time.
        var rows: [String] = []
        var agoEnd = 0.0
        var i = write - 1
        let stop = write - filled
        while i >= stop {
            var peak: Float = -200, trough: Float = 200
            var g: Float = 0, r: Float = 0
            var span = 0.0
            var n = 0
            while i >= stop, span < bucket {
                let k = ((i % Self.capacity) + Self.capacity) % Self.capacity
                peak = max(peak, level[k]); trough = min(trough, level[k])
                g = gaze[k]; r = raw[k]
                span += Double(interval[k])
                n += 1
                i -= 1
            }
            guard n > 0 else { break }
            rows.append(String(format: "    -%4.1fs  %6.1f…%6.1f dB   gaze %+4.0f°  raw %+4.0f°",
                               agoEnd + span, trough, peak, g, r))
            agoEnd += span
        }
        return rows.reversed()
    }
}
