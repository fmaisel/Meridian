// Metal renderer reproducing WebGLRenderer's behaviour for this scene: background pass, one directional
// shadow map (PCF soft), opaque list sorted front-to-back, transparent list back-to-front, render orders,
// per-material depth/blend/side state. All static geometry lives in GPU buffers built once; per frame
// only small uniform blocks change.

import MetalKit
import simd

struct FrameUniforms {
    var viewProj = M4.identity
    var view = M4.identity
    var proj = M4.identity
    var shadowVP = M4.identity
    var sunDir = F4.zero
    var sunColor = F4.zero
    var hemiSky = F4.zero
    var hemiGround = F4.zero
    var fogColor = F4.zero
    var fog = F4.zero
    var foci0 = F4.zero, foci1 = F4.zero, foci2 = F4.zero, foci3 = F4.zero, foci4 = F4.zero, foci5 = F4.zero
    var rimColor = F4.zero
    var focus = F4.zero
    var viewDir = F4.zero
    var viewport = F4.zero
    var skyTop = F4.zero
    var skyBottom = F4.zero
    var skyGlow = F4.zero
    var skyParams = F4.zero

    mutating func setFocus(_ i: Int, _ v: F4) {
        switch i {
        case 0: foci0 = v
        case 1: foci1 = v
        case 2: foci2 = v
        case 3: foci3 = v
        case 4: foci4 = v
        default: foci5 = v
        }
    }
}

struct DrawUniforms {
    var model = M4.identity
    var normalMat = M4.identity
    var color = F4.zero
    var glowColor = F4.zero
    var params = F4.zero
    var extra = F4.zero
    var extra2 = F4.zero
}

struct LineVertex {
    var p: (Float, Float, Float)
    var c: (Float, Float, Float)
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let textures: TextureLibrary
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var depthStates: [String: MTLDepthStencilState] = [:]
    private let shadowTexture: MTLTexture
    private let white: MTLTexture
    private let repeatSampler: MTLSamplerState
    private let clampSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private let sampleCount = 4
    let colorFormat: MTLPixelFormat = .bgra8Unorm
    private let frameSemaphore = DispatchSemaphore(value: 3)

    var frame = FrameUniforms()
    var shadowsEnabled = true
    /// Device pixels per point used for the drawable (adaptive).
    var pixelRatio: Float = 2
    /// Device pixels per world unit of the orthographic camera (for world-sized points).
    var pixelsPerUnit: Float = 50

    // reused per frame (no allocation in the hot path)
    private var opaque: [Node] = []
    private var transparent: [Node] = []
    private var casters: [Node] = []
    private var zOf: [Int: Float] = [:]

    var debugLines: [LineVertex] = []
    var debugSeams: [LineVertex] = []
    var debugPoints: [LineVertex] = []
    var debugBoxes: [LineVertex] = []
    var debugEnabled = false

    init?(view: MTKView) {
        // shaders ship as Metal source and are compiled once at launch (the system caches the result)
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let url = Bundle.main.url(forResource: "Shaders.metal", withExtension: "txt"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: source, options: options) } catch {
            print("Shader compile failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
        textures = TextureLibrary(device: device, queue: queue)

        // twice the web resolution over the same frustum: crisper contact shadows at no visible cost on Apple GPUs
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 4096, height: 4096, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        shadowTexture = device.makeTexture(descriptor: sd)!

        let wd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        white = device.makeTexture(descriptor: wd)!
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)

        let rs = MTLSamplerDescriptor()
        rs.minFilter = .linear; rs.magFilter = .linear; rs.mipFilter = .linear
        rs.sAddressMode = .repeat; rs.tAddressMode = .repeat
        rs.maxAnisotropy = 4
        repeatSampler = device.makeSamplerState(descriptor: rs)!
        let cs = MTLSamplerDescriptor()
        cs.minFilter = .linear; cs.magFilter = .linear; cs.mipFilter = .linear
        cs.sAddressMode = .clampToEdge; cs.tAddressMode = .clampToEdge
        cs.maxAnisotropy = 4
        clampSampler = device.makeSamplerState(descriptor: cs)!
        let ns = MTLSamplerDescriptor()
        ns.minFilter = .nearest; ns.magFilter = .nearest
        ns.sAddressMode = .clampToEdge; ns.tAddressMode = .clampToEdge
        nearestSampler = device.makeSamplerState(descriptor: ns)!

        view.device = device
        view.colorPixelFormat = colorFormat
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.framebufferOnly = true
    }

