import Metal
import simd

/// Core Metal raymarcher. Platform-agnostic: used by both the iOS `MTKView`
/// host and the macOS headless `ReliefRender` harness.
///
/// Two passes, all rendered at `supersample`× the target resolution (SSAA)
/// to anti-alias the distant silhouette:
///   1. `raymarchFragment` -> shaded color intermediate.
///   2. `downsampleFragment` -> box-average the hi-res color into `target`.
final class TerrainRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// Queue for offline bake/mask work — see init. Never used by per-frame paths.
    let bakeQueue: MTLCommandQueue
    private let raymarchPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let panoramaBakePipeline: MTLRenderPipelineState
    private let panoramaDepthPipeline: MTLRenderPipelineState
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
    /// Far-horizon strip (FarHorizon.swift): r16Float 2D texture, azimuth ×
    /// tan-elevation rows, texel = nearest beyond-tier hit distance in km
    /// (0 = sky). Nil binds `emptyRing` so the bake shaders need no flag.
    var ringTexture: MTLTexture?
    private lazy var emptyRing: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var texel: [Float16] = [0]                // 0 km = sky everywhere
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                  withBytes: &texel, bytesPerRow: 2)
        return t
    }()
    /// Coarse, wide-coverage far-field DEM, bound at texture(1). Sampled only where
    /// the near `heightTexture` has no data. nil → far tier disabled.
    var farHeightTexture: MTLTexture?

    /// Supersampling factor (1 = off). 2 = render at 2x, downsample (4x cost).
    var supersample: Int = 2

    // Hi-res intermediate, (re)allocated when the supersampled size changes.
    private var colorTex: MTLTexture?

    static let colorFormat: MTLPixelFormat = .rgba8Unorm

    init(device: MTLDevice, preferSource: Bool = false) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        self.commandQueue = queue
        // Offline work (bake bands, AA, depth/sky masks) runs on its OWN queue.
        // draw(in:) blocks the main thread on waitUntilScheduled (the label-sync
        // transaction), and on a shared queue every live frame during a re-bake
        // queued behind the in-flight ~10 ms band — the "first second after a
        // move" pan jitter. Cross-queue hazards don't arise: every consumer of a
        // baked texture waits for its command buffer's completion handler on the
        // CPU before touching the result. (-sharedBakeQueue: debug A/B switch
        // to restore the old single-queue behavior for comparison.)
        self.bakeQueue = ProcessInfo.processInfo.arguments.contains("-sharedBakeQueue")
            ? queue : (device.makeCommandQueue() ?? queue)

        let library: MTLLibrary
        if !preferSource,
           let def = device.makeDefaultLibrary(),
           def.makeFunction(name: "fullscreenVertex") != nil {
            library = def
        } else {
            let source = try ShaderLoader.loadSource()
            library = try device.makeLibrary(source: source, options: nil)
        }
        // DEM-sampling functions get told whether this GPU can linear-filter
        // 32-bit float textures (Apple families before 9 — most iPhones —
        // cannot; the sampler silently degrades to nearest and the terrain
        // shows every 30 m cell as a flat step). false → the shader's manual
        // bilinear fallback, selected at compile time.
        let demConstants = MTLFunctionConstantValues()
        var hwFilterF32 = device.supports32BitFloatFiltering
        demConstants.setConstantValue(&hwFilterF32, type: .bool, index: 0)

        guard let vfn = library.makeFunction(name: "fullscreenVertex"),
              let march = try? library.makeFunction(name: "raymarchFragment", constantValues: demConstants),
              let down = library.makeFunction(name: "downsampleFragment"),
              let panoBake = try? library.makeFunction(name: "panoramaBakeFragment", constantValues: demConstants),
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

        // Panorama hit-distance map for label occlusion — r32Float target.
        guard let panoDepth = try? library.makeFunction(name: "panoramaDepthFragment",
                                                        constantValues: demConstants) else {
            throw RendererError.missingFunctions
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = panoDepth
        pd.colorAttachments[0].pixelFormat = .r32Float
        self.panoramaDepthPipeline = try device.makeRenderPipelineState(descriptor: pd)

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

    /// Height of an equirectangular panorama band `width` texels wide — the
    /// single home of the aspect contract with the shader's v-mapping
    /// (elevation band [-panoElevMax, +panoElevMax] out of a full π).
    static func panoHeight(forWidth width: Int, elevMax: Float) -> Int {
        max(1, Int(Double(width) * Double(elevMax) / Double.pi))
    }

    /// Bind the terrain inputs every raymarching pass needs: uniforms, near DEM
    /// (texture 0), far tier (texture 1, near as stand-in so something is always
    /// bound), far-horizon ring strip (texture 2, empty stand-in likewise).
    private func bindTerrainInputs(_ enc: MTLRenderCommandEncoder, _ u: inout Uniforms) {
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let tex = heightTexture { enc.setFragmentTexture(tex, index: 0) }
        enc.setFragmentTexture(farHeightTexture ?? heightTexture, index: 1)
        if let ring = ringTexture ?? emptyRing { enc.setFragmentTexture(ring, index: 2) }
    }

    /// Encode the equirectangular bake at `panoramaWidth` into a fresh color
    /// texture. Returns the committed-but-not-waited command buffer and the
    /// target color texture; the caller decides whether to block or wait async.
    private func encodeBake(uniforms: Uniforms) -> (MTLCommandBuffer, MTLTexture)? {
        let panoW = panoramaWidth
        let panoH = Self.panoHeight(forWidth: panoW, elevMax: uniforms.panoElevMax)

        func make(_ fmt: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: panoW, height: panoH, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // Color-only bake (depth output dropped): one render target, not two.
        guard let bakeColor = make(Self.colorFormat),
              let cb = bakeQueue.makeCommandBuffer() else { return nil }
        var u = uniforms

        // Equirectangular raymarch -> the panorama color texture.
        let pa = MTLRenderPassDescriptor()
        pa.colorAttachments[0].texture = bakeColor
        pa.colorAttachments[0].loadAction = .clear
        pa.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pa) {
            enc.setRenderPipelineState(panoramaBakePipeline)
            bindTerrainInputs(enc, &u)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        return (cb, bakeColor)
    }

    /// Render a SMALL equirectangular bake and return its per-texel terrain/sky alpha
    /// (≈255 = terrain, 0 = sky). Uses the SAME bake shader and per-direction rays as
    /// the full panorama, so the terrain/sky verdict at any (az, el) matches the real
    /// bake exactly regardless of resolution — used to cull peak labels whose summit
    /// lands on sky the bake draws above the (coarsely-rendered) terrain. CPU-readable.
    func terrainSkyMask(uniforms: Uniforms, width: Int = 1024) -> (width: Int, height: Int, alpha: [UInt8])? {
        let w = max(8, width)
        let h = Self.panoHeight(forWidth: w, elevMax: uniforms.panoElevMax)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared                  // CPU-readable via getBytes
        guard let tex = device.makeTexture(descriptor: d),
              let cb = bakeQueue.makeCommandBuffer() else { return nil }
        var u = uniforms
        let pa = MTLRenderPassDescriptor()
        pa.colorAttachments[0].texture = tex
        pa.colorAttachments[0].loadAction = .clear
        pa.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pa) else { return nil }
        enc.setRenderPipelineState(panoramaBakePipeline)
        bindTerrainInputs(enc, &u)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { ptr in
            tex.getBytes(ptr.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { alpha[i] = rgba[i * 4 + 3] }   // rgba8: alpha is byte 3
        return (w, h, alpha)
    }

    /// Per-texel hit-distance panorama for label occlusion (blocking; ~50–150 ms
    /// at the 4096 default — one-time per viewpoint, called off-main). Sky/miss
    /// texels carry the FAR sentinel (≥ maxDistance×4). Rendered with the SAME
    /// march/eye/DEM as the visible panorama, so a label visibility decision made
    /// against it always agrees with the picture on screen.
    ///
    /// 8192 (0.044°/texel): the visible bake is 8–16 K wide, and the coarser
    /// the depth map, the wider the quantization band at silhouettes where
    /// near-grazing peaks flip between shown/hidden — at 4096 a summit
    /// skimming a ridge 80 km out was decided by a pixel that could lie.
    /// ~40–80 MB transient, one banded pass per viewpoint (still far cheaper
    /// than the bake it runs beside).
    /// `paced: true` = a display frame's breather between bands, exactly like
    /// the paced bake: this pass runs DURING moves while the old scene is
    /// still live and interactive, and back-to-back bands saturated the GPU —
    /// visible as pan jitter for the pass's whole duration. The caller blocks
    /// a background thread either way, so pacing costs only wall time.
    func terrainDepthMap(uniforms: Uniforms, width: Int = 8192, paced: Bool = false)
        -> (width: Int, height: Int, depth: [Float])? {
        let w = max(8, width)
        let h = Self.panoHeight(forWidth: w, elevMax: uniforms.panoElevMax)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared                  // CPU-readable via getBytes
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        var u = uniforms
        // Sliced into azimuth bands like the bake (see bakePanoramaAsync): this
        // runs while the app is LIVE, and one 4k unpreemptible raymarch pass froze
        // the display for its whole duration. 512-texel bands keep each GPU chunk
        // around a frame; the caller already blocks a utility thread, so waiting
        // per band costs nothing extra.
        let bands = max(1, (w + 511) / 512)
        let bandW = (w + bands - 1) / bands
        for i in 0..<bands {
            guard let cb = bakeQueue.makeCommandBuffer() else { return nil }
            let pa = MTLRenderPassDescriptor()
            pa.colorAttachments[0].texture = tex
            pa.colorAttachments[0].loadAction = i == 0 ? .clear : .load
            pa.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pa) else { return nil }
            enc.setRenderPipelineState(panoramaDepthPipeline)
            bindTerrainInputs(enc, &u)
            let x = i * bandW
            enc.setScissorRect(MTLScissorRect(x: x, y: 0, width: min(bandW, w - x), height: h))
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            // An aborted buffer (app backgrounded mid-pass) leaves the texture
            // part-zeroed — and depth 0 reads as "terrain right in front of
            // the eye", so every label would judge occluded and the scene
            // shows NO labels at all. Fail loud instead; the caller retries.
            guard cb.status == .completed else { return nil }
            if paced, i + 1 < bands { Thread.sleep(forTimeInterval: 0.014) }
        }
        var depth = [Float](repeating: 0, count: w * h)
        depth.withUnsafeMutableBytes { ptr in
            tex.getBytes(ptr.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return (w, h, depth)
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
              let cb = bakeQueue.makeCommandBuffer() else { return nil }
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
    ///
    /// The raymarch is SLICED into azimuth bands, one command buffer each, chained
    /// via completion handlers. A single monolithic pass owned the GPU for its full
    /// duration (hundreds of ms at 16k) and a render pass can't be preempted — the
    /// live view AND all UIKit/CoreAnimation compositing froze while it ran. Bands
    /// give the display a scheduling gap between buffers, so the app stays fluid
    /// while the bake streams in behind it.
    /// `onProgress` (main queue) ticks once per completed band with 0…1 — the
    /// bands give the readout a genuinely continuous signal during the bake
    /// (the readout used to freeze at a constant until the whole bake landed).
    /// `paced: true` = leave a display frame's gap between bands. For SILENT
    /// top-ups (the far-horizon ring landing right as a move's scene swaps in):
    /// they run at the exact moment the user starts panning the new scene, and
    /// back-to-back bands kept the GPU saturated for the first second. The gap
    /// halves the bake's GPU duty cycle at the cost of ~2× its (invisible)
    /// wall time. Latency-critical bakes (a move's main bake) stay unpaced.
    func bakePanoramaAsync(uniforms: Uniforms,
                           paced: Bool = false,
                           onProgress: ((Double) -> Void)? = nil,
                           completion: @escaping (MTLTexture?) -> Void) {
        let panoW = panoramaWidth
        let panoH = Self.panoHeight(forWidth: panoW, elevMax: uniforms.panoElevMax)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: panoW, height: panoH, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let bakeColor = device.makeTexture(descriptor: d) else {
            DispatchQueue.main.async { completion(nil) }; return
        }
        // The quick bake (≤2048) stays one slice — the loading screen is up, nothing
        // can jitter, and latency to first image matters most. The full-res rebake
        // runs while the user is ALREADY looking around, so its bands are 256 texels:
        // ~10 ms of GPU each, under a display frame, which keeps the live pan smooth
        // instead of stuttering for the bake's whole duration. Per-band encode/commit
        // overhead is well under a millisecond.
        let bands = panoW <= 2048 ? 1 : (panoW + 255) / 256
        let bandW = (panoW + bands - 1) / bands
        var u = uniforms

        func encodeBand(_ i: Int) {
            guard let cb = bakeQueue.makeCommandBuffer() else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let pa = MTLRenderPassDescriptor()
            pa.colorAttachments[0].texture = bakeColor
            // First band clears the whole target; later bands write their scissored
            // slice over what's already there.
            pa.colorAttachments[0].loadAction = i == 0 ? .clear : .load
            pa.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: pa) {
                enc.setRenderPipelineState(panoramaBakePipeline)
                bindTerrainInputs(enc, &u)
                let x = i * bandW
                enc.setScissorRect(MTLScissorRect(
                    x: x, y: 0, width: min(bandW, panoW - x), height: panoH))
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            cb.addCompletedHandler { [weak self] buf in
                // GPU work aborted (classic case: the app was backgrounded mid-bake
                // — iOS forbids background GPU execution). The target texture is
                // partly or wholly unwritten; zero alpha reads as "sky", so
                // installing it paints the whole view blue. Report failure instead
                // and let the caller retry when the app is active again.
                if buf.error != nil {
                    NSLog("Panorama bake aborted at band %d: %@", i,
                          String(describing: buf.error))
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                if let onProgress {
                    let f = Double(i + 1) / Double(bands)
                    DispatchQueue.main.async { onProgress(f) }
                }
                if i + 1 < bands {
                    if paced {
                        // Next band after a frame's breather — the live view
                        // gets a clean GPU slot between bands.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                            encodeBand(i + 1)
                        }
                    } else {
                        encodeBand(i + 1)
                    }
                    return
                }
                // AA runs in its own command buffer, kicked off only once the bake
                // has completed — reading the just-rendered panorama inside the same
                // command buffer races the write and yields garbage.
                guard let self, let (cb2, aa) = self.encodeAA(src: bakeColor) else {
                    DispatchQueue.main.async { completion(bakeColor) }   // fallback: un-AA'd
                    return
                }
                cb2.addCompletedHandler { buf2 in
                    // AA aborted (backgrounded): the bake itself finished — ship
                    // the un-AA'd panorama rather than a garbage AA target.
                    DispatchQueue.main.async { completion(buf2.error == nil ? aa : bakeColor) }
                }
                cb2.commit()
            }
            cb.commit()
        }
        encodeBand(0)
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

    /// Labels-only AR: clear the drawable to fully transparent and draw NO terrain,
    /// so only the CALayer peak overlay shows over the live camera. CoreAnimation
    /// composites the (empty) drawable over the camera preview.
    func encodeClearTransparent(into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
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
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        colorTex = device.makeTexture(descriptor: d)
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
        guard let colorTex = colorTex else { return }
        var u = uniforms

        // --- Pass 1: raymarch -> color (hi-res) ---
        // (The old second MRT attachment — a supersampled r32Float depth target,
        // ~48 MB resident — had no downstream reader and is gone.)
        let p1 = MTLRenderPassDescriptor()
        p1.colorAttachments[0].texture = colorTex
        p1.colorAttachments[0].loadAction = .clear
        p1.colorAttachments[0].storeAction = .store
        p1.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: p1) {
            enc.setRenderPipelineState(raymarchPipeline)
            // The raymarch fragment takes no ring texture (the far ring only
            // exists in the bake/depth paths), but the shared bind is harmless.
            bindTerrainInputs(enc, &u)
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
