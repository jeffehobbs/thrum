import SwiftUI
import MetalKit
import simd

/// One wave. Laid out to match `Voice` in Wash.metal — three `float2`s, 24 bytes,
/// no Swift `Array` anywhere near it (see the phone's Visualizer for why).
struct WashVoice {
    /// Scale degree across (x) and tier (y); the shader turns x into a direction.
    var anchor = simd_float2(0, 0)
    /// (level, hue)
    var lh = simd_float2(0, 0)
    /// (seed, tier)
    var sp = simd_float2(0, 0)
}

/// Must stay laid out identically to `Header` in Wash.metal. 32 bytes.
struct WashHeader {
    var resolution = simd_float2(1, 1)
    var time: Float = 0
    var dim: Float = 1
    var count: Int32 = 0
    var master: Float = 0
    /// Always 1 on tvOS — see `makeUIView`. Kept in the layout so the shader's
    /// crest arithmetic stays written down for a platform that can use it.
    var headroom: Float = 1
    var pad: Float = 0
}

/// The wash, at the panel's native size.
///
/// The phone's visualizer spends most of its file explaining what it does *not*
/// draw, because a phone runs on a battery. An Apple TV does not. The drawable is
/// left at the layer's own scale — 3840×2160 on a 4K set — and the frame rate at
/// 60. It was 30 on the argument that the wash moves on 11–29 second LFOs and
/// 60 would oversample a slow signal; true of the signal, wrong about the eye,
/// which reads a slow gradient stepping at 30 as jitter. A dozen sines per pixel
/// in one full-screen pass is well inside an A15 at that size, at either rate.
struct WashView: UIViewRepresentable {
    @ObservedObject var host: TVHost

    func makeCoordinator() -> Renderer { Renderer(host: host) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = context.coordinator
        // As much colour as tvOS will give a Metal layer, which is wide gamut in
        // sixteen bits — and not HDR. `wantsExtendedDynamicRangeContent` and
        // `CAEDRMetadata` are both `API_UNAVAILABLE(tvos)`: on an Apple TV only
        // HDR *video* may go above reference white, and a drawable that tries
        // is clamped. So: float pixels into Display P3, which gets the P3
        // primaries (the wash's saturated blues and greens are outside sRGB)
        // and a ten-bit ramp on the way to the panel — no dither needed — while
        // 1.0 stays SDR white. If the set is in an HDR mode the Apple TV maps
        // that white into the container itself; the shader cannot exceed it.
        view.colorPixelFormat = .rgba16Float
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        view.framebufferOnly = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = TVHost.fps
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.host = host
    }

    final class Renderer: NSObject, MTKViewDelegate {
        var host: TVHost
        weak var view: MTKView?

        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var header = WashHeader()
        private var voices = [WashVoice](repeating: WashVoice(), count: 32)
        private let startTime = CFAbsoluteTimeGetCurrent()
        /// Eased toward 1 while playing and toward a low glow while idle, so a
        /// stop is the room dimming rather than a cut.
        private var dim: Float = 0.35

        init(host: TVHost) {
            self.host = host
            super.init()
            build()
        }

        private func build() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let library = device.makeDefaultLibrary(),
                  let vfn = library.makeFunction(name: "wash_vertex"),
                  let ffn = library.makeFunction(name: "wash_fragment") else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .rgba16Float
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
            // Read for the log only. UIScreen reports an EDR headroom on tvOS
            // even though no layer here can opt into using it; the shader is
            // handed 1 regardless, so the picture never depends on a number the
            // platform will not honour. What the set actually reports is worth
            // knowing, and `./build.sh tvlog` is where it shows up.
            let reported = Float(view.window?.screen.currentEDRHeadroom ?? 1)
            header.headroom = 1
            MainActor.assumeIsolated { host.noteHeadroom(reported) }
            let target: Float = MainActor.assumeIsolated { host.running } ? 1 : 0.35
            dim += (target - dim) * 0.02
            header.dim = dim
            let filled = MainActor.assumeIsolated { host.fillWash(&voices) }
            header.count = filled.count
            header.master = filled.master

            encoder.setRenderPipelineState(pipeline)
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
