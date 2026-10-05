// MTTerrainRenderer.swift — ORIGINAL code for the MetalTerrain library.
//
// Metal 3 renderer (Metal 4 fast paths where available) for MTTerrainWorld:
// chunk streaming with an LRU mesh cache, background mesh building,
// one draw call per chunk, one for water, and one instanced draw per
// structure kind.

import Foundation
import Metal
import MetalKit
import simd

// MARK: - Private math helpers (original)

private func mtLookAt(eye: SIMD3<Float>,
                      target: SIMD3<Float>,
                      up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> simd_float4x4 {
    let z = normalize(eye - target)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(x.x, y.x, z.x, 0)
    m.columns.1 = SIMD4<Float>(x.y, y.y, z.y, 0)
    m.columns.2 = SIMD4<Float>(x.z, y.z, z.z, 0)
    m.columns.3 = SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    return m
}

private func mtPerspective(fovDegrees: Float, aspect: Float,
                           near: Float, far: Float) -> simd_float4x4 {
    let f: Float = 1.0 / tan(fovDegrees * .pi / 360.0)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(f / aspect, 0, 0, 0)
    m.columns.1 = SIMD4<Float>(0, f, 0, 0)
    // Metal NDC depth is 0...1; the camera looks down -Z.
    m.columns.2 = SIMD4<Float>(0, 0, far / (near - far), -1)
    m.columns.3 = SIMD4<Float>(0, 0, (far * near) / (near - far), 0)
    return m
}

private func mtTranslation(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return m
}

private func mtRotationY(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle), s = sin(angle)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(c, 0, -s, 0)
    m.columns.2 = SIMD4<Float>(s, 0, c, 0)
    return m
}

private func mtUniformScale(_ s: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.0.x = s
    m.columns.1.y = s
    m.columns.2.z = s
    return m
}

// MARK: - Shader-visible structs

/// Must match `MTUniforms` in MTShaders.metal (192 bytes).
/// Uniform block uploaded per frame. 192 bytes, all 16-byte aligned.
/// Swift's `SIMD3<Float>` is 16-byte aligned (unlike Metal's 12-byte
/// `float3`), so small fields are packed into `SIMD4`s to keep the layout
/// identical on both sides. Must match `MTUniforms` in MTShaders.metal.
private struct MTUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    var cameraPos: SIMD4<Float>  // xyz = camera position
    var fogColor: SIMD4<Float>   // rgb = fog color, w = fog density
    var lightDir: SIMD4<Float>   // xyz = light direction, w = ambient
    var misc: SIMD4<Float>       // x = time seconds
}

/// Must match `MTInstanceData` in MTShaders.metal (80 bytes).
private struct MTInstanceData {
    var model: simd_float4x4
    var tint: SIMD4<Float>  // rgb = color tint
}

// MARK: - Renderer

/// Renders an `MTTerrainWorld` with Metal.
///
/// Typical integration:
/// ```swift
/// let renderer = MTTerrainRenderer(device: device, world: world)
/// renderer.setCamera(position: eye, target: lookAt, fovDegrees: 60,
///                    aspect: aspect, near: 0.1, far: 2000)
/// // per frame:
/// renderer.update(cameraTarget: SIMD2<Float>(lookAt.x, lookAt.z))
/// renderer.draw(in: mtkView)
/// ```
public final class MTTerrainRenderer {

    // MARK: Public API (exact per DESIGN.md)

    public var world: MTTerrainWorld {
        didSet { invalidateCaches() }
    }

    public var wireframe: Bool = false
    public var showsWater: Bool = true
    public var fogEnabled: Bool = true
    /// Sun position: azimuth (0-360°, direction) and elevation (0-90°, height).
    public var sunAzimuth: Float = 45
    public var sunElevation: Float = 50
    /// Last measured FPS (written by the demo's render loop, polled by UI).
    public var currentFPS: Double = 0
    /// Enhanced shader effects (specular + fresnel). Default off.
    public var shaderEffectsEnabled: Bool = false
    /// Render distance in chunks (radius). Changing this updates the world
    /// config, which triggers a cache invalidation and rebuild.
    public var viewDistance: Int {
        get { world.config.viewDistance }
        set {
            var cfg = world.config
            cfg.viewDistance = newValue
            world.config = cfg
        }
    }

