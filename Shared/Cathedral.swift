import Foundation

/// A feedback-delay-network reverb built for drones rather than for rooms.
///
/// Freeverb-style comb banks top out around three or four seconds before they
/// turn to metal. This is an 8×8 Hadamard FDN with modulated fractional taps
/// and per-line damping, which holds a smooth 30-second tail. It is fed through
/// a pre-delay and four diffusion allpasses per side, and deliberately has *no*
/// early reflection taps — early reflections tell the ear where the walls are,
/// and the point here is that there aren't any.
///
/// All state lives in flat C buffers. Swift `Array` on the render thread means
/// ARC traffic on the render thread, which is how you get dropouts under load.
final class Cathedral {
    private static let lineCount = 8
    private static let diffCount = 4      // per side

    /// Mutually prime-ish line lengths at 44.1 kHz, ~33–96 ms.
    private static let baseLens: [Double] = [1447, 1721, 2063, 2447, 2861, 3299, 3733, 4241]
    /// Slow, mutually irrational modulation rates (seconds per cycle).
    private static let modPeriods: [Double] = [7.3, 8.9, 11.1, 13.7, 5.9, 9.7, 12.3, 6.7]
    private static let modOffsets: [Double] = [0.0, 0.17, 0.41, 0.63, 0.29, 0.83, 0.11, 0.55]
    /// Output tap signs, chosen so L and R decorrelate.
    private static let signL: [Float] = [1, -1, 1, 1, -1, 1, -1, -1]
    private static let signR: [Float] = [1, 1, -1, 1, 1, -1, -1, 1]

    private static let diffLens: [Double] = [113, 271, 421, 617,      // L
                                             127, 293, 439, 631]      // R
    private static let maxSampleRate = 192_000.0
    private static let maxPredelay = 0.12
    /// Room for the largest size setting plus modulation headroom.
    private static let sizeHeadroom = 2.2

    // MARK: - Flat storage

    private let lineBuf: UnsafeMutablePointer<Float>
    private let lineOffset: UnsafeMutablePointer<Int>
    private let lineCap: UnsafeMutablePointer<Int>
    private let lineWrite: UnsafeMutablePointer<Int>
    private let lineLen: UnsafeMutablePointer<Double>
    private let lineDamp: UnsafeMutablePointer<Float>
    private let lineGain: UnsafeMutablePointer<Float>
    private let lineTotal: Int

    private let diffBuf: UnsafeMutablePointer<Float>
    private let diffOffset: UnsafeMutablePointer<Int>
    private let diffLen: UnsafeMutablePointer<Int>
    private let diffIdx: UnsafeMutablePointer<Int>
    private let diffTotal: Int

    private let modPeriod: UnsafeMutablePointer<Double>
    private let modOffset: UnsafeMutablePointer<Double>
    private let sgnL: UnsafeMutablePointer<Float>
    private let sgnR: UnsafeMutablePointer<Float>

    /// Preallocated render scratch.
    private let y: UnsafeMutablePointer<Float>
    private let readPos: UnsafeMutablePointer<Double>

    private let preBuf: UnsafeMutablePointer<Float>
    private let preSize: Int
    private var preIdx = 0
    private var preLen = 1

    private var sampleRate = 44100.0
    private var lowCutL: Float = 0
    private var lowCutR: Float = 0
    private var mixSmoothed: Float = 0
    private var sizeSmoothed: Float = 1

