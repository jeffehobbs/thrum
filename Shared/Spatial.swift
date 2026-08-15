import Foundation
import AVFoundation
import CoreMotion
import simd

/// Where the drone sits around you, and which way your head is pointing.
///
/// Thrum's grid already has two axes worth placing in a room: the eight columns
/// are scale degrees, and the four rows are octaves. So the field is a pair of
/// rings — the low two octaves slung slightly below the ear line, the high two
/// lifted above it — with the tonic dead ahead and the remaining degrees going
/// clockwise around you. A tone's position is therefore a fact about the music
/// rather than a decoration: an arpeggio walking up a column climbs, and a lane
/// walking across the mode orbits.

public struct SpatialField {
    /// Metres from the listener to the ring. Small is a helmet, large is a room.
    public var radius: Double = 1.6
    /// How far the two octave tiers are pushed apart vertically, in degrees.
    public var lift: Double = 22

    public init(radius: Double = 1.6, lift: Double = 22) {
        self.radius = radius
        self.lift = lift
    }

    public static let azimuths = 8

    /// Position of one bus. AVAudioEnvironmentNode is right-handed with the
    /// listener facing −z, so "ahead" is negative z and +x is to the right.
    public func position(bus: Int) -> AVAudio3DPoint {
        let tier = bus / Self.azimuths            // 0 = low octaves, 1 = high
        let col = bus % Self.azimuths
        let az = Double(col) / Double(Self.azimuths) * 2 * Double.pi
        let el = (tier == 0 ? -lift : lift) * Double.pi / 180
        let r = max(0.2, radius)
        return AVAudio3DPoint(x: Float(r * cos(el) * sin(az)),
                              y: Float(r * sin(el)),
                              z: Float(-r * cos(el) * cos(az)))
    }

    /// Human-readable compass label, for the UI.
    public static func label(bus: Int) -> String {
        let names = ["ahead", "45° R", "right", "135° R", "behind", "135° L", "left", "45° L"]
        let tier = bus / azimuths == 0 ? "low" : "high"
        return "\(names[bus % azimuths]) · \(tier)"
    }
}

/// One head orientation, in the two forms the rest of the app needs it.
///
/// `forward`/`up` are what the environment node is actually driven with. The three
/// angles are for the readout and for tests, and they are derived *from* the
/// rotation rather than being the thing carried around — see `HeadSmoother`.
public struct HeadOrientation {
    public var orientation: AVAudio3DVectorOrientation
    /// CoreMotion-convention angles, in degrees. Display only. These still go
    /// degenerate at pitch = ±90°, which is now harmless: nothing downstream reads
    /// them, and a number on a settings sheet being briefly ill-conditioned is not
    /// sixteen HRTFs being re-pointed.
    public var yaw: Double, pitch: Double, roll: Double

    public static let identity = HeadOrientation(
        orientation: AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1),
            up: AVAudio3DVector(x: 0, y: 1, z: 0)),
        yaw: 0, pitch: 0, roll: 0)
}

/// What one sample through the transport produced.
public struct HeadStep {
    public var head: HeadOrientation
    /// True angular speed of the *input* between this sample and the last, in
    /// degrees per second — the geodesic rate, not a per-axis one. This is the
    /// number that says whether a stream of samples is physically possible.
    public var rate: Double
    public var clamped: Bool

    public var yaw: Double { head.yaw }
    public var pitch: Double { head.pitch }
    public var roll: Double { head.roll }
}