    public init(device: MTLDevice, world: MTTerrainWorld) {
        self.device = device
        self.world = world
        guard let queue = device.makeCommandQueue() else {
            preconditionFailure("MTTerrainRenderer: device.makeCommandQueue() failed")
        }
        self.commandQueue = queue
        self.uniformStride = MemoryLayout<MTUniforms>.stride
        precondition(uniformStride == 192, "MTUniforms layout drifted from MTShaders.metal")
        // Metal requires buffer offsets bound via setVertexBuffer/setFragmentBuffer
        // to be multiples of 256. MTUniforms is 192 bytes, so pad the stride.
        self.uniformStrideAligned = (uniformStride + 255) & ~255

        buildPipelines()
        buildDepthStates()
        buildUniformBuffer()
        buildWaterMesh()
        loadStructureMeshes()
    }

    public func setCamera(position: SIMD3<Float>, target: SIMD3<Float>,
                          fovDegrees: Float, aspect: Float,
                          near: Float, far: Float) {
        cameraPos = position
        viewProj = mtPerspective(fovDegrees: fovDegrees, aspect: aspect,
                                 near: near, far: far)
            * mtLookAt(eye: position, target: target)
    }

    /// Streams chunks around `cameraTarget` (world XZ). Call every frame.
    /// Missing chunks are built on a background queue; the visible set only
    /// ever grows/shrinks by finished meshes, so `draw` never blocks.
    public func update(cameraTarget: SIMD2<Float>) {
        lastCameraTarget = cameraTarget
        // If the user replaced `world.config`, drop stale chunk meshes and
        // rebuild the water plane (its size/level come from the config).
        let version = world.configVersion
        if version != lastConfigVersion {
            lastConfigVersion = version
            invalidateCaches()
            buildWaterMesh()
        }
        let cfg = world.config
        let size = cfg.chunkWorldSize
        let radius = cfg.viewDistance
        let center = MTChunkCoord(x: Int(floor(cameraTarget.x / size)),
                                  z: Int(floor(cameraTarget.y / size)))

        // Fast path: if the camera hasn't crossed a chunk boundary, the needed
        // set is identical — skip the Set rebuild, eviction scan, and dispatch
        // loop entirely. (update() runs 60x/sec; this work is only needed
        // on movement.)
        if center == lastCenter {
            return
        }
        lastCenter = center

        var needed = Set<MTChunkCoord>()
        needed.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
        for dz in -radius...radius {
            for dx in -radius...radius {
                needed.insert(MTChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }

        let now = Date().timeIntervalSince1970
        var toBuild: [MTChunkCoord] = []
        cacheLock.lock()
        // Evict anything outside the view radius.
        for coord in chunkCache.keys where Self.chebyshev(coord, center) > radius {
            chunkCache.removeValue(forKey: coord)
        }
        // LRU cap: never hold more than the full visible square, with an
        // absolute ceiling so a large viewDistance can't exhaust iPad memory.
        let cap = min((2 * radius + 1) * (2 * radius + 1), Self.maxChunkCacheSize)
        if chunkCache.count > cap {
            let oldest = chunkCache
                .sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(chunkCache.count - cap)
                .map { $0.key }
            for coord in oldest { chunkCache.removeValue(forKey: coord) }
        }
        for coord in needed {
            if var mesh = chunkCache[coord] {
                mesh.lastUsed = now
                chunkCache[coord] = mesh
            } else if !pendingBuilds.contains(coord) {
                pendingBuilds.insert(coord)
                toBuild.append(coord)
            }
        }
        cacheLock.unlock()

        for coord in toBuild {
            buildChunkAsync(coord, cameraTarget: cameraTarget)
        }

        // Rebuild structure instances only when the visible chunk set changes.
        // Track enabled state separately to force rebuild on toggle.
        if world.structuresEnabled {
            if needed != structureChunkSet || !structuresWereEnabled {
                structureChunkSet = needed
                structuresWereEnabled = true
                rebuildStructureInstances(visible: needed)
            }
        } else if !structureChunkSet.isEmpty || structuresWereEnabled {
            structureChunkSet = []
            structuresWereEnabled = false
            clearStructureInstances()
        }
    }

    /// Renders the current frame into `view`. The host app owns the
    /// `MTKViewDelegate`; call this from `mtkView(_:draw:)`.
    public func draw(in view: MTKView) {
        if !viewConfigured {
            view.depthStencilPixelFormat = .depth32Float
            view.colorPixelFormat = .bgra8Unorm
            viewConfigured = true
        }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // Wait for an in-flight frame to finish before reusing its slot.
        frameSemaphore.wait()
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.frameSemaphore.signal()
        }

        frameIndex = (frameIndex + 1) % maxFramesInFlight
        let terrainSlot = frameIndex * slotsPerFrame
        let waterSlot = terrainSlot + 1
        let time = Float(Date().timeIntervalSince(startTime))
        writeUniforms(slot: terrainSlot, model: matrix_identity_float4x4, time: time)
        // Water plane is built around the XZ origin; recenter it under the camera.
        writeUniforms(slot: waterSlot,
                      model: mtTranslation(SIMD3<Float>(lastCameraTarget.x, 0,
                                                        lastCameraTarget.y)),
                      time: time)

        encoder.setDepthStencilState(depthState)
        encoder.setTriangleFillMode(wireframe ? .lines : .fill)
        encoder.setCullMode(.back)

        // 1 draw call per chunk. Iterate under the lock instead of
        // copying to an Array every frame (was a 60fps allocation).
        // Frustum culling: skip chunks outside the camera view.
        encoder.setRenderPipelineState(terrainPipeline)
        bindUniforms(encoder, slot: terrainSlot)
        let frustum = Frustum(viewProj: viewProj)
        cacheLock.lock()
        for mesh in chunkCache.values {
            guard frustum.intersects(min: mesh.boundsMin, max: mesh.boundsMax) else { continue }
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: mesh.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: mesh.indexBuffer,
                                          indexBufferOffset: 0)
        }
        cacheLock.unlock()

        // 1 instanced draw per structure kind.
        encoder.setRenderPipelineState(structurePipeline)
        bindUniforms(encoder, slot: terrainSlot)
        for kind in MTStructureKind.allCases {
            guard let sm = structureMeshes[kind],
                  sm.instanceCount > 0,
                  let instanceBuffer = sm.instanceBuffer
            else { continue }
            encoder.setVertexBuffer(sm.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: sm.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: sm.indexBuffer,
                                          indexBufferOffset: 0,
                                          instanceCount: sm.instanceCount)
        }

        // 1 draw for water, blended, drawn last.
        if showsWater, let wvb = waterVertexBuffer, let wib = waterIndexBuffer {
            encoder.setRenderPipelineState(waterPipeline)
            encoder.setDepthStencilState(waterDepthState)
            bindUniforms(encoder, slot: waterSlot)
            var alpha = waterAlpha
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 2)
            encoder.setVertexBuffer(wvb, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: waterIndexCount,
                                          indexType: .uint32,
                                          indexBuffer: wib,
                                          indexBufferOffset: 0)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Metal 4 detection

    /// True when the Metal 4 pipeline path was taken (iOS 26+, device
    /// supports it, and compilation succeeded). Otherwise Metal 3.
    public private(set) var usesMetal4: Bool = false

    // MARK: - Internals

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private var terrainPipeline: MTLRenderPipelineState!
    private var waterPipeline: MTLRenderPipelineState!
    private var structurePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var waterDepthState: MTLDepthStencilState!

    private var viewProj = matrix_identity_float4x4
    private var cameraPos = SIMD3<Float>(0, 0, 0)
    private var lastCameraTarget = SIMD2<Float>(0, 0)
    private var lastCenter: MTChunkCoord?
    private var lastConfigVersion: UInt64 = 0
    private let waterAlpha: Float = 0.82
    private let startTime = Date()

    // Triple-buffered uniforms; two slots per frame (terrain + water).
    // The semaphore guarantees the CPU never overwrites a uniform slot
    // the GPU is still reading (without it, a fast CPU can lap the GPU
    // and corrupt in-flight uniforms).
    private let maxFramesInFlight = 3
    private let frameSemaphore = DispatchSemaphore(value: 3)
    private let slotsPerFrame = 2
    /// Absolute ceiling on cached chunk meshes: ~300 chunks x ~290KB.
    /// Prevents memory exhaustion if viewDistance is raised.
    private static let maxChunkCacheSize = 300
    private let uniformStride: Int
    /// 256-byte aligned stride for buffer offsets (Metal requirement).
    private let uniformStrideAligned: Int
    private var uniformBuffer: MTLBuffer!
    private var frameIndex = 0

    private struct ChunkMesh {
        var vertexBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
        var lastUsed: TimeInterval
        /// World-space AABB for frustum culling.
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
    }

    /// Camera frustum planes extracted from the view-projection matrix.
    /// Each plane is (normal.xyz, distance): points with dot(n, p) + d > 0
    /// are inside.
    private struct Frustum {
        var planes: [SIMD4<Float>]  // 6 planes: left, right, bottom, top, near, far

        init(viewProj: simd_float4x4) {
            let m = viewProj
            // Rows of the matrix (Metal uses column-major storage).
            let r0 = SIMD4<Float>(m[0][0], m[1][0], m[2][0], m[3][0])
            let r1 = SIMD4<Float>(m[0][1], m[1][1], m[2][1], m[3][1])
            let r2 = SIMD4<Float>(m[0][2], m[1][2], m[2][2], m[3][2])
            let r3 = SIMD4<Float>(m[0][3], m[1][3], m[2][3], m[3][3])
            planes = [
                normalizePlane(r3 + r0),  // left
                normalizePlane(r3 - r0),  // right
                normalizePlane(r3 + r1),  // bottom
                normalizePlane(r3 - r1),  // top
                normalizePlane(r2),       // near (Metal depth is [0,1], not [-1,1])
                normalizePlane(r3 - r2),  // far
            ]
        }

        /// True if the AABB is at least partially inside the frustum.
        func intersects(min: SIMD3<Float>, max: SIMD3<Float>) -> Bool {
            for p in planes {
                let n = SIMD3<Float>(p.x, p.y, p.z)
                // Positive vertex of the AABB relative to the plane normal.
                let px = n.x >= 0 ? max.x : min.x
                let py = n.y >= 0 ? max.y : min.y
                let pz = n.z >= 0 ? max.z : min.z
                if n.x * px + n.y * py + n.z * pz + p.w < 0 {
                    return false
                }
            }
            return true
        }
    }

    private static func normalizePlane(_ p: SIMD4<Float>) -> SIMD4<Float> {
        let len = sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
        return len > 0 ? p / len : p
    }
    private var chunkCache: [MTChunkCoord: ChunkMesh] = [:]
    private var pendingBuilds = Set<MTChunkCoord>()
    private let cacheLock = NSLock()
    private let buildQueue = DispatchQueue(label: "com.MetalTerrain.meshBuild",
                                           qos: .userInitiated,
                                           attributes: .concurrent)
    // Generation counter: bumped by invalidateCaches(). Background builds
    // capture the generation at dispatch; if it changed by completion,
    // the mesh is stale (built from an old config) and must be dropped.
    private var buildGeneration: UInt64 = 0

    private var waterVertexBuffer: MTLBuffer?
    private var waterIndexBuffer: MTLBuffer?
    private var waterIndexCount = 0

    private struct StructureMesh {
        var vertexBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
        var instanceBuffer: MTLBuffer?
        var instanceCount: Int
    }
    private var structureMeshes: [MTStructureKind: StructureMesh] = [:]
    private var structureChunkSet = Set<MTChunkCoord>()
    private var structuresWereEnabled = true

    private var viewConfigured = false

    private static func chebyshev(_ a: MTChunkCoord, _ b: MTChunkCoord) -> Int {
        max(abs(a.x - b.x), abs(a.z - b.z))
    }

    // MARK: Pipelines

    private func defaultLibrary() -> MTLLibrary {
        // Newer SDKs: makeDefaultLibrary throws and returns non-optional.
        do {
            return try device.makeDefaultLibrary(bundle: .module)
        } catch {
            preconditionFailure("MTTerrainRenderer: default Metal library not found in bundle (.module). " +
                                "MTShaders.metal must be part of the MetalTerrain target: \(error)")
        }
    }

    private func buildPipelines() {
        let library = defaultLibrary()
        // Metal 4 needs Apple Silicon (the MTL4* types don't exist in the
        // Intel SDK). On arm64 with iOS 26 / macOS 26+, try Metal 4 first.
        #if arch(arm64)
        if #available(iOS 26, macOS 26, *), buildMetal4Pipelines(library: library) {
            usesMetal4 = true
            return
        }
        #endif
        usesMetal4 = false
        buildMetal3Pipelines(library: library)
    }

