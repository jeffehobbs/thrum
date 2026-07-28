import Foundation
import AVFoundation
import CoreMotion

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
    public var onOrientation: ((Double, Double, Double) -> Void)?

    private let manager = CMHeadphoneMotionManager()
    /// Where "forward" is. Held as a `CMAttitude` rather than three angles
    /// because recentring is a rotation composition, and rotations do not
    /// compose by subtracting Euler angles — doing that is only right for tiny
    /// deviations and goes visibly wrong further out (a head barely tilted can
    /// report ninety degrees of roll). `multiply(byInverseOf:)` does it properly.
    private var reference: CMAttitude?
    private var lastPublish = Date.distantPast
    /// Smoothed angles. CoreMotion delivers about twenty-five times a second,
    /// and handing those steps straight to the HRTF zippers — you hear the field
    /// clicking round rather than turning. A ~90 ms one-pole is enough to make it
    /// continuous without feeling like the room lags your head.
    private var smoothed: (yaw: Double, pitch: Double, roll: Double) = (0, 0, 0)
    private static let smoothing = 0.28

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
                guard let a = motion?.attitude else { return }
                self.ingest(a)
            }
        }
        status = .tracking
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
        yaw = 0; pitch = 0; roll = 0
        onOrientation?(0, 0, 0)
        refreshStatus()
    }

    /// Take the current head position as "facing forward". AirPods yaw drifts,
    /// so this is not a nicety — it is how the field gets put back in front of
    /// you, and it wants to be one obvious button.
    public func recenter() {
        reference = nil
        smoothed = (0, 0, 0)
        onOrientation?(0, 0, 0)
    }

    private func ingest(_ attitude: CMAttitude) {
        // Copy, or the first frame's reference would be mutated by the very
        // call that uses it and every angle after it would be nonsense.
        if reference == nil { reference = attitude.copy() as? CMAttitude }
        guard let ref = reference else { return }
        attitude.multiply(byInverseOf: ref)

        let deg = 180.0 / Double.pi
        // Wrap yaw into ±180° so crossing the back of the head doesn't spin the
        // field the long way round.
        var dy = attitude.yaw * deg
        dy = (dy + 180).truncatingRemainder(dividingBy: 360) - 180
        if dy < -180 { dy += 360 }
        let dp = attitude.pitch * deg
        let dr = attitude.roll * deg

        // Shortest way round on yaw, so the smoother doesn't take the long
        // route when the wrap above flips sign.
        var dyaw = dy - smoothed.yaw
        if dyaw > 180 { dyaw -= 360 } else if dyaw < -180 { dyaw += 360 }
        let k = Self.smoothing
        smoothed.yaw += dyaw * k
        smoothed.pitch += (dp - smoothed.pitch) * k
        smoothed.roll += (dr - smoothed.roll) * k

        // Rotating the *listener* with the head is what leaves the sources
        // standing still in the room.
        onOrientation?(smoothed.yaw, smoothed.pitch, smoothed.roll)

        let now = Date()
        if now.timeIntervalSince(lastPublish) > 0.1 {
            lastPublish = now
            yaw = smoothed.yaw; pitch = smoothed.pitch; roll = smoothed.roll
            if status != .tracking { status = .tracking }
        }
    }
}