    // ───────────────────────── resources ─────────────────────────

    func makeMesh(_ d: MeshData, pickable: Bool = false) -> GPUMesh {
        var floats = [Float]()
        floats.reserveCapacity(d.count * 9)
        var cpu: [F3] = []
        if pickable { cpu.reserveCapacity(d.count) }
        for i in 0..<d.count {
            let p = d.positions[i], n = d.normals[i], uv = d.uvs[i]
            floats += [Float(p.x), Float(p.y), Float(p.z), Float(n.x), Float(n.y), Float(n.z), Float(uv.x), Float(uv.y), Float(d.mist[i])]
            if pickable { cpu.append(p.f) }
        }
        let b = d.count > 0 ? d.bounds : (V3.zero, V3.zero)
        let center = ((b.0 + b.1) / 2).f
        var r: Float = 0
        for p in d.positions { r = max(r, simd_distance(p.f, center)) }
        let buf = device.makeBuffer(bytes: floats, length: max(16, floats.count * 4), options: .storageModeShared)!
        return GPUMesh(buffer: buf, offset: 0, count: d.count, cpu: pickable ? cpu : nil, center: center, radius: r)
    }

    /// Dynamic point cloud (positions only); the caller writes into `buffer.contents()`.
    func makePoints(count: Int) -> GPUMesh {
        let buf = device.makeBuffer(length: count * 12, options: .storageModeShared)!
        return GPUMesh(buffer: buf, offset: 0, count: count, primitive: .point, cpu: nil, center: .zero, radius: 0)
    }