/// The transport between one CoreMotion sample and sixteen HRTFs: the smoothing
/// that turns fifty samples a second into a field that turns rather than clicks,
/// and the limit that stops a bad sample being a rotation.
///
/// Pulled out of `HeadTracker` as a value type with no CoreMotion in it, because
/// `CMAttitude` has no public initialiser and anything reachable only through one is
/// untestable by construction. Everything interesting about the head-tracking
/// transport lives here, so `Tools/spatial` can drive it with a synthetic head.
///
/// **This smooths the rotation itself, not three Euler angles, and that is a fix
/// rather than a tidy-up.** It used to one-pole and rate-limit `CMAttitude`'s
/// `yaw`, `pitch` and `roll` independently, which is only meaningful while those
/// three numbers are independent — and they are not. CMAttitude reports Tait-Bryan
/// angles in Z-X-Y order, so **pitch is the middle axis**, and as pitch approaches
/// ±90° yaw and roll stop being separable: the same physical rotation can be
/// written with wildly different pairs of them.
///
/// ThrumFlow's flight recorder caught exactly that on a hike (2026-08-12): yaw and
/// roll taking equal-magnitude steps of up to **168° in a single 20 ms sample**,
/// agreeing with each other to within 0.02%, while pitch moved at an ordinary
/// 240°/s — with `overruns 0` and `motion 1500/30s` on the very same lines, so
/// neither the render path nor the sensor was involved. Offline, no spike at all
/// appears while relative pitch stays under ~75°; past 80° the rates hit ~9000°/s
/// with the yaw/roll agreement that fingerprints the singularity.
///
/// The rotation was smooth throughout. Only its decomposition was degenerate — but
/// the smoother could not know that, so it saw a 168° step and `maxDegreesPerSecond`
/// faithfully paid it out at 400°/s. **That is why the symptom is a warble lasting
/// nearly half a second rather than a click**, and why it is worst in the high end,
/// where elevation is carried by pinna notches at 5–10 kHz. The guard was doing its
/// job on a lie.
///
/// Why pitch reaches ±90° at all, given nobody looks straight up on a trail: it is
/// *relative* pitch, measured from a reference captured on the first sample after
/// `start()` — i.e. while the listener is looking down at the phone to press it.
/// That offsets the whole session by 50–60°, so an ordinary nod crosses vertical.
/// Referenced to the horizon it never comes close. `HeadTracker.recenter()` is the
/// user-facing cure for that, and now also the only thing the bias still costs.
///
/// Carrying a quaternion removes the failure mode instead of damping it: there is
/// no chart to fall off, `simd_slerp` takes the short way round on all three axes
/// at once (which the old code had to hand-fix per axis, and had missed on roll
/// until 1.4), and the rate handed to the flight recorder is the head's true
/// angular speed rather than an artifact of the chart.
public struct HeadSmoother {
    /// The one-pole's time constant, in seconds — enough to make the motion
    /// continuous without the room feeling like it lags the head.
    ///
    /// Expressed as a *time* rather than a per-sample coefficient, and that is a fix
    /// rather than a tidy-up. This was `smoothing = 0.28`, applied once per sample
    /// with no reference to `dt`, and documented as "~90 ms at CoreMotion's
    /// twenty-five samples a second". The second half of that sentence was the bug:
    /// a bare coefficient *is* a time constant divided by the sensor's rate, so it
    /// only means 0.12 s if the sensor really delivers 25 Hz.
    ///
    /// ThrumFlow's own flight recorder says it does not. Every AirPods Pro 2 session
    /// in the log reports `motion 1500/30s` — 50 Hz, dead on, twice the assumed rate
    /// — which made the real time constant 61 ms instead of 122 ms. Half the
    /// intended smoothing, so every head movement reached sixteen HRTFs about twice
    /// as twitchy as designed, on the one platform the feature was written for.
    ///
    /// 0.12 s is chosen to reproduce the old coefficient exactly at the rate it was
    /// tuned for: 1 − exp(−0.04/0.12) = 0.283. So nothing changes at 25 Hz, and at
    /// 50 Hz the smoothing is what it always claimed to be.
    public static let timeConstant = 0.12

    /// The per-sample coefficient for a given sample interval.
    public static func coefficient(for dt: Double) -> Double {
        1 - exp(-max(dt, 0.0001) / timeConstant)
    }

    /// The fastest the field is allowed to rotate, in degrees per second.
    ///
    /// Not a comfort feature — a limit on how wrong one bad sample can be. A head
    /// turns at 100–200°/s in ordinary use and perhaps 500°/s if something startles
    /// you, so at 400°/s this never touches a real movement. What it does touch is a
    /// *discontinuity*: an Euler angle that wraps, a reference re-seated mid-movement,
    /// or a dropped-and-resumed batch of Bluetooth samples all arrive as one enormous
    /// step, and a one-pole turns a 180° step into a 50° jump in a single 40 ms frame.
    /// Sixteen HRTFs re-pointed by 50° between one buffer and the next is not a
    /// rotation, it is an event — and an intermittent one, on whichever axis wrapped.
    public static let maxDegreesPerSecond = 400.0

    /// The longest gap between samples still treated as elapsed time when easing
    /// toward a new orientation.
    ///
    /// Without this the slew limit above is unenforceable against the one thing it
    /// was written for, and the 08-15 log says so in as many words: 32 stalls of up
    /// to 2 s, and `clamped 0` on every heartbeat. Both numbers are correct and
    /// together they are the bug.
    ///
    /// Both terms in `step` scale with `dt`, so a long gap relaxes them in exactly
    /// the wrong direction. At the 50 Hz the AirPods deliver, a one-pole moves 15%
    /// of the way to a new orientation per sample and the limiter allows 8° —
    /// sensible. After a 1.3 s gap the one-pole's fraction has risen to 1.000 and
    /// the limiter allows 520°, so the whole movement the head made while the
    /// stream was quiet is applied to sixteen HRTFs **in a single frame**, and the
    /// guard reports nothing because 40° really is less than 520°. A dropped
    /// Bluetooth batch is named in `maxDegreesPerSecond`'s own doc comment as a
    /// discontinuity it exists to catch; it was the one case it could not.
    ///
    /// Capping the interval makes a resumed stream look like an ordinary sample:
    /// the field eases to where the head now is over the following few samples,
    /// at a rate the limiter can and does police. 50 ms is longer than any real
    /// interval (20 ms at 50 Hz, 40 at 25) so nothing about normal operation
    /// changes, and short enough that a resumed stream catches up in about a third
    /// of a second.
    ///
    /// What a gap is *replaced* by is the stream's own recent interval rather than
    /// this constant, which is the difference between the first sample back being
    /// an ordinary one and it being twice as hard as one: at 50 Hz, substituting
    /// 50 ms would move the field 13.6° of a 40° movement in one frame where a real
    /// sample moves 6.1°. This threshold only decides *what counts as* a gap.
    ///
    /// Only the easing is capped. The leak still gets the true `dt`, because drift
    /// genuinely did accumulate for the whole gap and draining it is not an event
    /// anyone hears; and the reported rate still uses it, because the diagnostics'
    /// job is to describe the input rather than to flatter it.
    public static let maxCatchUpInterval = 0.05