    init() {
        let scale = Self.maxSampleRate / 44100.0

        func ibuf(_ n: Int) -> UnsafeMutablePointer<Int> {
            let p = UnsafeMutablePointer<Int>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p
        }
        func dbuf(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p
        }
        func fbuf(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p
        }

        lineOffset = ibuf(Self.lineCount)
        lineCap = ibuf(Self.lineCount)
        lineWrite = ibuf(Self.lineCount)
        lineLen = dbuf(Self.lineCount)
        lineDamp = fbuf(Self.lineCount)
        lineGain = fbuf(Self.lineCount)
        var total = 0
        for k in 0..<Self.lineCount {
            let cap = Int(Self.baseLens[k] * scale * Self.sizeHeadroom) + 64
            lineOffset[k] = total
            lineCap[k] = cap
            lineGain[k] = 0.9
            total += cap
        }
        lineTotal = total
        lineBuf = fbuf(total)

        let diffN = Self.diffCount * 2
        diffOffset = ibuf(diffN)
        diffLen = ibuf(diffN)
        diffIdx = ibuf(diffN)
        var dtotal = 0
        for i in 0..<diffN {
            let cap = Int(Self.diffLens[i] * scale) + 16
            diffOffset[i] = dtotal
            dtotal += cap
        }
        diffTotal = dtotal
        diffBuf = fbuf(dtotal)

        modPeriod = dbuf(Self.lineCount)
        modOffset = dbuf(Self.lineCount)
        sgnL = fbuf(Self.lineCount)
        sgnR = fbuf(Self.lineCount)
        for k in 0..<Self.lineCount {
            modPeriod[k] = Self.modPeriods[k]
            modOffset[k] = Self.modOffsets[k]
            sgnL[k] = Self.signL[k]
            sgnR[k] = Self.signR[k]
        }

        y = fbuf(Self.lineCount)
        readPos = dbuf(Self.lineCount)

        preSize = Int(Self.maxPredelay * Self.maxSampleRate) + 8
        preBuf = fbuf(preSize)

        applySampleRate()
    }

    deinit {
        lineBuf.deallocate(); lineOffset.deallocate(); lineCap.deallocate()
        lineWrite.deallocate(); lineLen.deallocate(); lineDamp.deallocate(); lineGain.deallocate()
        diffBuf.deallocate(); diffOffset.deallocate(); diffLen.deallocate(); diffIdx.deallocate()
        modPeriod.deallocate(); modOffset.deallocate(); sgnL.deallocate(); sgnR.deallocate()
        y.deallocate(); readPos.deallocate(); preBuf.deallocate()
    }

    func setSampleRate(_ sr: Double) {
        guard sr > 8000, sr <= Self.maxSampleRate, sr != sampleRate else { return }
        sampleRate = sr
        applySampleRate()
    }

    /// Called only outside the render loop.
    private func applySampleRate() {
        let scale = sampleRate / 44100.0
        for k in 0..<Self.lineCount {
            lineLen[k] = Self.baseLens[k] * scale
            lineWrite[k] = 0
            lineDamp[k] = 0
        }
        for i in 0..<(Self.diffCount * 2) {
            let cap = Int(Self.diffLens[i] * scale) + 16
            let room = (i + 1 < Self.diffCount * 2 ? diffOffset[i + 1] : diffTotal) - diffOffset[i]
            diffLen[i] = max(4, min(room - 2, min(cap, Int(Self.diffLens[i] * scale))))
            diffIdx[i] = 0
        }
        lineBuf.update(repeating: 0, count: lineTotal)
        diffBuf.update(repeating: 0, count: diffTotal)
        preBuf.update(repeating: 0, count: preSize)
        preIdx = 0
        preLen = max(1, min(preSize - 2, Int(0.028 * sampleRate)))
        lowCutL = 0; lowCutR = 0
    }

    func clear() {
        lineBuf.update(repeating: 0, count: lineTotal)
        diffBuf.update(repeating: 0, count: diffTotal)
        preBuf.update(repeating: 0, count: preSize)
        for k in 0..<Self.lineCount { lineDamp[k] = 0 }
        lowCutL = 0; lowCutR = 0
    }

    @inline(__always)
    private func allpass(_ i: Int, _ input: Float, _ g: Float) -> Float {
        let base = diffOffset[i]
        let idx = diffIdx[i]
        let delayed = diffBuf[base + idx]
        let v = input + delayed * g
        diffBuf[base + idx] = v
        var next = idx + 1
        if next >= diffLen[i] { next = 0 }
        diffIdx[i] = next
        return delayed - v * g
    }