    private func pipeline(_ name: String, vs: String, fs: String?, blend: Blend, depthOnly: Bool = false) -> MTLRenderPipelineState {
        let key = "\(name)|\(blend)"
        if let p = pipelines[key] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: vs)
        if let fs { d.fragmentFunction = library.makeFunction(name: fs) }
        if depthOnly {
            d.depthAttachmentPixelFormat = .depth32Float
        } else {
            d.rasterSampleCount = sampleCount
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            c.pixelFormat = colorFormat
            switch blend {
            case .none:
                c.isBlendingEnabled = false
            case .normal:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .sourceAlpha
                c.destinationAlphaBlendFactor = .one
            }
        }
        let p = try! device.makeRenderPipelineState(descriptor: d)
        pipelines[key] = p
        return p
    }

    private func depthState(test: Bool, write: Bool, fn: MTLCompareFunction) -> MTLDepthStencilState {
        let key = "\(test)\(write)\(fn.rawValue)"
        if let s = depthStates[key] { return s }
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = test ? fn : .always
        d.isDepthWriteEnabled = write
        let s = device.makeDepthStencilState(descriptor: d)!
        depthStates[key] = s
        return s
    }

    private func pipelineFor(_ m: Material) -> MTLRenderPipelineState {
        let b = m.effectiveBlend
        switch m.kind {
        case .lit: return pipeline("lit", vs: "vs_lit", fs: "fs_lit", blend: b)
        case .basic: return pipeline("basic", vs: "vs_basic", fs: "fs_basic", blend: b)
        case .sprite: return pipeline("sprite", vs: "vs_sprite", fs: "fs_basic", blend: b)
        case .points: return pipeline("points", vs: "vs_points", fs: "fs_points", blend: b)
        case .water: return pipeline("water", vs: "vs_world", fs: "fs_water", blend: b)
        case .fall: return pipeline("fall", vs: "vs_world", fs: "fs_fall", blend: b)
        case .banner: return pipeline("banner", vs: "vs_banner", fs: "fs_banner", blend: b)
        case .mist: return pipeline("mist", vs: "vs_world", fs: "fs_mist", blend: b)
        case .beam: return pipeline("beam", vs: "vs_world", fs: "fs_beam", blend: b)
        }
    }

    /// Build every pipeline state up front so no effect stutters the first time it appears.
    func prewarm() {
        let combos: [(ShaderKind, [Blend])] = [
            (.lit, [.none, .normal]), (.basic, [.none, .normal, .additive]), (.sprite, [.normal, .additive]), (.points, [.normal]),
            (.water, [.none]), (.fall, [.normal]), (.banner, [.none]), (.mist, [.normal]), (.beam, [.additive]),
        ]
        for (kind, blends) in combos {
            for b in blends {
                let m = Material(kind)
                m.blending = b == .none ? .normal : b
                m.transparent = b != .none
                _ = pipelineFor(m)
            }
        }
        _ = pipeline("sky", vs: "vs_sky", fs: "fs_sky", blend: .none)
        _ = pipeline("shadow", vs: "vs_shadow", fs: nil, blend: .none, depthOnly: true)
        _ = pipeline("line", vs: "vs_line", fs: "fs_line", blend: .normal)
    }

    private func ensureTargets(_ w: Int, _ h: Int) {
        if let t = msaaColor, t.width == w, t.height == h { return }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: w, height: h, mipmapped: false)
        cd.textureType = .type2DMultisample
        cd.sampleCount = sampleCount
        cd.usage = .renderTarget
        cd.storageMode = .memoryless
        msaaColor = device.makeTexture(descriptor: cd)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.textureType = .type2DMultisample
        dd.sampleCount = sampleCount
        dd.usage = .renderTarget
        dd.storageMode = .memoryless
        msaaDepth = device.makeTexture(descriptor: dd)
    }

    // ───────────────────────── frame ─────────────────────────

    func render(scene: Node, in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        frameSemaphore.wait()
        let tex = drawable.texture
        ensureTargets(tex.width, tex.height)
        frame.viewport = F4(Float(tex.width), Float(tex.height), pixelRatio, pixelsPerUnit)
        frame.fog.w = shadowsEnabled ? 1 : 0

        scene.updateWorld()
        collect(scene)

        guard let cb = queue.makeCommandBuffer() else { frameSemaphore.signal(); return }
        cb.addCompletedHandler { [sem = frameSemaphore] _ in sem.signal() }

        if shadowsEnabled { shadowPass(cb) }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = msaaColor
        rp.colorAttachments[0].resolveTexture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .multisampleResolve
        rp.depthAttachment.texture = msaaDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { frameSemaphore.signal(); return }
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentTexture(shadowTexture, index: 1)
        enc.setFragmentSamplerState(nearestSampler, index: 1)

        // background (sky) — no depth
        enc.setRenderPipelineState(pipeline("sky", vs: "vs_sky", fs: "fs_sky", blend: .none))
        enc.setDepthStencilState(depthState(test: false, write: false, fn: .always))
        enc.setCullMode(.none)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        for n in opaque { draw(n, enc) }
        for n in transparent { draw(n, enc) }
        if debugEnabled { drawDebug(enc) }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func collect(_ scene: Node) {
        opaque.removeAll(keepingCapacity: true)
        transparent.removeAll(keepingCapacity: true)
        casters.removeAll(keepingCapacity: true)
        zOf.removeAll(keepingCapacity: true)
        let vp = frame.viewProj
        func visit(_ n: Node) {
            guard n.visible else { return }
            if let m = n.material, m.visible, n.mesh != nil || n.isSprite {
                let c = n.isSprite ? F3.zero : n.mesh!.center
                let p = vp * (n.worldMatrix * F4(c, 1))
                zOf[n.id] = p.z / p.w
                if m.transparent { transparent.append(n) } else { opaque.append(n) }
                if n.castShadow && !n.isSprite && n.mesh?.primitive == .triangle { casters.append(n) }
            }
            for c in n.children { visit(c) }
        }
        visit(scene)
        opaque.sort { a, b in
            if a.renderOrder != b.renderOrder { return a.renderOrder < b.renderOrder }
            if a.material!.id != b.material!.id { return a.material!.id < b.material!.id }
            let za = zOf[a.id]!, zb = zOf[b.id]!
            if za != zb { return za < zb }
            return a.id < b.id
        }
        transparent.sort { a, b in
            if a.renderOrder != b.renderOrder { return a.renderOrder < b.renderOrder }
            let za = zOf[a.id]!, zb = zOf[b.id]!
            if za != zb { return za > zb }
            return a.id < b.id
        }
    }

    private func shadowPass(_ cb: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.depthAttachment.texture = shadowTexture
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setFrontFacing(.counterClockwise)
        enc.setRenderPipelineState(pipeline("shadow", vs: "vs_shadow", fs: nil, blend: .none, depthOnly: true))
        enc.setDepthStencilState(depthState(test: true, write: true, fn: .lessEqual))
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        var du = DrawUniforms()
        for n in casters {
            guard let mesh = n.mesh, let m = n.material else { continue }
            // three renders the opposite side into the shadow map (FrontSide → BackSide)
            switch m.side {
            case .front: enc.setCullMode(.front)
            case .back: enc.setCullMode(.back)
            case .double: enc.setCullMode(.none)
            }
            du.model = n.worldMatrix
            enc.setVertexBuffer(mesh.buffer, offset: mesh.offset, index: 0)
            enc.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
        }
        enc.endEncoding()
    }

    private func draw(_ n: Node, _ enc: MTLRenderCommandEncoder) {
        guard let m = n.material else { return }
        enc.setRenderPipelineState(pipelineFor(m))
        enc.setDepthStencilState(depthState(test: m.depthTest, write: m.depthWrite, fn: m.depthFunc))
        switch m.side {
        case .front: enc.setCullMode(.back)
        case .back: enc.setCullMode(.front)
        case .double: enc.setCullMode(.none)
        }
        enc.setFrontFacing(simd_determinant(n.worldMatrix.upperLeft3x3) < 0 ? .clockwise : .counterClockwise)
        if m.polygonOffset { enc.setDepthBias(-4, slopeScale: -4, clamp: 0) } else { enc.setDepthBias(0, slopeScale: 0, clamp: 0) }

        var du = DrawUniforms()
        du.model = n.worldMatrix
        let nm = n.worldMatrix.upperLeft3x3.inverse.transpose
        du.normalMat = M4(columns: (F4(nm.columns.0, 0), F4(nm.columns.1, 0), F4(nm.columns.2, 0), F4(0, 0, 0, 1)))
        du.color = F4(m.color, m.opacity)
        du.glowColor = F4(m.glowColor, m.glow)
        var flags = 0
        if m.map != nil { flags |= 1 }
        if m.flat { flags |= 2 }
        if n.receiveShadow { flags |= 4 }
        du.params = F4(m.cut, Float(flags), m.kind == .points ? m.size : m.phase, m.k)
        du.extra = m.extra
        du.extra2 = m.extra2
        enc.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentTexture(m.map ?? white, index: 0)
        enc.setFragmentSamplerState(m.map === textures.tile ? repeatSampler : clampSampler, index: 0)

        if n.isSprite {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        } else if let mesh = n.mesh {
            enc.setVertexBuffer(mesh.buffer, offset: mesh.offset, index: 0)
            enc.drawPrimitives(type: mesh.primitive, vertexStart: 0, vertexCount: mesh.count)
        }
    }

    private func drawDebug(_ enc: MTLRenderCommandEncoder) {
        enc.setDepthStencilState(depthState(test: false, write: false, fn: .always))
        enc.setCullMode(.none)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        func lines(_ v: [LineVertex], _ type: MTLPrimitiveType, _ alpha: Float, _ size: Float) {
            guard !v.isEmpty else { return }
            enc.setRenderPipelineState(pipeline("line", vs: "vs_line", fs: "fs_line", blend: .normal))
            var du = DrawUniforms()
            du.color = F4(1, 1, 1, alpha)
            du.params = F4(0, 0, size, 0)
            enc.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setFragmentBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            v.withUnsafeBytes { raw in
                if raw.count <= 4096 {
                    enc.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
                } else if let b = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) {
                    enc.setVertexBuffer(b, offset: 0, index: 0)
                }
            }
            enc.drawPrimitives(type: type, vertexStart: 0, vertexCount: v.count)
        }
        lines(debugBoxes, .line, 0.35, 1)
        lines(debugLines, .line, 0.8, 1)
        lines(debugSeams, .line, 1, 1)
        lines(debugPoints, .point, 1, 7)
    }
}