    public static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    /// The change of frame from CoreMotion's axes to the environment node's, as a
    /// rotation to conjugate by.
    ///
    /// This is the same handedness reconciliation the app has always applied, in a
    /// form that survives the singularity. Both halves were *measured*, not read out
    /// of documentation, because deriving this by hand got it backwards once already:
    ///
    /// - `Tools/axis` established the node's own conventions by asking which ear a
    ///   source lands in: positions are −z ahead, +x right, +y up, and positive
    ///   listener yaw/roll turn the listener clockwise where positive CoreMotion
    ///   attitude is counterclockwise. Hence the long-standing `(-yaw, -pitch, -roll)`.
    /// - Reading `listenerVectorOrientation` back after *setting*
    ///   `listenerAngularOrientation` makes the node state its angular-to-vector
    ///   mapping itself: `R = Ry(−yaw)·Rx(pitch)·Rz(−roll)`.
    ///
    /// Composing those two says the shipped negation is exactly a 180° rotation about
    /// (0, 1, 1)/√2 — it sends CoreMotion's (right, forward, up) onto the node's
    /// (−x, z, y). That it is a *pure frame change* is the load-bearing part, and it
    /// was checked rather than assumed: conjugating by this and taking the node's own
    /// vectors agrees to **0.000000** across 400 random combined rotations, against
    /// the angular path the app shipped. So this rewrite cannot have moved the field,
    /// which for a notarized Mac app is the whole question. The same check identified
    /// CMAttitude's Euler order as Z-X-Y (the only one of six that matched), which is
    /// what makes pitch the middle axis and puts the singularity at ±90°.
    static let toListener = simd_quatd(angle: .pi,
                                      axis: simd_normalize(simd_double3(0, 1, 1)))

    /// Smoothed head rotation, in CoreMotion's frame. Starts at identity rather than
    /// snapping to the first sample, so a fresh reference glides in from dead ahead.
    private var current = Self.identity
    /// The previous *input*, kept only so the reported rate is the rate the sensor
    /// claimed the head was moving. Measuring it against the smoother's own output
    /// instead reports the tracking lag divided by the smoothing constant — an
    /// ordinary 50°/s nod reads as 171°/s that way, which would make the one number
    /// whose job is to say "this stream is not physically possible" say it always.
    private var previous: simd_quatd?
    /// What this stream's sample interval has recently been, so a late sample can
    /// be eased in as though it were an ordinary one. Nil until the first sample.
    private var typicalInterval: Double?

    public init() {}

    /// Into ±180°, so crossing the back of the head doesn't spin the field the long
    /// way round. Kept for the readout and for tests; the transport no longer needs
    /// it, because a geodesic has no seam to wrap at.
    public static func wrap(_ d: Double) -> Double {
        var v = (d + 180).truncatingRemainder(dividingBy: 360) - 180
        if v < -180 { v += 360 }
        return v
    }

