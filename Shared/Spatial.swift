import Foundation
import AVFoundation
#if canImport(CoreMotion)
import CoreMotion
#endif
import simd
import os

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

// MARK: - The head-tracking transport
//
// From a CoreMotion sample to sixteen HRTFs being re-pointed, in five pieces, each
// one a value type with no CoreMotion and no threads in it:
//
//   HeadMath       the rotation arithmetic — frame change, quaternion log, twist
//   HeadReference  the leaky heading: the one thing the transport keeps a reference to
//   HeadSmoother   the geodesic one-pole and the slew limit
//   HeadTransport  the pipeline: samples in on the sensor's clock, orientations out
//                  on the audio's
//   HeadTracker    the only object with CoreMotion, a lock and a thread in it
//
// The split that matters is the one inside `HeadTransport`, and it is the point of
// this rewrite. Head tracking used to run entirely on the sensor's schedule: every
// CoreMotion callback smoothed, limited and *wrote to the environment node*, with a
// dead band and a 45 ms rate cap in the host deciding which of those writes went
// through. Three clocks were involved — the AirPods at 50 Hz, the rate cap at 22 Hz,
// and the render cycle reading the result at whatever the IO buffer made it — and
// none of them was locked to the others. The node only ever *applies* an orientation
// at the start of a render cycle, so what the ear got was the head's path sampled
// by the beat frequency between three unrelated timers: sometimes two writes fell in
// one cycle and one was discarded, sometimes none fell and the field held for a
// cycle then moved twice as far. Every smoothing constant in the chain was tuned
// against that jitter without anyone knowing it was there.
//
// Now the sensor only *deposits* a target, and the field is advanced toward it by
// the render clock: `HeadTracker` is ticked once per render cycle by the host's
// pump, and each tick moves the smoother by the true elapsed time and hands the
// node exactly one orientation, which the very next cycle applies. The sensor may
// jitter, batch, or stall — the field's motion is a function of the audio clock
// alone, so it is as even as the audio is.
//
// `Tools/handover` measured what this buys against the node itself, and it decided
// two host-side settings that go with it — see `FlowHost.buildGraph` and
// `FlowHost.preferredBufferDuration`.

/// One head orientation, in the two forms the rest of the app needs it.
///
/// `orientation` is what the environment node is driven with. The three angles are
/// for the readout and for tests, derived *from* the rotation rather than being
/// the thing carried around. They still go degenerate at pitch = ±90°, which is
/// harmless: nothing downstream reads them, and a number on a settings sheet being
/// briefly ill-conditioned is not sixteen HRTFs being re-pointed.
public struct HeadOrientation: Sendable {
    public var orientation: AVAudio3DVectorOrientation
    /// CoreMotion-convention angles, in degrees. Display only.
    public var yaw: Double, pitch: Double, roll: Double

    public static let identity = HeadOrientation(
        orientation: AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1),
            up: AVAudio3DVector(x: 0, y: 1, z: 0)),
        yaw: 0, pitch: 0, roll: 0)

    /// Gaze elevation, in degrees, off the forward vector rather than the Euler
    /// readout — `asin(forward.y)` is well-conditioned everywhere on the sphere.
    public var gaze: Double {
        asin(max(-1, min(1, Double(orientation.forward.y)))) * 180 / .pi
    }

    /// The shorter rotation between two orientations, in degrees, measured on the
    /// vectors the node is driven with. Chord length is the angle to well within
    /// rounding at the sizes this is used for, and needs no trig; taking the larger
    /// of the two axes means a pure roll — which leaves `forward` alone — counts.
    public func separation(from other: HeadOrientation) -> Double {
        func chord(_ a: AVAudio3DVector, _ b: AVAudio3DVector) -> Double {
            let dx = Double(a.x - b.x), dy = Double(a.y - b.y), dz = Double(a.z - b.z)
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        return max(chord(orientation.forward, other.orientation.forward),
                   chord(orientation.up, other.orientation.up)) * 180 / .pi
    }
}

