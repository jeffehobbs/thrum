import AudioToolbox
import AVFoundation
import Foundation

/// Thrum as an AUv3 instrument (`aumu thrm Jhob`), for Logic and any other host.
///
/// Thin on purpose: the parameter tree, the bus, and a render block that hands
/// the host's buffer and event list to `ThrumKernel`. Patch state is the
/// parameter tree, which `AUAudioUnit`'s own `fullState` already saves and
/// restores — there is nothing else in Thrum worth remembering between sessions.
public final class ThrumAudioUnit: AUAudioUnit {
    let kernel = ThrumKernel()

    private var outputBus: AUAudioUnitBus!
    private var outputBusArray: AUAudioUnitBusArray!
    private var _currentPreset: AUAudioUnitPreset?
    private let presets: [AUAudioUnitPreset] = ThrumPresets.all.enumerated().map {
        let p = AUAudioUnitPreset()
        p.number = $0.offset
        p.name = $0.element.name
        return p
    }

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        let tree = ThrumParamSpec.makeTree()
        let kernel = self.kernel
        tree.implementorValueObserver = { [weak self] param, value in
            // Flow's own moves coming back round from `publishFlow` are already
            // in the kernel; passing them on would read as a hand on the control
            // and make Flow let go of it.
            if self?.publishing == true { return }
            kernel.set(param.address, Double(value))
        }
        tree.implementorValueProvider = { param in AUValue(kernel.get(param.address)) }
        tree.implementorStringFromValueCallback = { param, value in
            guard let p = ThrumParam(rawValue: param.address) else { return "" }
            return ThrumParamSpec.spec(p).display(Double(value?.pointee ?? param.value))
        }
        parameterTree = tree

        maximumFramesToRender = 4096
        _currentPreset = presets.first
        published = ThrumParamSpec.all.map { $0.defaultValue }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.publishFlow() }
        timer.resume()
        flowTimer = timer
    }

    deinit { flowTimer?.cancel() }

    // MARK: - Flow → host

    /// Flow moves controls from the render thread, straight into the kernel,
    /// and nobody outside this process hears about it: the host's view of the
    /// tree is a proxy that only updates when a value is *set*. So four times a
    /// second, anything that has moved under it is set again here — which is
    /// what makes Logic's own controls follow Flow, and lets automation in
    /// Latch or Touch record a Flow session as it happens.
    private var flowTimer: DispatchSourceTimer?
    private var publishing = false
    private var published: [Double] = []

    private func publishFlow() {
        guard let tree = parameterTree else { return }
        publishing = true
        defer { publishing = false }
        for spec in ThrumParamSpec.all {
            let i = Int(spec.param.rawValue)
            let v = kernel.get(spec.param.rawValue)
            // A hair either way is not worth a message to the host.
            let span = spec.range.upperBound - spec.range.lowerBound
            guard abs(v - published[i]) > span * 0.0005 else { continue }
            published[i] = v
            tree.parameter(withAddress: spec.param.rawValue)?.setValue(AUValue(v), originator: nil)
        }
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    /// No input, mono or stereo out.
    public override var channelCapabilities: [NSNumber]? { [0, 2, 0, 1] }

    public override var factoryPresets: [AUAudioUnitPreset]? { presets }

    public override var currentPreset: AUAudioUnitPreset? {
        get { _currentPreset }
        set {
            guard let preset = newValue else { _currentPreset = nil; return }
            if preset.number >= 0 {
                guard preset.number < ThrumPresets.all.count, let tree = parameterTree else { return }
                let values = ThrumPresets.all[preset.number].values
                for spec in ThrumParamSpec.all {
                    tree.parameter(withAddress: spec.param.rawValue)?.value =
                        AUValue(values[spec.param] ?? spec.defaultValue)
                }
                _currentPreset = preset
            } else {
                // A user preset: the base class reads it from disk and sets
                // fullState from it.
                super.currentPreset = preset
                _currentPreset = preset
            }
        }
    }

    public override var supportsUserPresets: Bool { true }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        guard format.channelCount == 1 || format.channelCount == 2 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        kernel.prepare(sampleRate: format.sampleRate, maxFrames: Int(maximumFramesToRender))
    }

    public override func reset() {
        super.reset()
        kernel.requestReset()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, events, _ in
            kernel.render(frameCount: Int(frameCount), timestamp: timestamp,
                          output: outputData, events: events)
        }
    }
}