    /// Angle of the shorter rotation between two orientations, in degrees.
    static func angle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
        // |dot| rather than dot: q and −q are the same rotation, and taking the
        // absolute value is what picks the short arc.
        let d = min(1.0, abs(simd_dot(a, b)))
        return 2 * acos(d) * 180 / .pi
    }

    /// A rotation as an axis scaled by its angle in radians — the quaternion log.
    ///
    /// Needed because `HeadTracker`'s drift leak has to treat one component of a
    /// rotation differently from the rest, and a quaternion offers nowhere to make
    /// that cut. A rotation vector does: it is an ordinary `simd_double3`, so the
    /// yaw part is a projection onto the vertical and the elevation part is what is
    /// left. Splitting Euler angles instead would reintroduce the exact chart that
    /// put a 168° step in the log — the whole point of this type is that nothing on
    /// the transport forms one.
    static func rotationVector(_ q: simd_quatd) -> simd_double3 {
        // q and −q are the same rotation but their logs point opposite ways; taking
        // the positive-real form is what keeps the leak pulling the short way round
        // instead of walking the long way through 360°.
        var imag = q.imag, real = q.real
        if real < 0 { imag = -imag; real = -real }
        let s = simd_length(imag)
        guard s > 1e-12 else { return .zero }
        return imag * (2 * atan2(s, real) / s)
    }

    /// And back, for composing the scaled correction on.
    static func rotation(vector v: simd_double3) -> simd_quatd {
        let a = simd_length(v)
        guard a > 1e-12 else { return identity }
        return simd_quatd(angle: a, axis: v / a)
    }

    /// One step of the drift leak: the correction moved a little way toward the
    /// current orientation, yaw and elevation at their own rates.
    ///
    /// Pulled out of `HeadTracker.ingest` so it can be measured rather than reasoned
    /// about — the same reason `toListener` is a constant and not three negations.
    /// `Tools/drift` drives it against the drift rate the 08-14 log actually recorded.
    ///
    /// Composed on the *left* throughout, which is what makes `up` mean anything: left
    /// multiplication is a rotation in the reference frame, where `up` lives, and right
    /// multiplication would be one in the head's own frame, where the split would
    /// follow the head around and each time constant would land on the wrong axis.
    public static func leaked(_ leak: simd_quatd, toward rel: simd_quatd,
                              up: simd_double3, dt: Double,
                              elevation: Double, yaw: Double) -> simd_quatd {
        let v = rotationVector(rel * leak.conjugate)
        let yawPart = simd_dot(v, up) * up
        let scaled = yawPart * (1 - exp(-dt / yaw))
                   + (v - yawPart) * (1 - exp(-dt / elevation))
        return rotation(vector: scaled) * leak
    }

    /// CoreMotion's Euler angles, composed into the rotation they describe.
    ///
    /// Z-X-Y, per the measurement above: `Rz(yaw)·Rx(pitch)·Ry(roll)`. Composing and
    /// then decomposing is lossless away from the singularity and, more to the point,
    /// *cancels* the degenerate yaw/roll split at it — which is why feeding this path
    /// the very angle pairs that used to produce a 168° lurch now produces none.
    public static func rotation(yaw: Double, pitch: Double, roll: Double) -> simd_quatd {
        let d = Double.pi / 180
        return simd_quatd(angle: yaw * d, axis: simd_double3(0, 0, 1))
             * simd_quatd(angle: pitch * d, axis: simd_double3(1, 0, 0))
             * simd_quatd(angle: roll * d, axis: simd_double3(0, 1, 0))
    }

    /// And back out again, for the readout only.
    static func euler(_ q: simd_quatd) -> (yaw: Double, pitch: Double, roll: Double) {
        // Read off the columns rather than indexing a matrix, because simd is
        // column-major and row/column confusion here is silent and wrong.
        let ex = q.act(simd_double3(1, 0, 0))
        let ey = q.act(simd_double3(0, 1, 0))
        let ez = q.act(simd_double3(0, 0, 1))
        let deg = 180 / Double.pi
        return (yaw: atan2(-ey.x, ey.y) * deg,
                pitch: asin(max(-1, min(1, ey.z))) * deg,
                roll: atan2(-ex.z, ez.z) * deg)
    }

    /// The orientation as the environment node wants it.
    static func listener(_ q: simd_quatd) -> AVAudio3DVectorOrientation {
        let l = toListener * q * toListener.conjugate
        let f = l.act(simd_double3(0, 0, -1))
        let u = l.act(simd_double3(0, 1, 0))
        return AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: Float(f.x), y: Float(f.y), z: Float(f.z)),
            up: AVAudio3DVector(x: Float(u.x), y: Float(u.y), z: Float(u.z)))
    }

    /// One sample in, the smoothed orientation out — plus what it took to get there,
    /// which is what the flight recorder reports.
    ///
    /// The real entry point. `CMAttitude.quaternion` is singularity-free, so nothing
    /// on this path ever forms an Euler angle except the readout at the end.
    public mutating func step(rotation target: simd_quatd, dt: Double) -> HeadStep {
        // Not `dt` — see `maxCatchUpInterval`. A gap in the stream must not buy the
        // field permission to jump, so a late sample is eased in as though it had
        // arrived on time, at whatever "on time" has recently meant.
        let ease: Double
        if dt <= Self.maxCatchUpInterval {
            typicalInterval = typicalInterval.map { $0 * 0.9 + dt * 0.1 } ?? dt
            ease = dt
        } else {
            ease = typicalInterval ?? Self.maxCatchUpInterval
        }
        let limit = Self.maxDegreesPerSecond * ease
        let smoothing = Self.coefficient(for: ease)

        // The one-pole, on the geodesic: move a fixed fraction of the remaining
        // rotation each sample, exactly as before, but along the shortest arc through
        // orientation space rather than along three independent number lines.
        let remaining = Self.angle(current, target)
        var fraction = smoothing
        var clamped = false
        if remaining * smoothing > limit {
            fraction = limit / remaining
            clamped = true
        }
        if remaining > 1e-9 {
            current = simd_normalize(simd_slerp(current, target, fraction))
        }

        // Against the previous input, not against our own output.
        let rate = previous.map { Self.angle($0, target) / dt } ?? 0
        previous = target

        let e = Self.euler(current)
        return HeadStep(head: HeadOrientation(orientation: Self.listener(current),
                                              yaw: e.yaw, pitch: e.pitch, roll: e.roll),
                        rate: rate, clamped: clamped)
    }

    /// Euler-angle convenience, so `Tools/spatial` can drive a synthetic head without
    /// a `CMAttitude` it has no way to build.
    public mutating func step(yaw: Double, pitch: Double, roll: Double,
                              dt: Double) -> HeadStep {
        step(rotation: Self.rotation(yaw: yaw, pitch: pitch, roll: roll), dt: dt)
    }

    /// Where the smoother has got to, in CoreMotion's angles. Readout and tests.
    public var yaw: Double { Self.euler(current).yaw }
    public var pitch: Double { Self.euler(current).pitch }
    public var roll: Double { Self.euler(current).roll }
    public var orientation: AVAudio3DVectorOrientation { Self.listener(current) }
}