/// The rotation arithmetic, with nothing stateful in it.
///
/// Everything here is on quaternions, and that is a fix rather than a style. The
/// transport used to smooth and rate-limit `CMAttitude`'s `yaw`, `pitch` and `roll`
/// as three independent signals, which they are not: CMAttitude reports Tait-Bryan
/// angles in Z-X-Y order, so **pitch is the middle axis**, and as pitch approaches
/// ±90° yaw and roll stop being separable. ThrumFlow's flight recorder caught the
/// consequence on a hike (2026-08-12): yaw and roll taking equal steps of up to 168°
/// in one 20 ms sample, agreeing to 0.02%, while the underlying rotation moved at a
/// walk. The slew limit faithfully paid the phantom step out at 400°/s, which is why
/// it was heard as a half-second warble rather than a click. A quaternion has no
/// chart to fall off; the only Euler angles formed anywhere are the readout's.
public enum HeadMath {
    public static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    /// The change of frame from CoreMotion's axes to the environment node's, as a
    /// rotation to conjugate by.
    ///
    /// Both halves were *measured*, not read out of documentation, because deriving
    /// this by hand got it backwards once already:
    ///
    /// - `Tools/axis` established the node's conventions by asking which ear a source
    ///   lands in: positions are −z ahead, +x right, +y up, and positive listener
    ///   yaw/roll turn the listener clockwise where positive CoreMotion attitude is
    ///   counterclockwise. Hence the long-standing `(-yaw, -pitch, -roll)`.
    /// - Reading `listenerVectorOrientation` back after *setting*
    ///   `listenerAngularOrientation` makes the node state its own angular-to-vector
    ///   mapping: `R = Ry(−yaw)·Rx(pitch)·Rz(−roll)`.
    ///
    /// Composing those says the shipped negation is exactly a 180° rotation about
    /// (0, 1, 1)/√2 — it sends CoreMotion's (right, forward, up) onto the node's
    /// (−x, z, y). That it is a *pure frame change* was checked rather than assumed:
    /// conjugating by this and taking the node's own vectors agrees to 0.000000 across
    /// 400 random rotations against the angular path the app shipped, so the rewrite
    /// cannot have moved the field. The same check identified CMAttitude's Euler order
    /// as Z-X-Y — the only one of six that matched.
    static let toListener = simd_quatd(angle: .pi,
                                       axis: simd_normalize(simd_double3(0, 1, 1)))

    /// Into ±180°. For the readout and for tests; the transport has no seam to wrap
    /// at, because a geodesic has none.
    public static func wrap(_ d: Double) -> Double {
        var v = (d + 180).truncatingRemainder(dividingBy: 360) - 180
        if v < -180 { v += 360 }
        return v
    }

    /// Angle of the shorter rotation between two orientations, in degrees.
    public static func angle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
        // |dot| rather than dot: q and −q are the same rotation, and taking the
        // absolute value is what picks the short arc.
        let d = min(1.0, abs(simd_dot(a, b)))
        return 2 * acos(d) * 180 / .pi
    }

    /// A rotation as an axis scaled by its angle in radians — the quaternion log.
    ///
    /// The heading leak has to treat one component of a rotation differently from
    /// the rest, and a quaternion offers nowhere to make that cut. A rotation vector
    /// does: the yaw part is a projection onto the vertical and the elevation part is
    /// what is left. Splitting Euler angles instead would reintroduce the exact chart
    /// that put a 168° step in the log.
    static func rotationVector(_ q: simd_quatd) -> simd_double3 {
        // q and −q are the same rotation but their logs point opposite ways; the
        // positive-real form is what keeps the leak pulling the short way round.
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

    /// The twist of a rotation about an axis — the pure rotation about `axis`
    /// contained in `q`, with the swing (everything about any perpendicular axis)
    /// divided off.
    ///
    /// This is how the heading is seeded: the head's yaw about the world's vertical,
    /// with its pitch and roll never entering. Both decompositions share it —
    /// `q = twist · swing` and `q = swing′ · twist` have the *same* twist — so no order
    /// convention is needed here.
    ///
    /// Degenerate when the rotation carries the axis to its opposite (a 180° swing),
    /// where "how much of this is yaw" has no answer; identity is returned and a
    /// caller seeding from it starts dead ahead, which is the only honest choice.
    public static func twist(_ q: simd_quatd, about axis: simd_double3) -> simd_quatd {
        let proj = simd_dot(q.imag, axis) * axis
        let t = simd_double4(proj.x, proj.y, proj.z, q.real)
        let len = simd_length(t)
        guard len > 1e-9 else { return identity }
        return simd_quatd(vector: t / len)
    }

    /// CoreMotion's Euler angles, composed into the rotation they describe.
    ///
    /// Z-X-Y, per the measurement above: `Rz(yaw)·Rx(pitch)·Ry(roll)`. Composing and
    /// then decomposing is lossless away from the singularity and *cancels* the
    /// degenerate yaw/roll split at it — which is why feeding this path the very
    /// angle pairs that used to produce a 168° lurch produces none.
    public static func rotation(yaw: Double, pitch: Double, roll: Double) -> simd_quatd {
        let d = Double.pi / 180
        return simd_quatd(angle: yaw * d, axis: simd_double3(0, 0, 1))
             * simd_quatd(angle: pitch * d, axis: simd_double3(1, 0, 0))
             * simd_quatd(angle: roll * d, axis: simd_double3(0, 1, 0))
    }

    /// And back out again, for the readout only.
    public static func euler(_ q: simd_quatd) -> (yaw: Double, pitch: Double, roll: Double) {
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
    public static func listener(_ q: simd_quatd) -> AVAudio3DVectorOrientation {
        let l = toListener * q * toListener.conjugate
        let f = l.act(simd_double3(0, 0, -1))
        let u = l.act(simd_double3(0, 1, 0))
        return AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: Float(f.x), y: Float(f.y), z: Float(f.z)),
            up: AVAudio3DVector(x: Float(u.x), y: Float(u.y), z: Float(u.z)))
    }

    /// Both forms at once.
    public static func orientation(_ q: simd_quatd) -> HeadOrientation {
        let e = euler(q)
        return HeadOrientation(orientation: listener(q), yaw: e.yaw, pitch: e.pitch, roll: e.roll)
    }

    /// Gaze elevation of a rotation, in degrees, through the same frame change the
    /// node sees — so a raw attitude and a referenced one are directly comparable.
    public static func tilt(_ q: simd_quatd) -> Double {
        orientation(q).gaze
    }
}

