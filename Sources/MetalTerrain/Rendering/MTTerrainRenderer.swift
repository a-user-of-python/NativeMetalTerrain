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
/// Uniform block uploaded per frame. 224 bytes, all 16-byte aligned.
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
    var seaLevel: SIMD4<Float>   // x = normalized sea level (0...1)
    var sunColor: SIMD4<Float>   // rgb = sun tint, w = unused
}

/// Must match `MTInstanceData` in MTShaders.metal (80 bytes).
private struct MTInstanceData {
    var model: simd_float4x4
    var tint: SIMD4<Float>  // rgb = color tint
}

/// Must match `MTWaterParams` in MTShaders.metal (48 bytes: 3x float4).
/// Uses SIMD4 packing to match Metal's float3+float 16-byte alignment.
private struct MTWaterParams {
    var deepAndSpeed: SIMD4<Float>    // rgb = deep color, w = wave speed
    var shallowAndAmp: SIMD4<Float>   // rgb = shallow color, w = wave amplitude
    var opacityAndPad: SIMD4<Float>   // x = opacity, yzw = padding
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
        didSet {
            invalidateCaches()
            #if M3_FEATURES
            rebuildBiomeTable()
            #endif
        }
    }

    public var wireframe: Bool = false
    public var showsWater: Bool = true
    public var fogEnabled: Bool = true
    /// Water deep color (linear RGB). Updates the water params buffer.
    public var waterDeepColor: SIMD3<Float> = SIMD3<Float>(0.01, 0.22, 0.35) {
        didSet { updateWaterParams() }
    }
    /// Water shallow color (linear RGB). Updates the water params buffer.
    public var waterShallowColor: SIMD3<Float> = SIMD3<Float>(0.15, 0.55, 0.65) {
        didSet { updateWaterParams() }
    }
    /// Water wave animation speed multiplier (0...3). Updates the water params buffer.
    public var waveSpeed: Float = 1.0 {
        didSet { waveSpeed = min(max(0, waveSpeed), 3); updateWaterParams() }
    }
    /// Water wave normal strength multiplier (0...2). Updates the water params buffer.
    public var waveAmplitude: Float = 1.0 {
        didSet { waveAmplitude = min(max(0, waveAmplitude), 2); updateWaterParams() }
    }
    /// Water opacity (0...1). Multiplied with the alpha buffer. Updates the water params buffer.
    public var waterOpacity: Float = 0.82 {
        didSet { waterOpacity = min(max(0, waterOpacity), 1); updateWaterParams() }
    }
    /// Sun position: azimuth (0-360°, direction) and elevation (0-90°, height).
    public var sunAzimuth: Float = 45
    public var sunElevation: Float = 50
    /// Time of day in hours (0...24). When `timeOfDayEnabled` is true, the
    /// renderer advances this automatically and drives `sunAzimuth`,
    /// `sunElevation` and `sunColor` from it. Default 12 (noon).
    public var timeOfDay: Float = 12 {
        didSet {
            timeOfDay = min(max(0, timeOfDay), 24)
            if timeOfDayEnabled { applyTimeOfDay() }
        }
    }
    /// When true, `update(cameraTarget:)` advances `timeOfDay` every frame
    /// and overrides the sun position/color. Default false: manual
    /// `sunAzimuth`/`sunElevation` control keeps working as before.
    public var timeOfDayEnabled: Bool = false {
        didSet {
            if timeOfDayEnabled {
                applyTimeOfDay()
            } else {
                // v1.1.3: clear fog override when time animation is off.
                fogColorOverride = nil
            }
        }
    }
    /// Game-hours advanced per real minute (0...60). Default 1.0.
    public var timeOfDaySpeed: Float = 1.0 {
        didSet { timeOfDaySpeed = min(max(0, timeOfDaySpeed), 60) }
    }
    /// Sun tint (rgb) applied to terrain lighting. Updated automatically
    /// from `timeOfDay` when `timeOfDayEnabled`; settable manually otherwise.
    /// Default matches the previous hardcoded warm glint.
    public var sunColor: SIMD3<Float> = SIMD3<Float>(1.0, 0.98, 0.92)
    /// v1.1.3: when set, overrides cfg.fogColor (used by applyTimeOfDay).
    public var fogColorOverride: SIMD3<Float>?
    /// Last measured FPS (written by the demo's render loop, polled by UI).
    public var currentFPS: Double = 0
    /// GPU memory currently allocated by Metal, in MB (for stats overlay).
    public var gpuAllocatedMB: Double {
        Double(device.currentAllocatedSize) / 1_000_000
    }
    /// Enhanced shader effects (specular + fresnel). Default off.
    public var shaderEffectsEnabled: Bool = false
    /// Skybox (sky gradient + visible sun), drawn first each frame.
    /// Created by default; set to nil to disable. The sun position mirrors
    /// `sunAzimuth`/`sunElevation` automatically.
    public var skybox: MTSkybox?
    /// Re-enables the skybox after it was set to nil. Creates a new MTSkybox
    /// with the current device.
    public func enableSkybox() {
        if skybox == nil {
            skybox = MTSkybox(device: device)
        }
    }
    /// Cloud coverage amount, 0...1 (0 = clear, 1 = overcast). Default 0.4.
    /// Forwards to the skybox; also synced every frame in drawScene so it
    /// stays correct even if the skybox was recreated via enableSkybox().
    public var cloudAmount: Float = 0.4
    /// Whether stars render at night. Default true. Forwards to the skybox.
    public var starsEnabled: Bool = true

    // MARK: - Time of day

    /// Advances the time-of-day clock by `dt` seconds and maps it onto the
    /// sun position/color. Called automatically from `update(cameraTarget:)`;
    /// no-op unless `timeOfDayEnabled` is true.
    public func updateTimeOfDay(dt: Float) {
        guard timeOfDayEnabled, dt > 0 else { return }
        // timeOfDaySpeed is game-hours per real minute.
        timeOfDay = (timeOfDay + dt * timeOfDaySpeed / 60.0).truncatingRemainder(dividingBy: 24.0)
        // didSet on timeOfDay calls applyTimeOfDay() when enabled.
    }

    /// Maps the current `timeOfDay` onto `sunAzimuth`, `sunElevation` and
    /// `sunColor`. Public so apps can set `timeOfDay` manually and apply it.
    ///   6h = sunrise (az 90°, el 0°) · 12h = noon (az 180°, el 70°)
    ///   18h = sunset (az 270°, el 0°) · 0h = midnight (el -30°)
    public func applyTimeOfDay() {
        let t = timeOfDay
        // Azimuth sweeps 15°/hour: east at 6h, south at 12h, west at 18h.
        sunAzimuth = (90 + (t - 6) * 15).truncatingRemainder(dividingBy: 360)
        if sunAzimuth < 0 { sunAzimuth += 360 }
        // Elevation: sine arc, +70° at noon, -30° at midnight.
        let s = sin(2 * Float.pi * (t - 6) / 24)
        sunElevation = s >= 0 ? s * 70 : s * 30
        sunColor = Self.sunColorForElevation(sunElevation)
        // v1.1.3: fog follows the sky — dark at night, warm at dusk.
        fogColorOverride = Self.fogColorForElevation(sunElevation)
        // The skybox reads sunElevation every frame (day/dusk/night
        // gradients), so it follows automatically.
    }

    /// Fog color for a given sun elevation: light blue at day, warm at
    /// dusk, dark blue-black at night.
    public static func fogColorForElevation(_ elevation: Float) -> SIMD3<Float> {
        let day = SIMD3<Float>(0.65, 0.75, 0.85)   // light blue
        let dusk = SIMD3<Float>(0.85, 0.55, 0.45)  // warm orange-pink
        let night = SIMD3<Float>(0.02, 0.03, 0.06)  // dark blue-black
        let smooth: (Float) -> Float = { x in
            let c = min(max(x, 0), 1)
            return c * c * (3 - 2 * c)
        }
        if elevation >= 0 {
            let k = smooth(elevation / 70)
            // Blend dusk -> day as sun rises
            let lowElev = SIMD3<Float>(0.75, 0.6, 0.55)
            if elevation < 15 {
                return dusk + (lowElev - dusk) * smooth(elevation / 15)
            }
            return lowElev + (day - lowElev) * smooth((elevation - 15) / 55)
        } else {
            let k = smooth(-elevation / 30)
            return dusk + (night - dusk) * k
        }
    }

    /// Sun tint for a given elevation in degrees: warm orange at the
    /// horizon, white at noon, cool moonlight below the horizon.
    public static func sunColorForElevation(_ elevation: Float) -> SIMD3<Float> {
        let warm = SIMD3<Float>(1.0, 0.6, 0.4)
        let noon = SIMD3<Float>(1.0, 0.98, 0.95)
        let night = SIMD3<Float>(0.3, 0.4, 0.6)
        let smooth: (Float) -> Float = { x in
            let c = min(max(x, 0), 1)
            return c * c * (3 - 2 * c)
        }
        if elevation >= 0 {
            let k = smooth(elevation / 70)
            return warm + (noon - warm) * k
        } else {
            let k = smooth(-elevation / 30)
            return warm + (night - warm) * k
        }
    }
    /// Hardware ray-traced shadow acceleration structures (M3+/A17 Pro+).
    /// Nil when the device lacks hardware ray tracing or the build omits
    /// the M3_FEATURES compilation condition. Created in `init`; the TLAS
    /// is refreshed in `update(cameraTarget:)` as chunks stream.
    public var rayTracing: MTRayTracing?
    /// Render distance in chunks (radius). Changing this updates the world
    /// config, which triggers a cache invalidation and rebuild.
    public var viewDistance: Int {
        get { viewDistanceOverride ?? world.config.viewDistance }
        set {
            // Don't touch world.config here: that bumps configVersion which
            // invalidates the entire chunk cache (world regenerates).
            // Just update the override; update() picks up the new radius
            // and streams the additional chunks without dropping existing ones.
            let clamped = min(max(1, newValue), 10)
            if viewDistanceOverride != clamped {
                viewDistanceOverride = clamped
                // Water mesh size depends on viewDistance; rebuild it.
                // Chunk cache is NOT invalidated — existing chunks stay.
                buildWaterMesh()
            }
        }
    }
    /// Local override for viewDistance. When nil, uses world.config.viewDistance.
    private var viewDistanceOverride: Int?
    /// Wall-clock time of the last `update(cameraTarget:)` call, for the
    /// time-of-day clock delta.
    private var lastUpdateTime: Double?

    public init(device: MTLDevice, world: MTTerrainWorld, metalVersionOverride: MetalAPIVersion? = nil) {
        self.device = device
        self.world = world
        self.metalVersionOverride = metalVersionOverride
        guard let queue = device.makeCommandQueue() else {
            preconditionFailure("MTTerrainRenderer: device.makeCommandQueue() failed")
        }
        self.commandQueue = queue
        self.uniformStride = MemoryLayout<MTUniforms>.stride
        precondition(uniformStride == 224, "MTUniforms layout drifted from MTShaders.metal")
        // Metal requires buffer offsets bound via setVertexBuffer/setFragmentBuffer
        // to be multiples of 256. MTUniforms is 192 bytes, so pad the stride.
        self.uniformStrideAligned = (uniformStride + 255) & ~255

        buildPipelines()
        buildDepthStates()
        buildUniformBuffer()
        buildWaterMesh()
        // Initialize water params from world config.
        waterDeepColor = world.config.waterDeepColor
        waterShallowColor = world.config.waterShallowColor
        waveSpeed = world.config.waveSpeed
        waveAmplitude = world.config.waveAmplitude
        waterOpacity = world.config.waterOpacity
        buildWaterParamsBuffer()
        // v1.2.5: GPU heightmap generation. Nil when the kernel is
        // unavailable — the world then uses the CPU path in generateChunk.
        world.heightmapCompute = MTHeightmapCompute(device: device)
        // v1.2.6: GPU mesh building (padded heightmap -> packed vertices,
        // no CPU roundtrip). Nil on failure — buildChunkAsync falls back
        // to the CPU MTMeshBuilder path.
        if let hc = world.heightmapCompute {
            meshCompute = MTMeshCompute(device: device, heightmap: hc)
        }
        loadStructureMeshes()
        // v1.3.0: volcano lava particles (seeded with the world seed).
        lava = MTLavaParticles(seed: world.seed)
        // v1.3.0: warm the volcano cache off the main thread — detection
        // does ~2K noise evals; don't hitch the first frame.
        let w = world
        DispatchQueue.global(qos: .utility).async { _ = w.volcanoVents }
        // Skybox works on all devices (standard Metal 3).
        self.skybox = MTSkybox(device: device)
        #if M3_FEATURES
        // Ray tracing: hardware only, M3+/A17 Pro+. Nil on older GPUs.
        let rt = MTRayTracing(device: device)
        rayTracing = rt.isSupported ? rt : nil
        precondition(MemoryLayout<MTMeshChunkParams>.stride == 40,
                     "MTMeshChunkParams layout drifted from MTMeshShaders.metal")
        precondition(MemoryLayout<MTMeshBiomeGPU>.stride == 48,
                     "MTMeshBiomeGPU layout drifted from MTMeshShaders.metal")
        rebuildBiomeTable()
        #endif
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
        // Time-of-day clock: advances even when the camera is still, so it
        // runs before the early-return below.
        let now = Date().timeIntervalSince1970
        if let last = lastUpdateTime {
            updateTimeOfDay(dt: Float(now - last))
        }
        lastUpdateTime = now
        // v1.3.0: advance volcano lava simulation (cheap when no volcanoes).
        if let lava = lava {
            let ldt: Float
            if let lastLava = lastLavaTime {
                ldt = Float(now - lastLava)
            } else {
                ldt = 1.0 / 60.0
            }
            lastLavaTime = now
            lava.update(dt: ldt, world: world, cameraTarget: cameraTarget)
        }
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
        let radius = viewDistance
        let center = MTChunkCoord(x: Int(floor(cameraTarget.x / size)),
                                  z: Int(floor(cameraTarget.y / size)))

        // Fast path: if the camera hasn't crossed a chunk boundary AND the
        // view distance hasn't changed, the needed set is identical — skip
        // the Set rebuild, eviction scan, and dispatch loop entirely.
        // (update() runs 60x/sec; this work is only needed on movement
        // or viewDistance change.)
        if center == lastCenter && radius == lastRadius {
            return
        }
        lastCenter = center
        lastRadius = radius

        var needed = Set<MTChunkCoord>()
        needed.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
        for dz in -radius...radius {
            for dx in -radius...radius {
                needed.insert(MTChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }

        // v1.1.0: reuse `now` from above (single timestamp per frame).
        var toBuild: [MTChunkCoord] = []
        cacheLock.lock()
        // Evict anything well outside the view radius (+1 chunk buffer).
        // Keeps the previous ring alive while new chunks build, preventing
        // see-through holes during fast movement.
        for coord in chunkCache.keys where Self.chebyshev(coord, center) > radius + 1 {
            chunkCache.removeValue(forKey: coord)
        }
        // LRU cap: never hold more than the visible square plus the 1-chunk
        // eviction buffer, with an absolute ceiling so a large viewDistance
        // can't exhaust iPad memory.
        let cap = min((2 * (radius + 1) + 1) * (2 * (radius + 1) + 1), Self.maxChunkCacheSize)
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

        // Build nearest chunks first: the chunk under the camera should
        // appear immediately, not after a random Set ordering. Zero visual
        // change, large perceived improvement.
        let cx = Float(center.x) * size
        let cz = Float(center.z) * size
        toBuild.sort {
            let dx0 = Float($0.x) * size - cx, dz0 = Float($0.z) * size - cz
            let dx1 = Float($1.x) * size - cx, dz1 = Float($1.z) * size - cz
            return dx0*dx0 + dz0*dz0 < dx1*dx1 + dz1*dz1
        }
        for coord in toBuild {
            buildChunkAsync(coord, cameraTarget: cameraTarget)
        }

        #if M3_FEATURES
        // Refresh the ray-tracing TLAS from the currently cached chunk
        // meshes. Throttled to every 15 frames to avoid lag spikes during
        // streaming (TLAS rebuilds are expensive with full-res chunks).
        // MTRayTracing skips the rebuild when the chunk set is unchanged.
        tlasFrameCounter += 1
        if let rt = rayTracing, tlasFrameCounter % 15 == 0 {
            cacheLock.lock()
            let rtChunks = chunkCache.map { (coord, mesh) in
                (id: coord.hashValue,
                 vertexBuffer: mesh.vertexBuffer,
                 indexBuffer: mesh.indexBuffer,
                 indexCount: mesh.indexCount,
                 transform: matrix_identity_float4x4)
            }
            cacheLock.unlock()
            rt.update(chunks: rtChunks)
        }
        #endif

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
    /// - Parameter overlay: Optional closure called with the render encoder
    ///   after the terrain is drawn but before the encoder ends. Use this to
    ///   draw app-level objects (like a debug car) in the SAME render pass,
    ///   avoiding the synchronization issues of a second pass.
    public func draw(in view: MTKView, overlay: ((MTLRenderCommandEncoder) -> Void)? = nil) {
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

        drawScene(encoder: encoder, viewProj: viewProj, cameraPos: cameraPos,
                  terrainSlot: terrainSlot, waterSlot: waterSlot, time: time,
                  includeStructures: true, includeWater: true)

        // App overlay (e.g. debug car) draws in the same pass, after terrain.
        overlay?(encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders the scene (skybox + terrain) into an offscreen texture from
    /// an arbitrary camera. Used for real-time mirror reflections — call
    /// with a low-resolution texture (e.g. 256x128) for performance.
    /// Structures and water are skipped for speed; the mirror image is small.
    public func renderReflection(to texture: MTLTexture,
                                 from cameraPosition: SIMD3<Float>,
                                 lookingAt target: SIMD3<Float>,
                                 fovDegrees: Float = 70) {
        let w = texture.width, h = texture.height
        guard w > 0 && h > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Depth texture for the reflection pass — cached and reused;
        // only recreated when the reflection target size changes.
        if reflectionDepthTexture == nil ||
            reflectionDepthSize.width != w || reflectionDepthSize.height != h {
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            depthDesc.storageMode = .private
            depthDesc.usage = .renderTarget
            reflectionDepthTexture = device.makeTexture(descriptor: depthDesc)
            reflectionDepthSize = (w, h)
        }
        guard let depthTex = reflectionDepthTexture else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.15, blue: 0.25, alpha: 1)
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Mirror camera: aspect from texture dimensions.
        let aspect = Float(w) / Float(max(h, 1))
        let mirrorViewProj = mtPerspective(fovDegrees: fovDegrees, aspect: aspect,
                                           near: 1, far: 20000)
            * mtLookAt(eye: cameraPosition, target: target)

        // Use a dedicated uniform slot (beyond the frame slots) so the
        // reflection pass doesn't disturb the main render state.
        // includeSky: false — the reflection target is tiny (e.g. 256x128
        // for car mirrors); sky detail (clouds, stars) is invisible there.
        let reflectionSlot = maxFramesInFlight * slotsPerFrame
        let time = Float(Date().timeIntervalSince(startTime))
        drawScene(encoder: encoder, viewProj: mirrorViewProj, cameraPos: cameraPosition,
                  terrainSlot: reflectionSlot, waterSlot: reflectionSlot + 1, time: time,
                  includeStructures: false, includeWater: false, includeSky: false)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Core scene rendering: skybox, terrain chunks, optionally structures
    /// and water. Shared by `draw(in:)` and `renderReflection(to:from:)`.
    /// - Parameter includeSky: when false, skips the skybox draw (used by
    ///   the reflection pass, where the tiny target makes sky detail invisible).
    private func drawScene(encoder: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           cameraPos: SIMD3<Float>,
                           terrainSlot: Int, waterSlot: Int, time: Float,
                           includeStructures: Bool, includeWater: Bool,
                           includeSky: Bool = true) {
        writeUniforms(slot: terrainSlot, model: matrix_identity_float4x4, time: time,
                       viewProj: viewProj, cameraPos: cameraPos)
        // Water plane is built around the XZ origin; recenter it under the camera.
        // Snap to the water grid (size/64) so vertices align to stable world
        // positions — prevents shoreline swimming/jitter as the camera moves.
        let waterSize = Float(viewDistance * 2 + 4) * world.config.chunkWorldSize
        let waterGrid = waterSize / 64.0
        let snappedX = (lastCameraTarget.x / waterGrid).rounded() * waterGrid
        let snappedZ = (lastCameraTarget.y / waterGrid).rounded() * waterGrid
        writeUniforms(slot: waterSlot,
                      model: mtTranslation(SIMD3<Float>(snappedX, 0, snappedZ)),
                      time: time, viewProj: viewProj, cameraPos: cameraPos)

        encoder.setDepthStencilState(depthState)
        // Wireframe is now a smooth animated overlay in the fragment shader
        // (not .lines fill mode, which looked blocky/Lego-like).
        encoder.setTriangleFillMode(.fill)
        encoder.setCullMode(.back)

        // Skybox FIRST: fullscreen sky + sun at the far plane, no depth
        // writes. Terrain drawn afterward occludes it with normal depth.
        // (Skybox sets its own depth/cull state; terrain state is set above
        // and re-applied below, so wireframe mode never affects the sky.)
        // Skipped when includeSky is false (reflection pass).
        if includeSky, let skybox = skybox {
            skybox.sunAzimuth = self.sunAzimuth
            skybox.sunElevation = self.sunElevation
            skybox.cloudAmount = self.cloudAmount
            skybox.starsEnabled = self.starsEnabled
            skybox.draw(encoder: encoder, viewProjection: viewProj,
                        cameraPos: cameraPos, time: time)
            encoder.setDepthStencilState(depthState)
            encoder.setTriangleFillMode(.fill)
            encoder.setCullMode(.back)
        }

        // 1 draw call per chunk. Iterate under the lock instead of
        // copying to an Array every frame (was a 60fps allocation).
        // Frustum culling: skip chunks outside the camera view.
        let frustum = Frustum(viewProj: viewProj)
        #if M3_FEATURES
        if meshShadingActive {
            drawChunksMeshShading(encoder: encoder, slot: terrainSlot,
                                  frustum: frustum)
        } else {
            drawChunksStandard(encoder: encoder, slot: terrainSlot,
                               frustum: frustum)
        }
        #else
        encoder.setRenderPipelineState(terrainPipeline)
        bindUniforms(encoder, slot: terrainSlot)
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
        #endif

        // 1 instanced draw per structure kind (skipped for reflections).
        // Structures use no culling: some generated triangles may have
        // inconsistent winding, and double-sided is safer than invisible.
        if includeStructures {
            encoder.setCullMode(.none)
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
            encoder.setCullMode(.back)  // restore for water/terrain
        }

        // v1.3.0: volcano lava billboards (additive, emissive).
        // Skipped for reflections; depth-tested but doesn't write depth.
        if includeStructures, let lavaPipeline = lavaPipeline,
           let lava = lava {
            let instances = lava.renderInstances()
            if !instances.isEmpty {
                // Reusable instance buffer (avoids per-frame allocation).
                let need = instances.count * 32
                if lavaInstanceBuffer == nil
                    || (lavaInstanceBuffer?.length ?? 0) < need {
                    lavaInstanceBuffer = device.makeBuffer(
                        length: 260 * 32, options: .storageModeShared)
                }
                if let ib = lavaInstanceBuffer {
                    let ptr = ib.contents().assumingMemoryBound(to: SIMD4<Float>.self)
                    for (idx, inst) in instances.enumerated() {
                        ptr[idx * 2] = SIMD4<Float>(inst.position, inst.size)
                        ptr[idx * 2 + 1] = SIMD4<Float>(inst.kind, inst.heat, 0, 0)
                    }
                    encoder.setRenderPipelineState(lavaPipeline)
                    encoder.setDepthStencilState(waterDepthState)
                    bindUniforms(encoder, slot: terrainSlot)
                    encoder.setVertexBuffer(ib, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip,
                                           vertexStart: 0, vertexCount: 4,
                                           instanceCount: instances.count)
                    // Restore state for water.
                    encoder.setDepthStencilState(depthState)
                    encoder.setCullMode(.back)
                }
            }
        }

        // 1 draw for water, blended, drawn last (skipped for reflections).
        if includeWater, showsWater, let wvb = waterVertexBuffer, let wib = waterIndexBuffer {
            encoder.setRenderPipelineState(waterPipeline)
            encoder.setDepthStencilState(waterDepthState)
            bindUniforms(encoder, slot: waterSlot)
            // v1.1.0: alpha buffer(2) removed — opacity comes from waterParams.
            if let wpb = waterParamsBuffer {
                encoder.setFragmentBuffer(wpb, offset: 0, index: 3)
            }
            encoder.setVertexBuffer(wvb, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: waterIndexCount,
                                          indexType: .uint32,
                                          indexBuffer: wib,
                                          indexBufferOffset: 0)
        }
    }

    /// Standard-path chunk drawing: one indexed draw per visible chunk.
    private func drawChunksStandard(encoder: MTLRenderCommandEncoder,
                                    slot: Int, frustum: Frustum) {
        #if M3_FEATURES
        // Use the ray-traced shadow pipeline when the TLAS is ready.
        let tlas = rayTracing?.topLevelStructure
        let pipeline: MTLRenderPipelineState = (tlas != nil) ? (terrainPipelineRT ?? terrainPipeline)
                                                             : terrainPipeline
        #else
        let pipeline: MTLRenderPipelineState = terrainPipeline
        #endif
        encoder.setRenderPipelineState(pipeline)
        bindUniforms(encoder, slot: slot)
        #if M3_FEATURES
        // Bind the TLAS for the shadow pass at fragment buffer index 3.
        // The RT fragment variant reads it; terrain_fragment ignores it.
        if let tlas = tlas {
            encoder.setFragmentAccelerationStructure(tlas, bufferIndex: 3)
        }
        #endif
        cacheLock.lock()
        for mesh in chunkCache.values {
            guard frustum.intersects(min: mesh.boundsMin, max: mesh.boundsMax)
            else { continue }
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: mesh.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: mesh.indexBuffer,
                                          indexBufferOffset: 0)
        }
        cacheLock.unlock()
    }

    #if M3_FEATURES
    /// Mesh-shading chunk pass: one `drawMeshThreadgroups` per visible chunk.
    /// The object shader culls and sizes the tile grid; the mesh shader
    /// expands the chunk's heightmap into vertices on-GPU.
    private func drawChunksMeshShading(encoder: MTLRenderCommandEncoder,
                                       slot: Int, frustum: Frustum) {
        guard let pipeline = meshShadingPipelineState else {
            drawChunksStandard(encoder: encoder, slot: slot, frustum: frustum)
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(uniformBuffer,
                                  offset: slot * uniformStrideAligned, index: 1)
        encoder.setObjectBuffer(uniformBuffer,
                                offset: slot * uniformStrideAligned, index: 1)
        encoder.setMeshBuffer(biomeTableBuffer, offset: 0, index: 1)
        var biomeCount = UInt32(biomeTable.count)
        encoder.setMeshBytes(&biomeCount,
                             length: MemoryLayout<UInt32>.stride, index: 2)
        let cfg = world.config
        cacheLock.lock()
        for (coord, mesh) in chunkCache {
            guard frustum.intersects(min: mesh.boundsMin, max: mesh.boundsMax),
                  let heightmap = mesh.heightmapBuffer else { continue }
            var params = MTMeshChunkParams(
                chunkOrigin: SIMD2<Float>(Float(coord.x) * cfg.chunkWorldSize,
                                          Float(coord.z) * cfg.chunkWorldSize),
                worldSize: cfg.chunkWorldSize,
                heightScale: cfg.heightScale,
                resolution: Float(mesh.heightmapResolution),
                lodStride: mesh.lodStride,
                minY: mesh.boundsMin.y,
                maxY: mesh.boundsMax.y,
                pad: SIMD2<Float>(0, 0))
            encoder.setObjectBytes(&params,
                                   length: MemoryLayout<MTMeshChunkParams>.stride,
                                   index: 0)
            encoder.setMeshBuffer(heightmap, offset: 0, index: 0)
            encoder.drawMeshThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
                threadsPerMeshThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
        }
        cacheLock.unlock()
    }
    #endif

    // MARK: - Metal 4 detection

    /// True when the Metal 4 pipeline path was taken (iOS 26+, device
    /// supports it, and compilation succeeded). Otherwise Metal 3.
    public private(set) var usesMetal4: Bool = false

    /// Force a specific Metal API version, or nil for auto-detect.
    /// Set before pipelines are built (takes effect on next rebuild).
    public var metalVersionOverride: MetalAPIVersion? = nil

    /// Metal API version selection.
    public enum MetalAPIVersion {
        case metal3
        case metal4
    }

    #if M3_FEATURES
    /// Mesh-shading pipeline (object + mesh + fragment). Nil when the GPU
    /// lacks mesh shading or compilation failed — falls back to standard.
    private var meshShadingPipelineState: MTLRenderPipelineState?
    /// Master switch for the mesh-shading path. Engages only when the build
    /// has M3_FEATURES, the GPU is Apple9+, and the pipeline compiled.
    public var meshShadingEnabled: Bool = true
    /// Constant biome color table for the mesh shader.
    private var biomeTableBuffer: MTLBuffer!
    private var biomeTable: [MTMeshBiomeGPU] = []

    /// True when the mesh-shading path can be used this frame.
    private var meshShadingActive: Bool {
        meshShadingEnabled
            && MTCapabilities.supportsMeshShading(device: device)
            && meshShadingPipelineState != nil
    }

    /// Must match `MTMeshChunkParams` in MTMeshShaders.metal (40 bytes).
    private struct MTMeshChunkParams {
        var chunkOrigin: SIMD2<Float>
        var worldSize: Float
        var heightScale: Float
        var resolution: Float
        var lodStride: Float
        var minY: Float
        var maxY: Float
        var pad: SIMD2<Float>
    }

    /// Must match `MTMeshBiome` in MTMeshShaders.metal (48 bytes).
    private struct MTMeshBiomeGPU {
        var groundAndMin: SIMD4<Float>
        var slopeAndMax: SIMD4<Float>
        var ids: SIMD4<Float>
    }

    /// Compiles the object/mesh/fragment pipeline. Best-effort and async:
    /// mesh-descriptor pipeline creation is async, so this returns
    /// immediately and the pipeline appears when compilation finishes —
    /// until then the standard path is used.
    private func buildMeshShadingPipelines(library: MTLLibrary) {
        guard MTCapabilities.supportsMeshShading(device: device),
              let objectFn = library.makeFunction(name: "mesh_terrain_object"),
              let meshFn = library.makeFunction(name: "mesh_terrain_mesh"),
              let fragmentFn = library.makeFunction(name: "mesh_terrain_fragment")
        else { meshShadingPipelineState = nil; return }
        let d = MTLMeshRenderPipelineDescriptor()
        d.objectFunction = objectFn
        d.meshFunction = meshFn
        d.fragmentFunction = fragmentFn
        guard let color0 = d.colorAttachments[0] else {
            meshShadingPipelineState = nil; return
        }
        color0.pixelFormat = .bgra8Unorm
        d.depthAttachmentPixelFormat = .depth32Float
        Task { [weak self, d] in
            guard let self else { return }
            do {
                let (pipeline, _) = try await self.device.makeRenderPipelineState(descriptor: d, options: [])
                self.meshShadingPipelineState = pipeline
            } catch {
                self.meshShadingPipelineState = nil
            }
        }
    }

    /// Packs the biome ladder (custom first, then config — same order as
    /// `biomeAt`) into the constant table the mesh shader colors with.
    private func buildBiomeTable(world: MTTerrainWorld) -> [MTMeshBiomeGPU] {
        var out: [MTMeshBiomeGPU] = []
        for biome in world.allBiomes.prefix(16) {
            let slope = biome.slopeColor ?? biome.groundColor
            let material: Float
            switch biome.name {
            case "deepOcean", "ocean": material = 5
            case "beach": material = 2
            case "mountain": material = 1
            case "snowyPeak": material = 3
            default: material = 0
            }
            out.append(MTMeshBiomeGPU(
                groundAndMin: SIMD4<Float>(biome.groundColor, biome.minHeight),
                slopeAndMax: SIMD4<Float>(slope, biome.maxHeight),
                ids: SIMD4<Float>(material,
                                  biome.emitsLight ? 1 : 0,
                                  biome.slopeColor != nil ? 1 : 0,
                                  biome.name == "snowyPeak" ? 1 : 0)))
        }
        return out
    }

    /// (Re)builds the mesh-shader biome table. Call from init and whenever
    /// the world or its biomes change.
    private func rebuildBiomeTable() {
        biomeTable = buildBiomeTable(world: world)
        biomeTableBuffer = biomeTable.withUnsafeBytes { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: max(ptr.count, 1),
                              options: .storageModeShared)!
        }
    }
    #endif

    // MARK: - Internals

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private var terrainPipeline: MTLRenderPipelineState!
    private var waterPipeline: MTLRenderPipelineState!
    private var structurePipeline: MTLRenderPipelineState!
    /// v1.3.0: additive-blended lava billboard pipeline (nil if shader missing).
    private var lavaPipeline: MTLRenderPipelineState?
    #if M3_FEATURES
    /// Ray-traced shadow variant of the terrain pipeline. Nil when the
    /// RT fragment function failed to compile; falls back to terrainPipeline.
    private var terrainPipelineRT: MTLRenderPipelineState?
    #endif
    private var depthState: MTLDepthStencilState!
    private var waterDepthState: MTLDepthStencilState!
    /// Cached depth texture for the reflection pass (renderReflection).
    /// Reused across calls; only recreated when the size changes.
    private var reflectionDepthTexture: MTLTexture?
    private var reflectionDepthSize: (width: Int, height: Int) = (0, 0)

    private var viewProj = matrix_identity_float4x4
    private var cameraPos = SIMD3<Float>(0, 0, 0)
    private var lastCameraTarget = SIMD2<Float>(0, 0)
    private var lastCenter: MTChunkCoord?
    private var lastRadius: Int?
    private var lastConfigVersion: UInt64 = 0
    // v1.1.0: removed (opacity now comes from waterParamsBuffer).
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
        #if M3_FEATURES
        /// Raw heightmap for the mesh-shading path (GPU expands vertices).
        /// Nil when the mesh path is unavailable; the standard path ignores it.
        var heightmapBuffer: MTLBuffer?
        var heightmapResolution: Int = 0
        /// Grid stride for LOD subsampling in the mesh shader (1 = full).
        var lodStride: Float = 1
        #endif
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
    /// v1.2.3: limits concurrent chunk builds to avoid GPU stalls when many
    /// chunks finish at once (the lag spike when moving fast).
    private let buildSemaphore = DispatchSemaphore(value: 2)
    /// v1.2.6: GPU mesh builder (heightmap + vertices on GPU). Nil when
    /// the kernel is unavailable — buildChunkAsync uses the CPU path.
    private var meshCompute: MTMeshCompute?
    /// v1.3.0: volcano lava particle simulation. Nil-safe: eruptions only
    /// run when volcanoes exist; rendering skips when no instances.
    private var lava: MTLavaParticles?
    /// Last lava sim time (for dt in update).
    private var lastLavaTime: Double?
    /// v1.3.0: reusable lava instance buffer (260 max × 32 bytes).
    private var lavaInstanceBuffer: MTLBuffer?
    // Generation counter: bumped by invalidateCaches(). Background builds
    // capture the generation at dispatch; if it changed by completion,
    // the mesh is stale (built from an old config) and must be dropped.
    private var buildGeneration: UInt64 = 0

    private var waterVertexBuffer: MTLBuffer?
    private var waterIndexBuffer: MTLBuffer?
    private var waterIndexCount = 0
    private var waterParamsBuffer: MTLBuffer?

    private struct StructureMesh {
        var vertexBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
        var instanceBuffer: MTLBuffer?
        var instanceCount: Int
    }
    private var structureMeshes: [MTStructureKind: StructureMesh] = [:]
    private var structureChunkSet = Set<MTChunkCoord>()
    private var tlasFrameCounter = 0
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
        #if M3_FEATURES
        // Mesh-shading pipeline (best-effort; nil on failure or older GPU).
        buildMeshShadingPipelines(library: library)
        #endif
        // Metal version override (from settings). Nil = auto-detect.
        if let override = metalVersionOverride {
            switch override {
            case .metal4:
                #if arch(arm64)
                if #available(iOS 26, macOS 26, *), buildMetal4Pipelines(library: library) {
                    usesMetal4 = true
                    return
                }
                #endif
                // Forced Metal 4 but unavailable — fall through to Metal 3.
                usesMetal4 = false
                buildMetal3Pipelines(library: library)
                return
            case .metal3:
                usesMetal4 = false
                buildMetal3Pipelines(library: library)
                return
            }
        }
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
            // v1.3.0: lava billboards — additive blending, emissive.
            // Best-effort: nil when the shader is missing (older .metallib).
            if library.makeFunction(name: "lava_vertex") != nil,
               library.makeFunction(name: "lava_fragment") != nil {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: "lava_vertex")
                d.fragmentFunction = library.makeFunction(name: "lava_fragment")
                d.colorAttachments[0]?.pixelFormat = .bgra8Unorm
                d.depthAttachmentPixelFormat = .depth32Float
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
                lavaPipeline = try? device.makeRenderPipelineState(descriptor: d)
            }
            #if M3_FEATURES
            // Ray-traced shadow variant of the terrain pipeline. Best-effort:
            // nil when the function is missing (older .metallib) — the
            // standard pipeline is used instead.
            if library.makeFunction(name: "terrain_fragment_rt") != nil {
                terrainPipelineRT = try device.makeRenderPipelineState(
                    descriptor: descriptor(vertex: "terrain_vertex",
                                           fragment: "terrain_fragment_rt",
                                           blending: false))
            }
            #endif
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
            // v1.3.0: lava billboards (additive). Best-effort.
            lavaPipeline = try? metal4AdditivePipeline(compiler: compiler, library: library,
                                                       vertex: "lava_vertex",
                                                       fragment: "lava_fragment")
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

    /// v1.3.0: Metal 4 additive-blending pipeline (for lava billboards).
    @available(iOS 26, macOS 26, *)
    private func metal4AdditivePipeline(compiler: MTL4Compiler,
                                        library: MTLLibrary,
                                        vertex: String,
                                        fragment: String) throws -> MTLRenderPipelineState {
        let vDesc = MTL4LibraryFunctionDescriptor()
        vDesc.library = library
        vDesc.name = vertex
        let fDesc = MTL4LibraryFunctionDescriptor()
        fDesc.library = library
        fDesc.name = fragment

        let d = MTL4RenderPipelineDescriptor()
        d.vertexFunctionDescriptor = vDesc
        d.fragmentFunctionDescriptor = fDesc
        d.inputPrimitiveTopology = .triangleStrip
        guard let color = d.colorAttachments[0] else {
            preconditionFailure("MTTerrainRenderer: Metal 4 color attachment 0 missing")
        }
        color.pixelFormat = .bgra8Unorm
        color.blendingState = .enabled
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .one
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
        // +1 for the reflection slot (used by renderReflection for mirrors).
        let length = uniformStrideAligned * (maxFramesInFlight * slotsPerFrame + 1)
        guard let buf = device.makeBuffer(length: length, options: .storageModeShared) else {
            preconditionFailure("MTTerrainRenderer: uniform buffer allocation failed")
        }
        uniformBuffer = buf
    }

    /// Procedural 3D geometric detail amount (0=off … 1=full). Displaces
    /// mesh-shader vertices by material-specific noise for real 3D texture.
    public var detailAmount: Float = 1.0

    private func writeUniforms(slot: Int, model: simd_float4x4, time: Float,
                               viewProj: simd_float4x4? = nil,
                               cameraPos: SIMD3<Float>? = nil) {
        let cfg = world.config
        let density = fogEnabled ? cfg.fogDensity : 0
        // Sun direction from azimuth/elevation (degrees).
        let az = sunAzimuth * .pi / 180
        let el = sunElevation * .pi / 180
        let sunDir = SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az))
        // misc: x=time, y=shaderFX, z=wireframe, w=detailAmount
        // seaLevel.x = world-space water level (for shoreline foam)
        let u = MTUniforms(
            viewProj: viewProj ?? self.viewProj,
            model: model,
            cameraPos: SIMD4<Float>(cameraPos ?? self.cameraPos, 1),
            fogColor: SIMD4<Float>(fogColorOverride ?? cfg.fogColor, density),
            lightDir: SIMD4<Float>(normalize(sunDir), cfg.ambientIntensity),
            misc: SIMD4<Float>(time, shaderEffectsEnabled ? 1 : 0,
                               wireframe ? 1 : 0, detailAmount),
            seaLevel: SIMD4<Float>(world.worldY(forHeight: cfg.seaLevel), cfg.sunIntensity, 0, 0),
            sunColor: SIMD4<Float>(sunColor, 1)
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
            // v1.2.3: throttle concurrent builds to prevent lag spikes.
            self.buildSemaphore.wait()
            defer { self.buildSemaphore.signal() }
            // Early-out: if a newer generation was requested while this
            // block was queued (rapid Generate clicks), skip the expensive
            // work entirely instead of building then dropping it.
            self.cacheLock.lock()
            let current = self.buildGeneration
            self.cacheLock.unlock()
            guard current == generation else { return }
            let size = self.world.config.chunkWorldSize
            let cx = (Float(coord.x) + 0.5) * size
            let cz = (Float(coord.z) + 0.5) * size
            let dist = hypot(cx - cameraTarget.x, cz - cameraTarget.y)
            let distanceFactor = dist / (Float(self.viewDistance) * size)
            // LOD: far chunks generate at half resolution (4x fewer noise evals).
            // The mesh shader takes arbitrary resolution+lodStride, so half-res
            // heightmaps work identically on both paths.
            let resScale: Float = distanceFactor > 0.4 ? 0.5 : 1.0
            // v1.2.6: full-GPU mesh path — padded heightmap and packed
            // vertices built on the GPU with no CPU roundtrip. Any failure
            // falls through to the CPU path below.
            if let mc = self.meshCompute {
                let res = max(2, Int(Float(max(2, self.world.config.chunkResolution)) * resScale))
                if let gpu = mc.buildMesh(coord: coord, res: res, world: self.world) {
                    let gpuIndices = MTMeshBuilder.cachedIndices(n: gpu.gridN)
                    if let ib = self.sharedIndexBuffer(n: gpu.gridN, indices: gpuIndices) {
                        #if M3_FEATURES
                        // Heightmap buffer for the mesh-shading path.
                        let hb = self.sharedBuffer(from: gpu.heights)
                        #endif
                        self.cacheLock.lock()
                        // Drop stale builds: config changed while generating.
                        if generation == self.buildGeneration {
                            let y0 = self.world.worldY(forHeight: gpu.minHeight)
                            let y1 = self.world.worldY(forHeight: gpu.maxHeight)
                            let x0 = Float(coord.x) * size
                            let z0 = Float(coord.z) * size
                            self.chunkCache[coord] = ChunkMesh(
                                vertexBuffer: gpu.vertexBuffer,
                                indexBuffer: ib,
                                indexCount: gpuIndices.count,
                                lastUsed: Date().timeIntervalSince1970,
                                boundsMin: SIMD3<Float>(x0, min(y0, y1) - 20, z0),
                                boundsMax: SIMD3<Float>(x0 + size, max(y0, y1) + 20, z0 + size)
                            )
                            #if M3_FEATURES
                            self.chunkCache[coord]?.heightmapBuffer = hb
                            self.chunkCache[coord]?.heightmapResolution = res
                            self.chunkCache[coord]?.lodStride = distanceFactor > 0.4 ? 2 : 1
                            #endif
                        }
                        self.pendingBuilds.remove(coord)
                        self.cacheLock.unlock()
                        return
                    }
                }
            }
            let chunk = self.world.generateChunk(at: coord, resolutionScale: resScale)
            let mesh = MTMeshBuilder.buildLOD(for: chunk, world: self.world,
                                              distanceFactor: distanceFactor)
            guard let vb = self.sharedBuffer(from: mesh.vertices),
                  let ib = self.sharedIndexBuffer(n: mesh.gridN,
                                                   indices: mesh.indices) else {
                self.cacheLock.lock()
                self.pendingBuilds.remove(coord)
                self.cacheLock.unlock()
                return
            }
            #if M3_FEATURES
            // Heightmap buffer for the mesh-shading path (GPU vertex expansion).
            let hb = self.sharedBuffer(from: chunk.heights)
            #endif
            self.cacheLock.lock()
            // Drop stale builds: config changed while we were generating.
            if generation == self.buildGeneration {
                // AABB for frustum culling: chunk XZ extent, Y from min/max height.
                // M3: min/max computed during generation (no extra passes).
                let y0 = self.world.worldY(forHeight: chunk.minHeight)
                let y1 = self.world.worldY(forHeight: chunk.maxHeight)
                let x0 = Float(coord.x) * size
                let z0 = Float(coord.z) * size
                self.chunkCache[coord] = ChunkMesh(
                    vertexBuffer: vb,
                    indexBuffer: ib,
                    indexCount: mesh.indices.count,
                    lastUsed: Date().timeIntervalSince1970,
                    boundsMin: SIMD3<Float>(x0, min(y0, y1) - 20, z0),
                    boundsMax: SIMD3<Float>(x0 + size, max(y0, y1) + 20, z0 + size)
                )
                #if M3_FEATURES
                self.chunkCache[coord]?.heightmapBuffer = hb
                self.chunkCache[coord]?.heightmapResolution = chunk.resolution
                self.chunkCache[coord]?.lodStride = distanceFactor > 0.4 ? 2 : 1
                #endif
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

    /// Shared index buffers keyed by grid size `n`. Chunk index topology
    /// is identical for every chunk at a given resolution, so one MTLBuffer
    /// serves all of them (saves ~1.5MB per chunk).
    private var sharedIndexBuffers: [Int: MTLBuffer] = [:]
    private let sharedIndexBufferLock = NSLock()

    /// Returns the shared index MTLBuffer for grid size `n`, creating it
    /// from `indices` on first use. Thread-safe (called on the build queue).
    private func sharedIndexBuffer(n: Int, indices: [UInt32]) -> MTLBuffer? {
        sharedIndexBufferLock.lock()
        defer { sharedIndexBufferLock.unlock() }
        if let buf = sharedIndexBuffers[n] { return buf }
        guard let buf = sharedBuffer(from: indices) else { return nil }
        sharedIndexBuffers[n] = buf
        return buf
    }

    private func invalidateCaches() {
        cacheLock.lock()
        chunkCache.removeAll()
        pendingBuilds.removeAll()
        buildGeneration &+= 1
        cacheLock.unlock()
        sharedIndexBufferLock.lock()
        sharedIndexBuffers.removeAll()
        sharedIndexBufferLock.unlock()
        structureChunkSet = []
        clearStructureInstances()
        // v1.3.0: new seed/config → fresh lava state.
        lava?.reset(seed: world.seed)
    }

    /// v1.3.0: is there lethal lava at a world position? For the app's
    /// player-death check. False when the lava system is unavailable.
    public func isLavaAt(_ position: SIMD3<Float>) -> Bool {
        lava?.isLavaAt(position) ?? false
    }

    // MARK: Water

    private func buildWaterMesh() {
        let cfg = world.config
        let size = Float(viewDistance * 2 + 4) * cfg.chunkWorldSize
        let level = world.worldY(forHeight: cfg.seaLevel)
        let mesh = MTMeshBuilder.buildWaterMesh(size: size, level: level,
                                                color: cfg.waterColor)
        waterVertexBuffer = sharedBuffer(from: mesh.vertices)
        waterIndexBuffer = sharedBuffer(from: mesh.indices)
        waterIndexCount = mesh.indices.count
    }

    /// Creates the water params buffer and fills it with current values.
    private func buildWaterParamsBuffer() {
        precondition(MemoryLayout<MTWaterParams>.stride == 48,
                     "MTWaterParams layout drifted from MTShaders.metal")
        waterParamsBuffer = device.makeBuffer(length: MemoryLayout<MTWaterParams>.stride,
                                              options: .storageModeShared)
        updateWaterParams()
    }

    /// Updates the water params buffer from the current public property values.
    private func updateWaterParams() {
        guard let buffer = waterParamsBuffer else { return }
        var params = MTWaterParams(
            deepAndSpeed: SIMD4<Float>(waterDeepColor.x, waterDeepColor.y, waterDeepColor.z, waveSpeed),
            shallowAndAmp: SIMD4<Float>(waterShallowColor.x, waterShallowColor.y, waterShallowColor.z, waveAmplitude),
            opacityAndPad: SIMD4<Float>(waterOpacity, 0, 0, 0)
        )
        buffer.contents().copyMemory(from: &params, byteCount: MemoryLayout<MTWaterParams>.stride)
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