    private func buildMetal3Pipelines(library: MTLLibrary) {
        func descriptor(vertex: String, fragment: String, blending: Bool) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            guard let v = library.makeFunction(name: vertex),
                  let f = library.makeFunction(name: fragment) else {
                preconditionFailure("MTTerrainRenderer: missing shader function \(vertex)/\(fragment)")
            }
            d.vertexFunction = v
            d.fragmentFunction = f
            // Newer SDKs: colorAttachments[0] is optional.
            guard let color0 = d.colorAttachments[0] else {
                preconditionFailure("MTTerrainRenderer: color attachment 0 missing")
            }
            color0.pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            if blending {
                let a = color0
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return d
        }
        do {
            terrainPipeline = try device.makeRenderPipelineState(
                descriptor: descriptor(vertex: "terrain_vertex", fragment: "terrain_fragment", blending: false))
            waterPipeline = try device.makeRenderPipelineState(
                descriptor: descriptor(vertex: "terrain_vertex", fragment: "water_fragment", blending: true))
            structurePipeline = try device.makeRenderPipelineState(
                descriptor: descriptor(vertex: "structure_vertex", fragment: "structure_fragment", blending: false))
        } catch {
            preconditionFailure("MTTerrainRenderer: pipeline creation failed: \(error)")
        }
    }