/// The leaky *heading* — a pure twist about the world's vertical, and the only
/// reference the transport keeps.
///
/// **Elevation and roll are never referenced at all.** The tracker used to divide a
/// full attitude out of every sample: a reference captured on the first sample after
/// `start()`, plus a leak chasing the whole referenced orientation. Mark #1 of the
/// 08-21 walk caught what that costs: the orientation handed to the environment node
/// sat at +69…+76° elevation for two seconds while the raw head sat at +22…27°,
/// moved *opposite* to the head, then snapped 67° in half a second — with overruns,
/// gaps, stalls and clamped all zero. The mechanism was structural: elevation was
/// derived from two orientation-referenced quantities, so any yaw-side error (the
/// sensor re-seating its own drifting yaw frame, the leak lagging a held turn, an
/// oblique start) conjugated into *elevation*, the axis the ear is most sensitive to.
///
/// So the swing comes from gravity and only the twist is referenced:
///
/// - **Pitch and roll** are taken from the attitude's own gravity-referenced swing,
///   per sample, absolutely. No reference biases them, no leak drains them, and no
///   path exists by which yaw error can become elevation. A neck bounds the result to
///   roughly ±70°, so the ±90° pole where azimuths whip is unreachable.
/// - **Yaw** has no absolute observation (gravity cannot see it, and AirPods yaw
///   genuinely drifts), so it is measured against this heading: seeded from the head's
///   twist on the first sample, drained toward the current twist with a ~120 s time
///   constant. The cost: hold a deliberate turn and the field slowly decides that is
///   forward. `Tools/heading` and `Tools/drift` measure both halves.
public struct HeadReference {
    /// Yaw drains with this time constant, in seconds.
    public static let yawTimeConstant = 120.0

    private var heading = HeadMath.identity
    private var seeded = false

    public init() {}

    /// One step of the leak: the correction moved a little way toward the current
    /// orientation, yaw and elevation at their own rates.
    ///
    /// Composed on the *left* throughout, which is what makes `up` mean anything: left
    /// multiplication is a rotation in the reference frame, where `up` lives; right
    /// multiplication would be one in the head's own frame, where the split would
    /// follow the head around and each time constant would land on the wrong axis.
    /// The transport passes `elevation: .infinity` — the swing is absolute, so there is
    /// no elevation drift to drain and the leak must never acquire a component off the
    /// vertical. The parameter exists so `Tools/heading` can reconstruct the old
    /// composition and show it contained the bug.
    public static func leaked(_ leak: simd_quatd, toward rel: simd_quatd,
                              up: simd_double3, dt: Double,
                              elevation: Double, yaw: Double) -> simd_quatd {
        let v = HeadMath.rotationVector(rel * leak.conjugate)
        let yawPart = simd_dot(v, up) * up
        let scaled = yawPart * (1 - exp(-dt / yaw))
                   + (v - yawPart) * (1 - exp(-dt / elevation))
        return HeadMath.rotation(vector: scaled) * leak
    }

