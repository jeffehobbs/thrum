import Foundation
import os.lock

/// UI/MIDI thread → render thread message for the drone engine.
public struct DroneEvent {
    public enum Kind: Int32 {
        case gate = 0     // value: 1 = swell in, 0 = fade out
        case level        // value: 0…1 target loudness for this tone
        case sitar        // value: 0…1 jawari/phase depth for this tone
        case retune       // value: new frequency in Hz, glided into
        case fadeAll      // value: release scale (1 = normal, small = quick)
        case panic        // immediate silence, FX tails cleared
    }

    public var kind: Int32
    public var pad: Int32
    public var value: Double

    public init(_ kind: Kind, pad: Int = 0, value: Double = 0) {
        self.kind = kind.rawValue
        self.pad = Int32(pad)
        self.value = value
    }
}

/// Fixed-capacity, lock-guarded queue. The render thread drains with a try-lock
/// so it never blocks; the producer holds the lock only long enough to copy a
/// few bytes. Same shape as the one in Nineteen, which has held up live.
public final class EventQueue<T> {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<T>
    private var count = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    public init(capacity: Int = 512) {
        self.capacity = capacity
        storage = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    public func push(_ event: T) {
        os_unfair_lock_lock(lock)
        if count < capacity {
            storage[count] = event
            count += 1
        }
        os_unfair_lock_unlock(lock)
    }

    /// Render-thread side: non-blocking. Events stay queued if the lock is held.
    public func drain(_ body: (T) -> Void) {
        guard os_unfair_lock_trylock(lock) else { return }
        for i in 0..<count { body(storage[i]) }
        count = 0
        os_unfair_lock_unlock(lock)
    }
}

/// RBJ biquad, direct form I. Coefficients are set from the UI thread between
/// blocks; state stays on the render thread.
public struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    public mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    public mutating func lowShelf(_ freq: Double, _ gainDB: Double, _ sr: Double, s: Double = 0.8) {
        let a = pow(10.0, gainDB / 40.0)
        let w = 2.0 * Double.pi * freq / sr
        let cw = cos(w), sw = sin(w)
        let alpha = sw / 2.0 * sqrt((a + 1 / a) * (1 / s - 1) + 2)
        let tsa = 2 * sqrt(a) * alpha
        let b0n = a * ((a + 1) - (a - 1) * cw + tsa)
        let b1n = 2 * a * ((a - 1) - (a + 1) * cw)
        let b2n = a * ((a + 1) - (a - 1) * cw - tsa)
        let a0n = (a + 1) + (a - 1) * cw + tsa
        let a1n = -2 * ((a - 1) + (a + 1) * cw)
        let a2n = (a + 1) + (a - 1) * cw - tsa
        normalize(b0n, b1n, b2n, a0n, a1n, a2n)
    }

    public mutating func highShelf(_ freq: Double, _ gainDB: Double, _ sr: Double, s: Double = 0.8) {
        let a = pow(10.0, gainDB / 40.0)
        let w = 2.0 * Double.pi * freq / sr
        let cw = cos(w), sw = sin(w)
        let alpha = sw / 2.0 * sqrt((a + 1 / a) * (1 / s - 1) + 2)
        let tsa = 2 * sqrt(a) * alpha
        let b0n = a * ((a + 1) + (a - 1) * cw + tsa)
        let b1n = -2 * a * ((a - 1) + (a + 1) * cw)
        let b2n = a * ((a + 1) + (a - 1) * cw - tsa)
        let a0n = (a + 1) - (a - 1) * cw + tsa
        let a1n = 2 * ((a - 1) - (a + 1) * cw)
        let a2n = (a + 1) - (a - 1) * cw - tsa
        normalize(b0n, b1n, b2n, a0n, a1n, a2n)
    }

    public mutating func peaking(_ freq: Double, _ gainDB: Double, _ q: Double, _ sr: Double) {
        let a = pow(10.0, gainDB / 40.0)
        let w = 2.0 * Double.pi * freq / sr
        let cw = cos(w), sw = sin(w)
        let alpha = sw / (2.0 * q)
        normalize(1 + alpha * a, -2 * cw, 1 - alpha * a,
                  1 + alpha / a, -2 * cw, 1 - alpha / a)
    }

    private mutating func normalize(_ b0n: Double, _ b1n: Double, _ b2n: Double,
                                    _ a0n: Double, _ a1n: Double, _ a2n: Double) {
        b0 = Float(b0n / a0n); b1 = Float(b1n / a0n); b2 = Float(b2n / a0n)
        a1 = Float(a1n / a0n); a2 = Float(a2n / a0n)
    }
}