    /// Mixes the wet signal into chL/chR in place.
    ///
    /// - Parameters:
    ///   - decay: RT60 in seconds.
    ///   - damp: 0…1 high-frequency absorption in the tail.
    ///   - size: 0.55…1.7 scaling of the delay lengths.
    ///   - mix: 0…1 wet amount.
    ///   - rotate: 0…1 depth of a very slow left/right rotation of the tail.
    ///   - time: running time in seconds at the start of the block.
    func process(_ n: Int,
                 _ chL: UnsafeMutablePointer<Float>,
                 _ chR: UnsafeMutablePointer<Float>,
                 decay: Double, damp: Float, size: Float, mix: Float,
                 rotate: Float, time: Double) {
        let sizeTarget = min(max(size, 0.55), 1.7)
        let mixTarget = min(max(mix, 0), 1)
        let rt60 = min(max(decay, 0.4), 40.0)
        let dampHz = Double(2600.0 - 2100.0 * min(max(damp, 0), 1))
        let dampCoef = 1.0 - Float(exp(-2.0 * Double.pi * dampHz / sampleRate))
        let lowCutCoef = 1.0 - Float(exp(-2.0 * Double.pi * 42.0 / sampleRate))
        let invSqrt8: Float = 0.35355339
        let lineCount = Self.lineCount

        var i = 0
        let chunk = 32
        while i < n {
            let count = min(chunk, n - i)
            let t = time + Double(i) / sampleRate

            sizeSmoothed += (sizeTarget - sizeSmoothed) * 0.02
            for k in 0..<lineCount {
                let base = lineLen[k] * Double(sizeSmoothed)
                let mod = 3.5 * sin(2.0 * Double.pi * (t / modPeriod[k] + modOffset[k]))
                readPos[k] = max(4.0, min(Double(lineCap[k] - 4), base + mod))
                lineGain[k] = Float(pow(10.0, -3.0 * base / (rt60 * sampleRate)))
            }

            // Very slow rotation of the tail across the stereo field (97 s).
            let rot = Double(min(max(rotate, 0), 1)) * 0.5 * sin(2.0 * Double.pi * t / 97.0)
            let rotL = Float(1.0 - max(0.0, rot))
            let rotR = Float(1.0 + min(0.0, rot))

            for j in 0..<count {
                let idx = i + j
                mixSmoothed += (mixTarget - mixSmoothed) * 0.0008

                let inL = chL[idx]
                let inR = chR[idx]

                // Pre-delay on a mono sum — the tail should not point anywhere.
                preBuf[preIdx] = (inL + inR) * 0.5
                var rp = preIdx - preLen
                if rp < 0 { rp += preSize }
                let delayed = preBuf[rp]
                preIdx += 1
                if preIdx >= preSize { preIdx = 0 }

                // Input diffusion — four allpasses per side, different lengths.
                var dl = delayed
                var dr = delayed
                for a in 0..<Self.diffCount {
                    dl = allpass(a, dl, 0.72)
                    dr = allpass(Self.diffCount + a, dr, 0.72)
                }

                // Read the network with a modulated fractional tap.
                for k in 0..<lineCount {
                    let cap = lineCap[k]
                    var p = Double(lineWrite[k]) - readPos[k]
                    if p < 0 { p += Double(cap) }
                    let i0 = Int(p)
                    let frac = Float(p - Double(i0))
                    let i1 = i0 + 1 >= cap ? 0 : i0 + 1
                    let off = lineOffset[k]
                    let a = lineBuf[off + i0]
                    let raw = a + (lineBuf[off + i1] - a) * frac
                    lineDamp[k] += (raw - lineDamp[k]) * dampCoef
                    y[k] = lineDamp[k]
                }

                var outL: Float = 0
                var outR: Float = 0
                for k in 0..<lineCount {
                    outL += y[k] * sgnL[k]
                    outR += y[k] * sgnR[k]
                }
                outL *= invSqrt8
                outR *= invSqrt8

                // Fast Walsh–Hadamard transform: lossless, maximally diffusive.
                var stride = 1
                while stride < lineCount {
                    var k = 0
                    while k < lineCount {
                        for m in k..<(k + stride) {
                            let a = y[m]
                            let b = y[m + stride]
                            y[m] = a + b
                            y[m + stride] = a - b
                        }
                        k += stride * 2
                    }
                    stride *= 2
                }

                for k in 0..<lineCount {
                    let feed = y[k] * invSqrt8 * lineGain[k]
                    let inject = (k % 2 == 0 ? dl : dr) * 0.42
                    lineBuf[lineOffset[k] + lineWrite[k]] = feed + inject
                    var w = lineWrite[k] + 1
                    if w >= lineCap[k] { w = 0 }
                    lineWrite[k] = w
                }

                // Keep rumble out of a 30-second tail.
                lowCutL += (outL - lowCutL) * lowCutCoef
                lowCutR += (outR - lowCutR) * lowCutCoef
                outL -= lowCutL
                outR -= lowCutR

                chL[idx] = inL + outL * mixSmoothed * rotL
                chR[idx] = inR + outR * mixSmoothed * rotR
            }
            i += count
        }
    }
}
