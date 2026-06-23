import Metal
import simd

/// Core Metal raymarcher. Platform-agnostic: used by both the iOS `MTKView`
/// host and the macOS headless `ReliefRender` harness.
///
/// Two passes, all rendered at `supersample`× the target resolution (SSAA)
/// to anti-alias the distant silhouette:
///   1. `raymarchFragment` (MRT) -> color + linear-depth intermediates.
///   2. `downsampleFragment` -> box-average the hi-res color into `target`.
final class TerrainRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let raymarchPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let panoramaBakePipeline: MTLRenderPipelineState
    private let panoramaViewPipeline: MTLRenderPipelineState
    private let panoramaViewARPipeline: MTLRenderPipelineState
    private let panoramaViewEdgesPipeline: MTLRenderPipelineState
    private let panoramaAAPipeline: MTLRenderPipelineState

    /// Equirectangular width of the baked 360° panorama (height derived from
    /// the elevation band). Larger = crisper when zoomed, more memory.
    /// 16384 is the Metal texture-dimension cap (~45 px/°).
    var panoramaWidth: Int = 16384
    /// The baked panorama (equirect color). nil until `bakePanorama` runs.
    private(set) var panoramaTex: MTLTexture?

    /// Optional sampled DEM height texture (R32Float, value = meters).
    var heightTexture: MTLTexture?

    /// Supersampling factor (1 = off). 2 = render at 2x, downsample (4x cost).
    var supersample: Int = 2

    // Hi-res intermediates, (re)allocated when the supersampled size changes.
    private var colorTex: MTLTexture?
    private var depthTex: MTLTexture?

    static let colorFormat: MTLPixelFormat = .rgba8Unorm
    static let depthFormat: MTLPixelFormat = .r32Float

    init(device: MTLDevice, preferSource: Bool = false) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        self.commandQueue = queue

        let library: MTLLibrary
        if !preferSource,
           let def = device.makeDefaultLibrary(),
           def.makeFunction(name: "fullscreenVertex") != nil {
            library = def
        } else {
            let source = try ShaderLoader.loadSource()
            library = try device.makeLibrary(source: source, options: nil)
        }
        guard let vfn = library.makeFunction(name: "fullscreenVertex"),
              let march = library.makeFunction(name: "raymarchFragment"),
              let down = library.makeFunction(name: "downsampleFragment"),
              let panoBake = library.makeFunction(name: "panoramaBakeFragment"),
              let panoView = library.makeFunction(name: "panoramaViewFragment"),
              let panoViewAR = library.makeFunction(name: "panoramaViewARFragment"),
              let panoViewEdges = library.makeFunction(name: "panoramaViewEdgesFragment"),
              let panoAA = library.makeFunction(name: "panoramaAAFragment") else {
            throw RendererError.missingFunctions
        }

        let p1 = MTLRenderPipelineDescriptor()
        p1.vertexFunction = vfn
        p1.fragmentFunction = march
        p1.colorAttachments[0].pixelFormat = Self.colorFormat
        p1.colorAttachments[1].pixelFormat = Self.depthFormat
        self.raymarchPipeline = try device.makeRenderPipelineState(descriptor: p1)

        let p3 = MTLRenderPipelineDescriptor()
        p3.vertexFunction = vfn
        p3.fragmentFunction = down
        p3.colorAttachments[0].pixelFormat = Self.colorFormat
        self.downsamplePipeline = try device.makeRenderPipelineState(descriptor: p3)

        // Panorama bake (color only — depth output dropped to halve bake memory).
        let pb = MTLRenderPipelineDescriptor()
        pb.vertexFunction = vfn
        pb.fragmentFunction = panoBake
        pb.colorAttachments[0].pixelFormat = Self.colorFormat
        self.panoramaBakePipeline = try device.makeRenderPipelineState(descriptor: pb)

        let pv = MTLRenderPipelineDescriptor()
        pv.vertexFunction = vfn
        pv.fragmentFunction = panoView
        pv.colorAttachments[0].pixelFormat = Self.colorFormat
        self.panoramaViewPipeline = try device.makeRenderPipelineState(descriptor: pv)

        // AR view: same target format; outputs premultiplied alpha so the sky is
        // transparent over the live camera. CoreAnimation composites the drawable.
        let pvAR = MTLRenderPipelineDescriptor()
        pvAR.vertexFunction = vfn
        pvAR.fragmentFunction = panoViewAR
        pvAR.colorAttachments[0].pixelFormat = Self.colorFormat
        self.panoramaViewARPipeline = try device.makeRenderPipelineState(descriptor: pvAR)

        // AR edges: white ridge edges over transparent (camera passthrough).
        let pvE = MTLRenderPipelineDescriptor()
        pvE.vertexFunction = vfn
        pvE.fragmentFunction = panoViewEdges
        pvE.colorAttachments[0].pixelFormat = Self.colorFormat
        self.panoramaViewEdgesPipeline = try device.makeRenderPipelineState(descriptor: pvE)

        // One-time edge AA applied to the baked panorama (post-bake).
        let pAA = MTLRenderPipelineDescriptor()
        pAA.vertexFunction = vfn
        pAA.fragmentFunction = panoAA
        pAA.colorAttachments[0].pixelFormat = Self.colorFormat
        self.panoramaAAPipeline = try device.makeRenderPipelineState(descriptor: pAA)
    }

    // MARK: - 360° panorama

    /// Encode the equirectangular bake at `panoramaWidth` into a fresh color
    /// texture. Returns the committed-but-not-waited command buffer and the
    /// target color texture; the caller decides whether to block or wait async.
    private func encodeBake(uniforms: Uniforms) -> (MTLCommandBuffer, MTLTexture)? {
        let panoW = panoramaWidth
        let panoH = max(1, Int(Double(panoW) * Double(uniforms.panoElevMax) / Double.pi))

        func make(_ fmt: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: panoW, height: panoH, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // Color-only bake (depth output dropped): one render target, not two.
        guard let bakeColor = make(Self.colorFormat),
              let cb = commandQueue.makeCommandBuffer() else { return nil }
        var u = uniforms

        // Equirectangular raymarch -> the panorama color texture.
        let pa = MTLRenderPassDescriptor()
        pa.colorAttachments[0].texture = bakeColor
        pa.colorAttachments[0].loadAction = .clear
        pa.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pa) {
            enc.setRenderPipelineState(panoramaBakePipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            if let tex = heightTexture { enc.setFragmentTexture(tex, index: 0) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        return (cb, bakeColor)
    }

    /// One-time edge AA of a baked panorama, in its OWN command buffer. Run after
    /// the bake has fully completed (so the source is finished — reading a
    /// just-rendered texture inside the same command buffer races the write and
    /// returns garbage). A single fullscreen pass; no per-frame cost.
    private func encodeAA(src: MTLTexture) -> (MTLCommandBuffer, MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: src.width, height: src.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let dst = device.makeTexture(descriptor: d),
              let cb = commandQueue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(panoramaAAPipeline)
        enc.setFragmentTexture(src, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return (cb, dst)
    }

    /// Bake the full 360° panorama for the fixed viewpoint in `uniforms`
    /// (one-time; redo only when the viewpoint moves). Blocks until complete.
    /// Used by the headless harness; the app uses `bakePanoramaAsync`.
    func bakePanorama(uniforms: Uniforms) {
        guard let (cb, bakeColor) = encodeBake(uniforms: uniforms) else { return }
        cb.commit()
        cb.waitUntilCompleted()                 // bake fully done before AA reads it
        if let (cb2, aa) = encodeAA(src: bakeColor) {
            cb2.commit()
            cb2.waitUntilCompleted()
            panoramaTex = aa
        } else {
            panoramaTex = bakeColor
        }
    }

    /// Bake without blocking the calling thread: the GPU does the work and
    /// `completion` is called on the main queue with the finished panorama once
    /// ready. The caller decides whether to `installPanorama` it (so a stale
    /// background bake can be discarded). Lets launch / reload stay responsive.
    func bakePanoramaAsync(uniforms: Uniforms, completion: @escaping (MTLTexture?) -> Void) {
        guard let (cb, bakeColor) = encodeBake(uniforms: uniforms) else {
            DispatchQueue.main.async { completion(nil) }; return
        }
        // AA runs in a second command buffer, kicked off only once the bake has
        // completed — reading the just-rendered panorama inside the same command
        // buffer races the write and yields garbage.
        cb.addCompletedHandler { [weak self] _ in
            guard let self, let (cb2, aa) = self.encodeAA(src: bakeColor) else {
                DispatchQueue.main.async { completion(bakeColor) }   // fallback: un-AA'd
                return
            }
            cb2.addCompletedHandler { _ in
                DispatchQueue.main.async { completion(aa) }
            }
            cb2.commit()
        }
        cb.commit()
    }

    /// Install a baked panorama as the current one. Call on the main thread
    /// (draw() reads `panoramaTex` there).
    func installPanorama(_ tex: MTLTexture) { panoramaTex = tex }

    /// Per-frame: sample the baked panorama for the current heading in
    /// `uniforms` (forward/right/up/fov/panoElevMax). Cheap; call every frame.
    func encodeView(uniforms: Uniforms, into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                    loadClear: SIMD4<Double> = SIMD4(0, 0, 0, 1)) {
        var u = uniforms
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: loadClear.x, green: loadClear.y, blue: loadClear.z, alpha: loadClear.w)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Before the first bake lands, just present the clear (black) — avoids
        // showing an undefined drawable on the first frame.
        if let pano = panoramaTex {
            enc.setRenderPipelineState(panoramaViewPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(pano, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    /// AR per-frame (relief): terrain opaque, sky transparent so the live camera
    /// reads through the (non-opaque) MTKView. The 3D `encodeView` path is unchanged.
    func encodeViewAR(uniforms: Uniforms, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        encodeTransparent(pipeline: panoramaViewARPipeline, uniforms: uniforms,
                          into: target, commandBuffer: commandBuffer)
    }

    /// AR per-frame (edges): white ridge edges over a transparent overlay; the rest
    /// is camera passthrough.
    func encodeViewEdges(uniforms: Uniforms, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        encodeTransparent(pipeline: panoramaViewEdgesPipeline, uniforms: uniforms,
                          into: target, commandBuffer: commandBuffer)
    }

    /// Shared transparent-overlay pass: clears to fully transparent, runs the given
    /// premultiplied-alpha view pipeline. CoreAnimation composites the drawable over
    /// whatever is behind the MTKView (the camera preview).
    private func encodeTransparent(pipeline: MTLRenderPipelineState, uniforms: Uniforms,
                                   into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        var u = uniforms
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let pano = panoramaTex {
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(pano, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    private func ensureIntermediates(width: Int, height: Int) {
        if let c = colorTex, c.width == width, c.height == height { return }
        func make(_ fmt: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        colorTex = make(Self.colorFormat)
        depthTex = make(Self.depthFormat)
    }

    /// Encode all passes, downsampling the final image into `target`.
    func encode(uniforms: Uniforms,
                into target: MTLTexture,
                commandBuffer: MTLCommandBuffer,
                loadClear: SIMD4<Double> = SIMD4(0, 0, 0, 1)) {
        let ss = max(1, supersample)
        let hiW = target.width * ss
        let hiH = target.height * ss
        ensureIntermediates(width: hiW, height: hiH)
        guard let colorTex = colorTex, let depthTex = depthTex else { return }
        var u = uniforms

        // --- Pass 1: raymarch -> color + depth (hi-res) ---
        let p1 = MTLRenderPassDescriptor()
        p1.colorAttachments[0].texture = colorTex
        p1.colorAttachments[0].loadAction = .clear
        p1.colorAttachments[0].storeAction = .store
        p1.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        p1.colorAttachments[1].texture = depthTex
        p1.colorAttachments[1].loadAction = .clear
        p1.colorAttachments[1].storeAction = .store
        let far = Double(uniforms.maxDistance) * 4.0
        p1.colorAttachments[1].clearColor = MTLClearColor(red: far, green: far, blue: far, alpha: far)
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: p1) {
            enc.setRenderPipelineState(raymarchPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            if let tex = heightTexture { enc.setFragmentTexture(tex, index: 0) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // --- Pass 2: downsample color -> target ---
        let p3 = MTLRenderPassDescriptor()
        p3.colorAttachments[0].texture = target
        p3.colorAttachments[0].loadAction = .clear
        p3.colorAttachments[0].storeAction = .store
        p3.colorAttachments[0].clearColor = MTLClearColor(
            red: loadClear.x, green: loadClear.y, blue: loadClear.z, alpha: loadClear.w)
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: p3) {
            enc.setRenderPipelineState(downsamplePipeline)
            enc.setFragmentTexture(colorTex, index: 0)
            var ssU = UInt32(ss)
            enc.setFragmentBytes(&ssU, length: MemoryLayout<UInt32>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    enum RendererError: Error {
        case noCommandQueue
        case missingFunctions
    }
}