/// AirPods head orientation, via CoreMotion.
///
/// `CMHeadphoneMotionManager` is `macos(14.0)`, which is Thrum's floor — so this
/// is a native Mac app reading real head tracking rather than relying on the
/// system's own Spatialize Stereo. That comes with two consequences worth
/// knowing: it needs a Motion permission prompt, and it is the only part of
/// Thrum that can be *denied*. Everything degrades to a head-locked field.
@MainActor
public final class HeadTracker: ObservableObject {
    public enum Status: Equatable {
        case unsupported          // no motion-capable headphones on this machine
        case needsPermission
        case denied
        case idle                 // available, not started
        case tracking

        public var blurb: String {
            switch self {
            case .unsupported:     return "No motion-capable headphones. AirPods Pro or AirPods Max report head orientation; most others don't."
            case .needsPermission: return "Needs permission to read head orientation."
            case .denied:          return "Motion access was denied — the field stays head-locked. Enable Thrum under Privacy & Security → Motion & Fitness."
            case .idle:            return "Ready."
            case .tracking:        return "Tracking. Turn your head and the drone stays where it is."
            }
        }
    }

    @Published public private(set) var status: Status = .idle
    /// Recentred head angles in degrees, for the readout.
    @Published public private(set) var yaw: Double = 0
    @Published public private(set) var pitch: Double = 0
    @Published public private(set) var roll: Double = 0

    /// Full-rate orientation sink — the host points this at the environment
    /// node. Kept separate from the published values, which are throttled,
    /// because SwiftUI does not need twenty-five redraws a second to show a
    /// number that is only there for reassurance.
    ///
    /// Carries forward/up vectors rather than three angles. The host used to negate
    /// the angles itself, on both platforms; that reconciliation now lives once, in
    /// `HeadSmoother.toListener`, where it can be tested.
    public var onOrientation: ((HeadOrientation) -> Void)?

    private let manager = CMHeadphoneMotionManager()
    /// Where "forward" is. Held as a `CMAttitude` rather than three angles
    /// because recentring is a rotation composition, and rotations do not
    /// compose by subtracting Euler angles — doing that is only right for tiny
    /// deviations and goes visibly wrong further out (a head barely tilted can
    /// report ninety degrees of roll). `multiply(byInverseOf:)` does it properly.
    private var reference: CMAttitude?

    /// How much of the referenced orientation is drift rather than head, and the
    /// vertical it is measured against.
    ///
    /// The 08-14 flight log is what these are for. Every one of six listener marks sat
    /// at an extreme *referenced* gaze — median 49–65°, |gaze| over 45° for 80.6% of
    /// the fifteen seconds before each press against 33.3% for the rest of the walk —
    /// while **raw** gaze stayed inside an ordinary neck's range the whole time
    /// (median +27° against a +25° baseline). Referenced minus raw drifted from about
    /// 0° to +40° over five minutes, and output level fell monotonically with the
    /// referenced angle (median −14.9 → −18.4 dB, p10 −18.1 → −23.0) while showing no
    /// relationship at all to the raw one. So the head was not where the field thought
    /// it was, and it was the reference that had moved — which is the test
    /// `rawSpread`'s doc comment was written to make, arriving at the answer it names.
    ///
    /// `recenter()` is the cure it names too, but calling it on a timer would be the
    /// wrong cure: it snaps, deliberately — it pushes `.identity` out and nils
    /// `lastSample` so the slew limit cannot smooth what follows, because a listener
    /// who presses a button is expecting exactly that. On a timer the same snap is
    /// unannounced, and `maxDegreesPerSecond`'s own doc comment already lists "a
    /// reference re-seated mid-movement" among the discontinuities it exists to catch.
    /// Scheduling one every thirty seconds would manufacture the artefact this is
    /// meant to remove.
    ///
    /// So the reference is not re-seated at all — it *leaks*. Each sample this
    /// correction slerps a little way toward the current orientation, which drains
    /// drift continuously and never produces an event to hear. The cost is that a leak
    /// cannot tell drift from intent: hold a deliberate turn and the field slowly
    /// decides that is forward. That is the trade, and it is worth taking at these
    /// numbers — the residual against a constant drift is just rate × τ, so the
    /// measured 0.13°/s leaves ~4° on elevation and ~16° on yaw, against the 40° that
    /// cost 5 dB at p10.
    ///
    /// Two time constants because the two axes are not symmetrical in use. Nobody
    /// holds an extreme *elevation* glance, so elevation can be drained briskly; people
    /// hold *yaw* glances constantly — watching something to the side while walking —
    /// so yaw is drained four times slower, where the leak is least likely to be wrong
    /// about what it is looking at.
    private var leak = HeadSmoother.identity
    /// World up in the reference frame, taken from gravity at the moment the reference
    /// is captured.
    ///
    /// Not simply `(0, 0, 1)`, and that is load-bearing. The reference is a *head*
    /// attitude, captured on the first sample after `start()` — i.e. while the listener
    /// is looking down at the phone to press it, which is what tilts the whole session
    /// by 50–60° in the first place. Its z is therefore 50–60° off the true vertical,
    /// and splitting yaw from elevation about it would mix each into the other and
    /// apply both time constants to the wrong thing. `CMDeviceMotion.gravity` is in the
    /// device frame, so at the instant of capture it *is* the reference frame's own
    /// reading of which way is down — the one moment the two frames coincide.
    private var upInReference: simd_double3?
    /// Elevation drains with a ~30 s time constant, yaw with ~120 s — see `leak`.
    private static let elevationLeak = 30.0
    private static let yawLeak = 120.0