    /// The attitude with the heading divided out — the head's true gravity swing plus
    /// its yaw relative to the leaky heading — and the heading advanced.
    ///
    /// Divided out on the left: a rotation in the world frame, where the vertical
    /// lives. A nod is a pure pitch of the result at any heading, and nothing on the
    /// yaw axis can reach its elevation, because `heading` is a twist about the very
    /// axis elevation is measured from.
    public mutating func referenced(_ attitude: simd_quatd, up: simd_double3,
                                    dt: Double) -> simd_quatd {
        if !seeded {
            heading = HeadMath.twist(attitude, about: up)
            seeded = true
        }
        let corrected = heading.conjugate * attitude
        heading = Self.leaked(heading, toward: attitude, up: up, dt: dt,
                              elevation: .infinity, yaw: Self.yawTimeConstant)
        return corrected
    }

    /// Re-seat from the next sample's twist.
    public mutating func reset() {
        heading = HeadMath.identity
        seeded = false
    }
}

/// The geodesic one-pole and the slew limit — the smoothing that turns a stream of
/// targets into a field that turns rather than clicks, and the limit that stops a
/// bad sample being a rotation.
///
/// Stepped by whoever owns the clock, with the true elapsed time. It has no opinion
/// about where its `dt` comes from, and that is the difference from the version it
/// replaces, which was stepped once per *sensor sample* and had to guess at what a
/// long gap meant (see `HeadTransport` for what happens to a stall now).
public struct HeadSmoother {
    /// The one-pole's time constant, in seconds — enough to make the motion
    /// continuous without the room feeling like it lags the head.
    ///
    /// A *time*, not a per-sample coefficient. This was `smoothing = 0.28` applied
    /// once per sample, documented as "~90 ms at CoreMotion's twenty-five samples a
    /// second" — but AirPods Pro 2 deliver 50 Hz (`motion 1500/30s` in every logged
    /// session), which made the real time constant 61 ms and every head movement
    /// twice as twitchy as designed. 0.12 s reproduces the old coefficient exactly at
    /// the rate it was tuned for: 1 − exp(−0.04/0.12) = 0.283.
    public static let timeConstant = 0.12

    /// The per-sample coefficient for a given interval.
    public static func coefficient(for dt: Double) -> Double {
        1 - exp(-max(dt, 0.0001) / timeConstant)
    }

    /// The fastest the field is allowed to rotate, in degrees per second.
    ///
    /// Not a comfort feature — a limit on how wrong one bad sample can be. A head
    /// turns at 100–200°/s in ordinary use and perhaps 500°/s if something startles
    /// you, so at 400°/s this never touches a real movement. What it does touch is a
    /// *discontinuity*: a reference re-seated mid-movement, or a dropped-and-resumed
    /// batch of Bluetooth samples arriving as one enormous step. Sixteen HRTFs
    /// re-pointed by 50° between one cycle and the next is not a rotation, it is an
    /// event.
    public static let maxDegreesPerSecond = 400.0

    /// Where the field is. Starts at identity rather than snapping to the first
    /// target, so a fresh reference glides in from dead ahead.
    public private(set) var current = HeadMath.identity

    public init() {}

    /// Move a fixed fraction of the remaining rotation toward `target`, along the
    /// shortest arc through orientation space rather than along three independent
    /// number lines. Returns whether the slew limit had to intervene.
    public mutating func step(toward target: simd_quatd, dt: Double) -> Bool {
        let dt = max(dt, 0.0001)
        let limit = Self.maxDegreesPerSecond * dt
        let smoothing = Self.coefficient(for: dt)
        let remaining = HeadMath.angle(current, target)
        var fraction = smoothing
        var clamped = false
        if remaining * smoothing > limit {
            fraction = limit / remaining
            clamped = true
        }
        if remaining > 1e-9 {
            current = simd_normalize(simd_slerp(current, target, fraction))
        }
        return clamped
    }

    public var orientation: HeadOrientation { HeadMath.orientation(current) }
}

