import SwiftUI
import MetalKit
import simd

/// The visualizer, and most of this app's battery budget.
///
/// Measured first, so the tuning here is aimed at the right target: the drone
/// engine renders Flow at 78× realtime (`Tools/budget`), about 1.3% of one core.
/// The audio is not what drains a phone — the screen and the GPU are. So every
/// choice below is about drawing as little as possible while still looking
/// continuous:
///
/// - **20 fps, not 60.** The content is modulated by LFOs on 11–29 second
///   periods. At 20 fps the fastest thing on screen is still sampled hundreds of
///   times per cycle; 60 would be spending triple the GPU to oversample a
///   0.09 Hz signal. Idle drops it to 6.
/// - **Deliberately under-sampled drawable.** A soft-bloom field is the one kind
///   of image that survives being drawn at a fraction of native resolution, and
///   on an iPad Pro native is 5.6 M pixels. Rendering at ~1 px per point instead
///   of 2–3 is a 4–9× cut in fragment work for no visible difference.
/// - **Genuinely paused when nothing is on screen.** Not throttled — paused. The
///   audio keeps going in the background; the GPU has no reason to.
/// One bloom, laid out to match the `Voice` struct in Shaders.metal.
///
/// Top-level rather than nested because `FlowHost` fills these directly from the
/// engine's meters — one copy, straight from the audio-thread-written array into
/// the uniform block, with no intermediate representation to keep in sync.
struct ShaderVoice {
    var position = simd_float2(0, 0)
    var level: Float = 0
    var hue: Float = 0
}

/// Must stay laid out identically to `Header` in Shaders.metal.
///
/// Contains no Swift `Array`, and that is the whole point — see the note on
/// `Header` in the shader. The voices travel as their own binding.
struct FieldHeader {
    var resolution = simd_float2(1, 1)
    var time: Float = 0
    var dim: Float = 1
    var count: Int32 = 0
    var master: Float = 0
}

struct FieldView: UIViewRepresentable {
    @ObservedObject var host: FlowHost

    func makeCoordinator() -> Renderer { Renderer(host: host) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.backgroundColor = .black
        // Draw on the display's clock rather than on demand — the field is always
        // moving, so setNeedsDisplay would just mean "every frame" with extra steps.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = FlowHost.activeFPS
        // See the note above: fewer fragments, no perceptible cost to blooms.
        view.contentScaleFactor = 1.0
        // No depth/stencil and no multisampling; this is one flat pass.
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.host = host
        view.preferredFramesPerSecond = host.targetFPS
        view.isPaused = !host.visualizerRunning
    }

    /// Bridges the engine's meters into the shader once per frame.
    ///
    /// Deliberately does no work on the audio thread and takes no locks: it reads
    /// the engine's meter array, which is written by the render thread and read
    /// here as a benign race on `Float`s — the same contract the Mac app's on-screen
    /// meters already use. A torn read shows one frame of a slightly wrong
    /// brightness, which is not a thing anyone can see.
    final class Renderer: NSObject, MTKViewDelegate {
        var host: FlowHost
        weak var view: MTKView?

        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        // Separate stored properties rather than one aggregate: the first version
        // passed three `inout` projections of a single struct into `fillField`,
        // which Swift's exclusivity checker correctly kills at runtime
        // ("simultaneous accesses… modification requires exclusive access").
        // Two independent variables cannot overlap.
        private var header = FieldHeader()
        private var voices = [ShaderVoice](repeating: ShaderVoice(), count: 32)
        private var startTime = CFAbsoluteTimeGetCurrent()

        init(host: FlowHost) {
            self.host = host
            super.init()
            build()
        }

        private func build() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let library = device.makeDefaultLibrary(),
                  let vfn = library.makeFunction(name: "field_vertex"),
                  let ffn = library.makeFunction(name: "field_fragment") else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
            queue = device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            header.resolution = simd_float2(Float(size.width), Float(size.height))
        }

        func draw(in view: MTKView) {
            guard let pipeline, let queue,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

            header.time = Float(CFAbsoluteTimeGetCurrent() - startTime)
            header.dim = host.dim
            let filled = host.fillField(&voices)
            header.count = filled.count
            header.master = filled.master

            encoder.setRenderPipelineState(pipeline)
            // Both small enough to go straight in as bytes — no buffers to manage
            // or triple-buffer, and no allocation per frame.
            withUnsafeBytes(of: &header) { raw in
                encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
            voices.withUnsafeBytes { raw in
                encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