    private var lastPublish = Date.distantPast
    /// Smoothed angles. Handing CoreMotion's steps straight to the HRTF zippers —
    /// you hear the field clicking round rather than turning. A ~120 ms one-pole is
    /// enough to make it continuous without feeling like the room lags your head.
    ///
    /// The rate is *measured*, not assumed: AirPods Pro 2 deliver 50 Hz, which the
    /// flight recorder reports as `motion 1500/30s`. The docs' "about twenty-five
    /// times a second" is where the old smoothing constant came from, and it was
    /// wrong on this hardware by a factor of two — see `HeadSmoother.timeConstant`.
    private var smoothed: HeadOrientation = .identity
    private var smoother = HeadSmoother()
    private var lastSample: TimeInterval?

    /// Diagnostics, read by the host's flight recorder and reset by the reading.
    ///
    /// Two numbers, because they answer different questions. `peakRate` says how
    /// fast the *input* claimed the head was moving, which is what tells you whether
    /// a listener's "it warbled when I tilted my head" is a physically plausible
    /// stream of samples or a stream with steps in it. `clampedFrames` says how often
    /// the limit above had to intervene, which is the same question asked of the
    /// output: zero means the input was clean and the artefact is somewhere else
    /// entirely.
    /// One number, not three, and that is the point of the 1.4.1 fix: the per-axis
    /// rates it used to report were a property of the Euler chart rather than of the
    /// head, and on the hike that produced this instrumentation they read 8352°/s
    /// while the head was moving normally. This is the geodesic rate, so a reading
    /// above a few hundred now means what it always claimed to: the stream itself has
    /// a step in it.
    public private(set) var peakRate: Double = 0
    public private(set) var clampedFrames = 0

    /// How far the gaze has left the reference horizon, and whether the sample stream
    /// went quiet — the two numbers the 08-13 report needs and the log did not have.
    ///
    /// The report is *an angle*: "I can most reliably reproduce this by looking all
    /// the way down towards my feet." Nothing in the log was a function of where the
    /// head was pointing, so a session with the symptom in it and a session without
    /// were indistinguishable — the one correlation the listener handed us was the one
    /// thing that could not be checked.
    ///
    /// `stalls` is the other half, and it is the hypothesis this instrumentation
    /// exists to test. Three offline harnesses have now cleared the render path
    /// (`Tools/warble`, `Tools/pole`, and the vector round-trip through the node), so
    /// what is left is the sample stream itself — and a *stall* in it is invisible in
    /// everything logged so far. `motion 1500/30s` is an aggregate: half a second of
    /// silence from the AirPods costs 25 samples out of 1500 and reads as 1475, which
    /// is indistinguishable from noise. But it is not inaudible. The field freezes for
    /// the length of the stall, then the smoother slews to catch up at up to 400°/s —
    /// which is precisely the half-second warble the slew limit was found producing
    /// once already, from a different cause.
    ///
    /// And it fits the gesture in a way no amount of mathematics does: the motion
    /// stream is a Bluetooth stream, separate from the audio one, between AirPods and
    /// a phone in a trouser pocket. Looking all the way down puts a chin, a chest and
    /// a torso across that path. This does not prove that is the cause; it makes the
    /// next walk able to say so, by recording the largest gap between samples and the
    /// tilt the head was at when it happened.
    public private(set) var peakTilt: Double = 0
    public private(set) var stalls = 0
    public private(set) var longestStall: Double = 0
    public private(set) var tiltAtStall: Double = 0

    /// Anything longer than this between samples is a stall rather than jitter.
    /// AirPods Pro 2 deliver 50 Hz — 20 ms — so this is twelve missed samples, well
    /// clear of ordinary scheduling slop and short enough to catch a freeze the ear
    /// would notice.
    public static let stallThreshold = 0.25