/// The pipeline between a motion sensor and an environment node, with no sensor
/// and no node in it: samples come in on one clock, orientations go out on another.
///
/// Single-threaded by construction — `HeadTracker` serialises access, and the
/// offline harnesses (`Tools/spatial`) drive both sides from one loop. The two
/// entry points:
///
/// - `ingest` is the **sensor side**. It runs the heading reference and deposits a
///   target. It never touches the smoother and never produces an orientation.
/// - `advance` is the **clock side**. It moves the smoother toward the current target
///   by the time actually elapsed since the last tick and returns the orientation to
///   hand the node — or nil when nothing worth a write has changed.
///
/// What this does to a stall in the motion stream is the reason for the split. The
/// 08-15 log had 32 stalls of up to 2 s and `clamped 0` on every heartbeat, because
/// the smoother was stepped per *sample* and both its terms scaled with the interval:
/// after a 1.3 s gap the one-pole's fraction was 1.000 and the limiter allowed 520°,
/// so everything the head did during the gap landed on sixteen HRTFs in a single
/// frame and the guard reported nothing because 40° is less than 520°. That took a
/// special case (`maxCatchUpInterval`) to paper over. Here there is nothing to paper:
/// during a stall the target simply stops changing and the field settles on it; when
/// the stream returns the target jumps and the smoother eases toward it at the audio
/// clock's own cadence, with the slew limit policing every tick as it would any
/// other. A late sample is not a long `dt`, because `dt` is not the sensor's to set.
public struct HeadTransport {
    /// Anything longer than this between samples is a stall rather than jitter.
    /// AirPods Pro 2 deliver 50 Hz — 20 ms — so this is twelve missed samples, well
    /// clear of scheduling slop and short enough to catch a freeze the ear would notice.
    public static let stallThreshold = 0.25

    /// The longest interval one tick is allowed to advance the smoother by.
    ///
    /// Ticks stop when the engine pauses and resume when it restarts, and the first
    /// tick back would otherwise carry the whole pause as one step. Two render cycles
    /// at the longest buffer the host asks for; nothing about normal operation comes
    /// near it.
    public static let maxTick = 0.2

    /// Movement below this, in degrees, is not handed to the node.
    ///
    /// Purely a saving of work, and measured to be nothing else: `Tools/handover`
    /// finds the transport's own residual wander around a still head — a few
    /// hundredths of a degree, once the one-pole has settled — costs the rendered
    /// high band 0.001 dB per hop over a listener who never moves at all, on either
    /// HRTF algorithm. So a write for it re-points sixteen HRTFs for nothing the ear
    /// can tell. Measured against the last orientation *written*, not the last tick,
    /// so a slow drift still arrives — in tenth-of-a-degree steps, which at the
    /// distances involved is a smaller step than the node's own filter grid.
    public static let deadBand = 0.1

    private var reference = HeadReference()
    private var smoother = HeadSmoother()
    /// The latest referenced attitude — where the field is being asked to go.
    private var target: simd_quatd?
    private var previousAttitude: simd_quatd?
    private var lastSampleAt: TimeInterval?
    private var lastTickAt: TimeInterval?
    /// What was last handed out, for the dead band and the readout.
    private var written = HeadOrientation.identity
    /// An orientation the host has not been handed yet — set at start and by
    /// `recenter()`, so the very next tick snaps to identity before gliding.
    private var pendingSnap = true

    public init() {}

    // MARK: Sensor side

    /// One motion sample. `attitude` is `CMAttitude.quaternion` — singularity-free —
    /// and `gravity` is `CMDeviceMotion.gravity`, in the device frame.
    public mutating func ingest(attitude: simd_quatd, gravity: simd_double3,
                                at timestamp: TimeInterval) {
        // The world's vertical, as the sensor itself measures it this sample.
        // Gravity arrives in the device frame; carried through the attitude it is the
        // vertical of the frame the attitude lives in — so the twist axis rests on a
        // measurement, not on the reference-frame contract. The fallback is that
        // contract (headphone attitude is z-vertical), for the odd sample where
        // gravity hasn't settled.
        let up = simd_length(gravity) > 0.1
            ? -simd_normalize(attitude.act(gravity))
            : simd_double3(0, 0, 1)

        let dt = lastSampleAt.map { max(timestamp - $0, 0.001) } ?? 0.02
        if lastSampleAt != nil, dt > Self.stallThreshold {
            diagnostics.stalls += 1
            if dt > diagnostics.longestStall {
                diagnostics.longestStall = dt
                // Where the field was when the stream went quiet, not where the head
                // had got to by the time it came back.
                diagnostics.tiltAtStall = written.gaze
            }
        }
        lastSampleAt = timestamp

        // The rate is the *sensor's* claim about the head — the geodesic angle between
        // consecutive samples over their interval. Measuring it against the smoother's
        // output would report tracking lag over the time constant, which makes an
        // ordinary 50°/s nod read as 171°/s. Its job is to say whether a stream is
        // physically possible: a reading above a few hundred means the stream itself
        // has a step in it.
        if let previous = previousAttitude {
            diagnostics.peakRate = max(diagnostics.peakRate, HeadMath.angle(previous, attitude) / dt)
        }
        previousAttitude = attitude
        diagnostics.samples += 1

        target = reference.referenced(attitude, up: up, dt: dt)

        // The same measurement on the unreferenced attitude, through the same frame
        // change, so it is directly comparable to `tilt`. The heading is a twist and
        // twists cannot move tilt, so the two histograms should agree to within
        // smoothing lag; their parting company again on some future walk is the alarm
        // that an error has found a new path onto the elevation axis.
        diagnostics.rawTilt = HeadMath.tilt(attitude)
        diagnostics.raw.add(diagnostics.rawTilt)
    }

