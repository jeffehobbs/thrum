import AVFoundation

/// Small owner for a two-channel AudioBufferList, so the harness can call the
/// ordinary stereo render path alongside the spatial one and compare them.
final class AudioBufferListHolder {
    let ptr: UnsafeMutablePointer<AudioBufferList>
    let l: UnsafeMutablePointer<Float>
    let r: UnsafeMutablePointer<Float>
    private let abl: UnsafeMutableAudioBufferListPointer

    init(_ n: Int) {
        abl = AudioBufferList.allocate(maximumBuffers: 2)
        l = UnsafeMutablePointer<Float>.allocate(capacity: n)
        r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        l.initialize(repeating: 0, count: n)
        r.initialize(repeating: 0, count: n)
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4),
                             mData: UnsafeMutableRawPointer(l))
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4),
                             mData: UnsafeMutableRawPointer(r))
        ptr = abl.unsafeMutablePointer
    }
}