    /// Where the gaze spent the window, not merely how far it got.
    ///
    /// `peakTilt` alone produced the 08-13 anomaly and could not explain it: the most
    /// extreme value in each thirty-second window, and across a twelve-minute walk
    /// those extremes spanned about 179° — more elevation than a neck has. But one
    /// extreme per window cannot say whether the head briefly reached that angle or
    /// sat there, and those are different faults. A histogram answers it for the cost
    /// of an array increment per sample, with no allocation on the motion callback.
    ///
    /// Five-degree buckets over the whole sphere of possible gaze. Coarse on purpose:
    /// this is being read by eye out of a log line.
    public struct TiltHistogram {
        static let buckets = 36
        static let width = 5.0
        private var counts = [Int](repeating: 0, count: buckets)
        private(set) var lowest = 0.0
        private(set) var highest = 0.0
        private var total = 0

        mutating func add(_ degrees: Double) {
            if total == 0 { lowest = degrees; highest = degrees }
            lowest = min(lowest, degrees)
            highest = max(highest, degrees)
            let i = min(Self.buckets - 1, max(0, Int((degrees + 90) / Self.width)))
            counts[i] += 1
            total += 1
        }

        /// Bucket centre at the halfway point. Approximate by construction and that is
        /// fine — the question is "was the head mostly level or mostly craned", which
        /// five degrees answers.
        var median: Double {
            guard total > 0 else { return 0 }
            var seen = 0
            for (i, c) in counts.enumerated() {
                seen += c
                if seen >= total / 2 { return -90 + (Double(i) + 0.5) * Self.width }
            }
            return 0
        }

        var isEmpty: Bool { total == 0 }
        mutating func reset() {
            counts = [Int](repeating: 0, count: Self.buckets)
            lowest = 0; highest = 0; total = 0
        }
    }

    /// The gaze as the *field* sees it — after the session reference is divided out.
    /// This is the number that spanned 179°.
    public private(set) var tiltSpread = TiltHistogram()
    /// The gaze as the *sensor* reports it, before any reference is applied.
    ///
    /// This is the discriminator, and it is the whole point of the pair. CoreMotion's
    /// attitude is gravity-referenced, so raw gaze elevation is an absolute statement
    /// about where the head is pointing relative to the horizon, and a neck bounds it
    /// to roughly ±70°. The referenced figure is that same head minus a reference
    /// captured once, at `start()`, while the listener was looking down at the phone
    /// to press play.
    ///
    /// So: if raw stays inside a neck's range while referenced spans 179°, the
    /// reference is what moved and `recenter()` is the cure. If raw spans it too, the
    /// sensor is reporting more pitch than the head has and no amount of re-referencing
    /// will help. One log line now separates two explanations that have been
    /// indistinguishable all week.
    public private(set) var rawSpread = TiltHistogram()
    /// The most recent raw gaze elevation, for instrumentation that samples rather
    /// than aggregates — see `MarkBuffer`.
    public private(set) var rawTilt: Double = 0

    public struct Diagnostics {
        public var peak: Double
        public var clamped: Int
        public var peakTilt: Double
        public var stalls: Int
        public var longestStall: Double
        public var tiltAtStall: Double
        public var tilt: TiltHistogram
        public var raw: TiltHistogram
    }

    public func drainDiagnostics() -> Diagnostics {
        defer {
            peakRate = 0; clampedFrames = 0
            peakTilt = 0; stalls = 0; longestStall = 0; tiltAtStall = 0
            tiltSpread.reset(); rawSpread.reset()
        }
        return Diagnostics(peak: peakRate, clamped: clampedFrames, peakTilt: peakTilt,
                           stalls: stalls, longestStall: longestStall,
                           tiltAtStall: tiltAtStall, tilt: tiltSpread, raw: rawSpread)
    }

    /// Gaze elevation above the reference horizon, in degrees.
    ///
    /// Read off the forward vector rather than the Euler readout, which is degenerate
    /// at exactly the angles this is here to measure. `asin(forward.y)` is
    /// well-conditioned everywhere on the sphere — ±90° is an honest value for it,
    /// and it is yaw and roll that stop being separable there, neither of which this
    /// needs.
    private static func tilt(_ head: HeadOrientation) -> Double {
        asin(max(-1, min(1, Double(head.orientation.forward.y)))) * 180 / .pi
    }

    public init() {
        refreshStatus()
    }