    // MARK: Clock side

    /// One tick of the clock that owns the node. Returns the orientation to write,
    /// or nil if the field has not moved enough to be worth one.
    public mutating func advance(to now: TimeInterval) -> HeadOrientation? {
        let dt = lastTickAt.map { min(max(now - $0, 0.0001), Self.maxTick) } ?? 0.02
        lastTickAt = now

        if pendingSnap {
            // A fresh start or a recenter: the field goes to dead ahead *now*, and
            // glides from there to wherever the head is. A listener who pressed the
            // button expects exactly that snap; nothing else in here ever produces one.
            pendingSnap = false
            written = .identity
            diagnostics.writes += 1
            return written
        }
        guard let target else { return nil }

        if smoother.step(toward: target, dt: dt) { diagnostics.clampedTicks += 1 }
        let out = smoother.orientation
        let tilt = out.gaze
        if abs(tilt) > abs(diagnostics.peakTilt) { diagnostics.peakTilt = tilt }
        diagnostics.tilt.add(tilt)

        guard out.separation(from: written) > Self.deadBand else { return nil }
        written = out
        diagnostics.writes += 1
        return out
    }

    /// Where the field is, for the readout.
    public var orientation: HeadOrientation { written }

    /// Take the current heading as "facing forward". Only the heading is re-seated —
    /// elevation comes from gravity and was never wrong, so the button has nothing
    /// to say about it. The field snaps to dead ahead and settles at the true tilt.
    public mutating func recenter() {
        reference.reset()
        smoother = HeadSmoother()
        target = nil
        previousAttitude = nil
        lastSampleAt = nil
        lastTickAt = nil
        pendingSnap = true
    }

    /// Forget everything, for a stop. Unlike `recenter`, this does *not* queue a
    /// snap to identity: tracking stops for reasons that have nothing to do with the
    /// listener wanting the field moved — a route change, a pause, a moment of
    /// Bluetooth — and a head-locked field should simply stay where it was.
    public mutating func reset() {
        recenter()
        pendingSnap = false
        written = .identity
    }

    // MARK: Diagnostics

    /// Where the gaze spent the window, not merely how far it got.
    ///
    /// `peakTilt` alone produced the 08-13 anomaly and could not explain it: one
    /// extreme per thirty-second window cannot say whether the head briefly reached
    /// that angle or sat there, and those are different faults. Five-degree buckets
    /// over the whole sphere; coarse on purpose, it is read by eye out of a log line.
    public struct TiltHistogram {
        static let buckets = 36
        static let width = 5.0
        private var counts = [Int](repeating: 0, count: buckets)
        public private(set) var lowest = 0.0
        public private(set) var highest = 0.0
        private var total = 0

        public init() {}

        public mutating func add(_ degrees: Double) {
            if total == 0 { lowest = degrees; highest = degrees }
            lowest = min(lowest, degrees)
            highest = max(highest, degrees)
            let i = min(Self.buckets - 1, max(0, Int((degrees + 90) / Self.width)))
            counts[i] += 1
            total += 1
        }

        /// Bucket centre at the halfway point. Approximate by construction, and fine:
        /// the question is "was the head mostly level or mostly craned".
        public var median: Double {
            guard total > 0 else { return 0 }
            var seen = 0
            for (i, c) in counts.enumerated() {
                seen += c
                if seen >= total / 2 { return -90 + (Double(i) + 0.5) * Self.width }
            }
            return 0
        }

        public var isEmpty: Bool { total == 0 }
        public mutating func reset() {
            counts = [Int](repeating: 0, count: Self.buckets)
            lowest = 0; highest = 0; total = 0
        }
    }