    /// Metal 4 fast path (iOS 26+ / macOS 26+, Apple Silicon only).
    /// Compiles the same shaders through `MTL4Compiler` (dedicated
    /// compilation context, shared Metal IR) instead of the device.
    /// Best-effort: any failure returns false and the caller falls back
    /// to the Metal 3 path.
    ///
    /// Compiled only on arm64: Metal 4 requires Apple Silicon GPUs.
    /// Intel Macs don't have the MTL4* types in their SDK, so the
    /// `#if arch(arm64)` gate keeps this file compiling there.
    /// API names verified against Apple's metal-cpp headers (MTL4Compiler,
    /// MTL4RenderPipelineDescriptor, MTL4LibraryFunctionDescriptor).
    #if arch(arm64)
    @available(iOS 26, macOS 26, *)
    private func buildMetal4Pipelines(library: MTLLibrary) -> Bool {
        do {
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            terrainPipeline = try metal4Pipeline(compiler: compiler, library: library,
                                                 vertex: "terrain_vertex",
                                                 fragment: "terrain_fragment",
                                                 blending: false)
            waterPipeline = try metal4Pipeline(compiler: compiler, library: library,
                                               vertex: "terrain_vertex",
                                               fragment: "water_fragment",
                                               blending: true)
            structurePipeline = try metal4Pipeline(compiler: compiler, library: library,
                                                   vertex: "structure_vertex",
                                                   fragment: "structure_fragment",
                                                   blending: false)
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26, macOS 26, *)
    private func metal4Pipeline(compiler: MTL4Compiler,
                                library: MTLLibrary,
                                vertex: String,
                                fragment: String,
                                blending: Bool) throws -> MTLRenderPipelineState {
        let vDesc = MTL4LibraryFunctionDescriptor()
        vDesc.library = library
        vDesc.name = vertex
        let fDesc = MTL4LibraryFunctionDescriptor()
        fDesc.library = library
        fDesc.name = fragment

        let d = MTL4RenderPipelineDescriptor()
        d.vertexFunctionDescriptor = vDesc
        d.fragmentFunctionDescriptor = fDesc
        d.inputPrimitiveTopology = .triangle
        guard let color = d.colorAttachments[0] else {
            preconditionFailure("MTTerrainRenderer: Metal 4 color attachment 0 missing")
        }
        color.pixelFormat = .bgra8Unorm
        if blending {
            color.blendingState = .enabled
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .sourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        // NOTE: Metal 4 specializes depth/stencil formats per render pass at
        // encode time; MTL4RenderPipelineDescriptor carries no depth pixel
        // format. Depth testing still comes from the encoder's
        // depthStencilState + the MTKView's depth attachment.
        return try compiler.makeRenderPipelineState(descriptor: d, compilerTaskOptions: nil)
    }
    #endif

    private func buildDepthStates() {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        guard let s = device.makeDepthStencilState(descriptor: d) else {
            preconditionFailure("MTTerrainRenderer: depth stencil state creation failed")
        }
        depthState = s

        let w = MTLDepthStencilDescriptor()
        w.depthCompareFunction = .less
        w.isDepthWriteEnabled = false   // transparent water: test, don't write
        guard let ws = device.makeDepthStencilState(descriptor: w) else {
            preconditionFailure("MTTerrainRenderer: water depth stencil state creation failed")
        }
        waterDepthState = ws
    }

    // MARK: Uniforms

    private func buildUniformBuffer() {
        let length = uniformStrideAligned * maxFramesInFlight * slotsPerFrame
        guard let buf = device.makeBuffer(length: length, options: .storageModeShared) else {
            preconditionFailure("MTTerrainRenderer: uniform buffer allocation failed")
        }
        uniformBuffer = buf
    }

    private func writeUniforms(slot: Int, model: simd_float4x4, time: Float) {
        let cfg = world.config
        let density = fogEnabled ? cfg.fogDensity : 0
        // Sun direction from azimuth/elevation (degrees).
        let az = sunAzimuth * .pi / 180
        let el = sunElevation * .pi / 180
        let sunDir = SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az))
        let u = MTUniforms(
            viewProj: viewProj,
            model: model,
            cameraPos: SIMD4<Float>(cameraPos, 1),
            fogColor: SIMD4<Float>(cfg.fogColor, density),
            lightDir: SIMD4<Float>(normalize(sunDir), 0.38),
            misc: SIMD4<Float>(time, shaderEffectsEnabled ? 1 : 0, 0, 0)
        )
        var copy = u
        let dst = uniformBuffer.contents().advanced(by: slot * uniformStrideAligned)
        dst.copyMemory(from: &copy, byteCount: uniformStride)
    }