    public func refreshStatus() {
        guard manager.isDeviceMotionAvailable else { status = .unsupported; return }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted: status = .denied
        case .notDetermined:       status = .needsPermission
        default:                   status = manager.isDeviceMotionActive ? .tracking : .idle
        }
    }

    public func start() {
        guard manager.isDeviceMotionAvailable else { status = .unsupported; return }
        guard !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil {
                    self.status = CMHeadphoneMotionManager.authorizationStatus() == .denied
                        ? .denied : .idle
                    return
                }
                guard let motion else { return }
                self.ingest(motion.attitude,
                            gravity: simd_double3(motion.gravity.x, motion.gravity.y,
                                                  motion.gravity.z),
                            at: motion.timestamp)
            }
        }
        status = .tracking
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
        upInReference = nil
        leak = HeadSmoother.identity
        smoothed = .identity
        smoother = HeadSmoother()
        // Or the next sample's dt is however long the AirPods were out of the ear,
        // which would let the slew limit through in one enormous step — the exact
        // thing it is there to catch.
        lastSample = nil
        yaw = 0; pitch = 0; roll = 0
        // Deliberately *not* pushing the identity orientation out.
        //
        // That snapped the listener back to dead ahead the instant tracking stopped,
        // which is a hard rotation of the whole field — every source jumping at once
        // — and tracking stops for reasons that have nothing to do with the listener
        // wanting that: a route change, a pause, a moment of Bluetooth. Leaving the
        // orientation where it was means a head-locked field simply stays where it
        // is, which is what "stopped following your head" should sound like. The
        // host sets a fresh orientation as soon as motion resumes.
        refreshStatus()
    }

    /// Take the current head position as "facing forward". AirPods yaw drifts,
    /// so this is not a nicety — it is how the field gets put back in front of
    /// you, and it wants to be one obvious button.
    public func recenter() {
        reference = nil
        // Both re-derived from the next sample, alongside the reference itself. The
        // leak drains drift; it is not a second opinion about where forward is, and
        // carrying it across an explicit recentre would have it argue with the button.
        upInReference = nil
        leak = HeadSmoother.identity
        smoothed = .identity
        smoother = HeadSmoother()
        // Or the next sample's dt is however long the AirPods were out of the ear,
        // which would let the slew limit through in one enormous step — the exact
        // thing it is there to catch.
        lastSample = nil
        onOrientation?(.identity)
    }

    private func ingest(_ attitude: CMAttitude, gravity: simd_double3,
                        at timestamp: TimeInterval) {
        // Copy, or the first frame's reference would be mutated by the very
        // call that uses it and every angle after it would be nonsense.
        // Before the reference is divided out — `multiply(byInverseOf:)` mutates the
        // attitude in place, so this is the only moment the sensor's own, gravity-
        // referenced orientation is still available.
        let rawQuat = attitude.quaternion

        if reference == nil {
            reference = attitude.copy() as? CMAttitude
            // The one instant the device frame and the reference frame are the same,
            // so the only instant gravity can be read straight into the latter.
            let g = simd_length(gravity) > 0.1 ? -simd_normalize(gravity) : simd_double3(0, 0, 1)
            upInReference = g
            leak = HeadSmoother.identity
        }
        guard let ref = reference else { return }
        attitude.multiply(byInverseOf: ref)

        let dt = lastSample.map { max(timestamp - $0, 0.001) } ?? 0.04
        // Before the smoother, and against the *previous* tilt: the interesting
        // number is where the head was when the stream went quiet, not where it had
        // got to by the time it came back.
        if lastSample != nil, dt > Self.stallThreshold {
            stalls += 1
            if dt > longestStall {
                longestStall = dt
                tiltAtStall = Self.tilt(smoothed)
            }
        }
        lastSample = timestamp

        // `quaternion`, not `yaw`/`pitch`/`roll`. Reading the Euler angles here is
        // what put a 168° step into a stream whose underlying rotation never moved
        // faster than a walk — see `HeadSmoother`. The quaternion has no chart and so
        // no singularity to fall into.
        let q = attitude.quaternion
        let rel = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)

        // Drain the drift, then hand the smoother what is left — see `leak`.
        //
        // Composed on the *left* throughout, which is what makes the vertical mean
        // anything: left multiplication is a rotation in the reference frame, where
        // `upInReference` lives, and right multiplication would be one in the head's
        // own, where the split would follow the head around. The correction the field
        // sees and the error the leak chases are the same quantity — `leak⁻¹ · rel` —
        // so when the leak has caught up the field is dead ahead, by construction.
        let corrected = leak.conjugate * rel
        if let up = upInReference {
            leak = HeadSmoother.leaked(leak, toward: rel, up: up, dt: dt,
                                       elevation: Self.elevationLeak, yaw: Self.yawLeak)
        }

        let out = smoother.step(rotation: corrected, dt: dt)
        smoothed = out.head
        peakRate = max(peakRate, out.rate)
        if out.clamped { clampedFrames += 1 }
        let tilt = Self.tilt(smoothed)
        if abs(tilt) > abs(peakTilt) { peakTilt = tilt }
        tiltSpread.add(tilt)
        // The same measurement on the unreferenced attitude, through the same frame
        // change, so the two numbers are directly comparable.
        rawTilt = Self.tilt(HeadOrientation(
            orientation: HeadSmoother.listener(simd_quatd(ix: rawQuat.x, iy: rawQuat.y,
                                                          iz: rawQuat.z, r: rawQuat.w)),
            yaw: 0, pitch: 0, roll: 0))
        rawSpread.add(Self.tilt(HeadOrientation(
            orientation: HeadSmoother.listener(simd_quatd(ix: rawQuat.x, iy: rawQuat.y,
                                                  iz: rawQuat.z, r: rawQuat.w)),
            yaw: 0, pitch: 0, roll: 0)))

        // Rotating the *listener* with the head is what leaves the sources
        // standing still in the room.
        onOrientation?(smoothed)

        let now = Date()
        if now.timeIntervalSince(lastPublish) > 0.1 {
            lastPublish = now
            yaw = smoothed.yaw; pitch = smoothed.pitch; roll = smoothed.roll
            if status != .tracking { status = .tracking }
        }
    }
}