    /// What the flight recorder reads every thirty seconds, and why each is here.
    ///
    /// - `samples` and `writes` are the two clocks: how many sensor samples arrived
    ///   and how many orientations went to the node. On a still head the second
    ///   should be a small fraction of the first; on a moving one it should sit at
    ///   the render rate and no higher, whatever the sensor does.
    /// - `peakRate` is how fast the *input* claimed the head moved, `clampedTicks`
    ///   how often the limit had to intervene on the *output*. Zero means the input
    ///   was clean and any artefact is somewhere else entirely.
    /// - `stalls` is the hypothesis the 08-15 walk tested and refuted (stalls are
    ///   real but not a function of where the head is). Still worth a number.
    /// - `tilt` against `raw`: the field's gaze against the sensor's. They agree by
    ///   construction now; their disagreeing again is the alarm.
    public struct Diagnostics {
        public var samples = 0
        public var writes = 0
        public var peakRate = 0.0
        public var clampedTicks = 0
        public var peakTilt = 0.0
        public var stalls = 0
        public var longestStall = 0.0
        public var tiltAtStall = 0.0
        public var tilt = TiltHistogram()
        public var raw = TiltHistogram()
        /// The most recent raw gaze, for instrumentation that samples rather than
        /// aggregates — see `MarkBuffer`. Not reset by a drain.
        public var rawTilt = 0.0
    }

    public private(set) var diagnostics = Diagnostics()

    public mutating func drainDiagnostics() -> Diagnostics {
        defer {
            let keep = diagnostics.rawTilt
            diagnostics = Diagnostics()
            diagnostics.rawTilt = keep
        }
        return diagnostics
    }
}