    private func bindUniforms(_ encoder: MTLRenderCommandEncoder, slot: Int) {
        encoder.setVertexBuffer(uniformBuffer, offset: slot * uniformStrideAligned, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: slot * uniformStrideAligned, index: 1)
    }

    // MARK: Chunk streaming

    private func buildChunkAsync(_ coord: MTChunkCoord, cameraTarget: SIMD2<Float>) {
        // Capture the generation: if caches were invalidated while this
        // build was in flight, the mesh is stale — drop it.
        cacheLock.lock()
        let generation = buildGeneration
        cacheLock.unlock()
        buildQueue.async { [weak self] in
            guard let self = self else { return }
            let size = self.world.config.chunkWorldSize
            let cx = (Float(coord.x) + 0.5) * size
            let cz = (Float(coord.z) + 0.5) * size
            let dist = hypot(cx - cameraTarget.x, cz - cameraTarget.y)
            let distanceFactor = dist / (Float(self.world.config.viewDistance) * size)
            // LOD: far chunks generate at half resolution (4x fewer noise evals).
            let resScale: Float = distanceFactor > 0.4 ? 0.5 : 1.0
            let chunk = self.world.generateChunk(at: coord, resolutionScale: resScale)
            let mesh = MTMeshBuilder.buildLOD(for: chunk, world: self.world,
                                              distanceFactor: distanceFactor)
            guard let vb = self.sharedBuffer(from: mesh.vertices),
                  let ib = self.sharedBuffer(from: mesh.indices) else {
                self.cacheLock.lock()
                self.pendingBuilds.remove(coord)
                self.cacheLock.unlock()
                return
            }
            self.cacheLock.lock()
            // Drop stale builds: config changed while we were generating.
            if generation == self.buildGeneration {
                // AABB for frustum culling: chunk XZ extent, Y from min/max height.
                let minH = chunk.heights.min() ?? 0
                let maxH = chunk.heights.max() ?? 1
                let y0 = self.world.worldY(forHeight: minH)
                let y1 = self.world.worldY(forHeight: maxH)
                let x0 = Float(coord.x) * size
                let z0 = Float(coord.z) * size
                self.chunkCache[coord] = ChunkMesh(
                    vertexBuffer: vb,
                    indexBuffer: ib,
                    indexCount: mesh.indices.count,
                    lastUsed: Date().timeIntervalSince1970,
                    boundsMin: SIMD3<Float>(x0, min(y0, y1) - 20, z0),
                    boundsMax: SIMD3<Float>(x0 + size, max(y0, y1) + 20, z0 + size))
            }
            self.pendingBuilds.remove(coord)
            self.cacheLock.unlock()
        }
    }

    private func sharedBuffer<T>(from array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { ptr in
            // MTLBuffer creation is thread-safe; safe on the build queue.
            device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count,
                              options: .storageModeShared)
        }
    }

    private func invalidateCaches() {
        cacheLock.lock()
        chunkCache.removeAll()
        pendingBuilds.removeAll()
        buildGeneration &+= 1
        cacheLock.unlock()
        structureChunkSet = []
        clearStructureInstances()
    }

    // MARK: Water

    private func buildWaterMesh() {
        let cfg = world.config
        let size = Float(cfg.viewDistance * 2 + 4) * cfg.chunkWorldSize
        let level = world.worldY(forHeight: cfg.seaLevel)
        let mesh = MTMeshBuilder.buildWaterMesh(size: size, level: level,
                                                color: cfg.waterColor)
        waterVertexBuffer = sharedBuffer(from: mesh.vertices)
        waterIndexBuffer = sharedBuffer(from: mesh.indices)
        waterIndexCount = mesh.indices.count
    }

    // MARK: Structures

    private func loadStructureMeshes() {
        // Calls into the sibling Structures module (see MTMeshBuilder).
        let built = MTMeshBuilder.buildStructureMeshes()
        for (kind, mesh) in built {
            guard let vb = sharedBuffer(from: mesh.vertices),
                  let ib = sharedBuffer(from: mesh.indices) else { continue }
            structureMeshes[kind] = StructureMesh(vertexBuffer: vb,
                                                  indexBuffer: ib,
                                                  indexCount: mesh.indices.count,
                                                  instanceBuffer: nil,
                                                  instanceCount: 0)
        }
    }

    /// Rebuilds per-kind instance buffers (model matrix + tint) for the
    /// currently visible chunks. The expensive placement queries run on the
    /// background build queue; only the buffer swap happens on main.
    /// Called only when the visible chunk set changes, not every frame.
    private func rebuildStructureInstances(visible: Set<MTChunkCoord>) {
        let world = self.world
        // Capture the generation: drop results if config changed mid-build.
        cacheLock.lock()
        let generation = buildGeneration
        cacheLock.unlock()
        buildQueue.async { [weak self] in
            guard let self = self else { return }
            var perKind: [MTStructureKind: [MTInstanceData]] = [:]
            // Sort for deterministic instance-buffer order: Swift Set
            // iteration is randomized per run, which would make
            // "same seed = same bytes" false at the buffer level.
            for coord in visible.sorted() {
                for placement in world.structures(in: coord) {
                    let model = mtTranslation(placement.position)
                        * mtRotationY(placement.rotationY)
                        * mtUniformScale(placement.scale)
                    perKind[placement.kind, default: []].append(
                        MTInstanceData(model: model,
                                       tint: SIMD4<Float>(1, 1, 1, 1)))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cacheLock.lock()
                let fresh = (generation == self.buildGeneration)
                self.cacheLock.unlock()
                guard fresh else { return }
                for kind in MTStructureKind.allCases {
                    guard var sm = self.structureMeshes[kind] else { continue }
                    let list = perKind[kind] ?? []
                    sm.instanceCount = list.count
                    sm.instanceBuffer = list.isEmpty ? nil : self.sharedBuffer(from: list)
                    self.structureMeshes[kind] = sm
                }
            }
        }
    }

    private func clearStructureInstances() {
        for kind in structureMeshes.keys {
            structureMeshes[kind]?.instanceBuffer = nil
            structureMeshes[kind]?.instanceCount = 0
        }
    }
}