/// AirPods head orientation, via CoreMotion, paced by the audio clock.
///
/// `CMHeadphoneMotionManager` is `macos(14.0)`, which is Thrum's floor — so this is
/// a native app reading real head tracking rather than relying on the system's own
/// Spatialize Stereo. It needs a Motion permission prompt, and it is the only part
/// of Thrum that can be *denied*. Everything degrades to a head-locked field.
///
/// Three threads meet here, and the structure keeps them apart:
///
/// - **CoreMotion's queue** delivers samples — its own serial queue, not `.main`,
///   because a main thread busy with SwiftUI and a Metal field is exactly the kind
///   of thread that delivers sensor samples late and in batches. Each sample is
///   folded into the transport under a lock and nothing else happens.
/// - **The render thread** calls `tick()` once per cycle, from the host's pump. It
///   signals a semaphore and returns; nothing is computed and no lock is taken.
/// - **The pacer** is a dedicated thread that waits on that semaphore. Each wake it
///   advances the transport by the true elapsed time and hands the result to
///   `onOrientation`, which the host points at the environment node — so the node
///   gets exactly one write per render cycle, landing while the cycle that signalled
///   it is still rendering and applied by the next. If nothing ticks it (spatial off,
///   or a host that never wired it) it free-runs at `fallbackInterval`.
///
/// The `@Published` readout is throttled to 10 Hz on the main queue: SwiftUI does not
/// need fifty redraws a second to show a number that is only there for reassurance.
#if canImport(CoreMotion)
public final class HeadTracker: ObservableObject, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
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

    public typealias Diagnostics = HeadTransport.Diagnostics
    public typealias TiltHistogram = HeadTransport.TiltHistogram

    @Published public private(set) var status: Status = .idle
    /// Recentred head angles in degrees, for the readout. Main queue, 10 Hz.
    @Published public private(set) var yaw: Double = 0
    @Published public private(set) var pitch: Double = 0
    @Published public private(set) var roll: Double = 0

    /// The orientation sink — the host points this at the environment node.
    ///
    /// **Called on the pacer thread**, at most once per render cycle, and only when
    /// the field has moved. Setting `AVAudioEnvironmentNode.listenerVectorOrientation`
    /// from there is fine: it is a node property, not a render-thread call, and it
    /// takes the same engine lock from any non-render thread. Set before `start()`.
    public var onOrientation: ((HeadOrientation) -> Void)?

    /// How often the pacer advances the field when nothing is ticking it.
    public static let fallbackInterval = 0.033

    private let manager = CMHeadphoneMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.jeffhobbs.thrum.head-motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let transport = OSAllocatedUnfairLock(initialState: HeadTransport())
    /// One count per render cycle. Signalled from the render thread, drained by the
    /// pacer. A `DispatchSemaphore` signal with no waiter is an atomic increment and
    /// with one is a single mach trap; either is fine on the audio thread, and it is
    /// what Apple's own audio→worker hand-offs use.
    private let cycle = DispatchSemaphore(value: 0)
    /// Which pacer is current. Bumped by `stop()`; a pacer that finds itself
    /// superseded exits, so a quick stop/start cannot leave two running.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private var lastPublish: TimeInterval = 0

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

    // MARK: Lifecycle

    public func start() {
        guard manager.isDeviceMotionAvailable else { status = .unsupported; return }
        guard !manager.isDeviceMotionActive else { return }
        transport.withLock { $0.recenter() }
        startPacer()
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            if error != nil {
                let denied = CMHeadphoneMotionManager.authorizationStatus() == .denied
                DispatchQueue.main.async { self.status = denied ? .denied : .idle }
                return
            }
            guard let motion else { return }
            let q = motion.attitude.quaternion
            let g = motion.gravity
            // `quaternion`, not `yaw`/`pitch`/`roll` — see `HeadMath`.
            self.transport.withLock {
                $0.ingest(attitude: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w),
                          gravity: simd_double3(g.x, g.y, g.z),
                          at: motion.timestamp)
            }
        }
        status = .tracking
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        stopPacer()
        transport.withLock { $0.reset() }
        yaw = 0; pitch = 0; roll = 0
        // Deliberately *not* pushing the identity orientation out — see
        // `HeadTransport.reset`. The host sets a fresh orientation as soon as motion
        // resumes.
        refreshStatus()
    }

    /// Take the current heading as "facing forward". AirPods yaw drifts, so this is
    /// not a nicety — it is how the field gets put back in front of you, and it
    /// wants to be one obvious button. The snap happens on the next tick.
    public func recenter() {
        transport.withLock { $0.recenter() }
    }

    /// Diagnostics, read by the host's flight recorder and reset by the reading.
    public func drainDiagnostics() -> Diagnostics {
        transport.withLock { $0.drainDiagnostics() }
    }

    /// The most recent raw gaze elevation, for instrumentation that samples rather
    /// than aggregates.
    public var rawTilt: Double {
        transport.withLock { $0.diagnostics.rawTilt }
    }

    // MARK: Pacing

    /// One render cycle has begun. Safe to call from the render thread.
    public func tick() {
        cycle.signal()
    }

    private func startPacer() {
        let mine = generation.withLock { $0 += 1; return $0 }
        let thread = Thread { [self] in self.pace(generation: mine) }
        thread.name = "com.jeffhobbs.thrum.head-pacer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func stopPacer() {
        generation.withLock { $0 += 1 }
        cycle.signal()
    }

    private func pace(generation mine: Int) {
        // Ticks that arrived while nobody was pacing — an hour of spatial rendering
        // with tracking off is 180,000 of them — are not cycles to catch up on.
        while cycle.wait(timeout: .now()) == .success {}
        while generation.withLock({ $0 }) == mine {
            _ = cycle.wait(timeout: .now() + .milliseconds(Int(Self.fallbackInterval * 1000)))
            // A burst is one tick. Seventeen source nodes share one cycle and the pump
            // already collapses them, but nothing here should depend on that.
            while cycle.wait(timeout: .now()) == .success {}
            guard generation.withLock({ $0 }) == mine else { return }

            let now = ProcessInfo.processInfo.systemUptime
            guard let out = transport.withLock({ $0.advance(to: now) }) else { continue }
            // Rotating the *listener* with the head is what leaves the sources
            // standing still in the room.
            onOrientation?(out)

            if now - lastPublish > 0.1 {
                lastPublish = now
                DispatchQueue.main.async { [self] in
                    yaw = out.yaw; pitch = out.pitch; roll = out.roll
                    if status != .tracking, manager.isDeviceMotionActive { status = .tracking }
                }
            }
        }
    }
}
#else
/// The television has no CoreMotion and nothing to track: an Apple TV is a fixed
/// listener in a room, and the field is placed around the speakers rather than
/// around a head. Same surface as the real tracker so `ThrumModel` and the hosts
/// compile unchanged — `status` is permanently `.unsupported`, `start()` is a
/// no-op, and no orientation is ever delivered.
public final class HeadTracker: ObservableObject, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case unsupported, needsPermission, denied, idle, tracking
        public var blurb: String { "No head tracking on this platform." }
    }
    public typealias Diagnostics = HeadTransport.Diagnostics
    public typealias TiltHistogram = HeadTransport.TiltHistogram

    @Published public private(set) var status: Status = .unsupported
    @Published public private(set) var yaw: Double = 0
    @Published public private(set) var pitch: Double = 0
    @Published public private(set) var roll: Double = 0
    public var onOrientation: ((HeadOrientation) -> Void)?
    public static let fallbackInterval = 0.033

    public init() {}
    public func refreshStatus() {}
    public func start() {}
    public func stop() {}
    public func recenter() {}
    public func drainDiagnostics() -> Diagnostics {
        var t = HeadTransport()
        return t.drainDiagnostics()
    }
    public var rawTilt: Double { 0 }
    public func tick() {}
}
#endif
