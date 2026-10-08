// MTTerrainWorld.swift
// MetalTerrain — the main entry point: seeded infinite terrain,
// biome lookup, chunk generation, and seeded structure placement.
//
// Everything here is deterministic: the same seed + config always
// produces the same heights, biomes, chunks, and structures.
// No I/O and no unseeded randomness.

import Foundation

/// Seeded infinite 3D heightmap terrain world. Matches DESIGN.md exactly.
public final class MTTerrainWorld {
    // All mutable state is protected by `stateLock`: `config` and `seed`
    // are read from background chunk-build queues while the main thread
    // may write them.
    private let stateLock = NSLock()
    private var _config: MTTerrainConfig
    private var _seed: UInt64

    /// Live configuration (noise knobs, biomes, structure toggle, ...).
    /// Thread-safe. Setting it bumps `configVersion` so renderers can
    /// invalidate their caches.
    public var config: MTTerrainConfig {
        get { stateLock.withLock { _config } }
        set {
            stateLock.withLock {
                _config = newValue
                _configVersion &+= 1
            }
        }
    }
    /// World seed. Height, chunk, and structure queries are pure
    /// functions of this seed plus `config`. Thread-safe.
    public var seed: UInt64 {
        get { stateLock.withLock { _seed } }
        set { stateLock.withLock { _seed = newValue } }
    }
    /// Incremented every time `config` is set. Renderers snapshot this in
    /// `update()` and rebuild caches + water when it changes.
    public var configVersion: UInt64 {
        stateLock.withLock { _configVersion }
    }
    private var _configVersion: UInt64 = 0

    /// Custom biomes added via `setBiome`, in insertion order.
    /// These take precedence over `config.biomes` in `biomeAt`.
    /// Guarded by `stateLock`: mutated on the main thread (demo UI),
    /// read on the background chunk-build queue.
    private var _customBiomes: [MTBiome] = []
    private var customBiomes: [MTBiome] {
        get { stateLock.withLock { _customBiomes } }
        set { stateLock.withLock { _customBiomes = newValue } }
    }

    // Cached noise tables, keyed by seed. Building the 256-entry
    // permutation tables is the most expensive part of a height query;
    // without this cache, `heightAt` (and every chunk build) pays for
    // two Fisher-Yates shuffles per call.
    private let noiseLock = NSLock()
    private var cachedNoiseSeed: UInt64?
    private var cachedNoise: MTPerlinNoise?
    private var cachedWarpNoise: MTPerlinNoise?
    private var cachedStructureDensityNoise: MTPerlinNoise?
    private var cachedStructureKindNoise: MTPerlinNoise?

    /// Returns the (base, warp) noise tables for the current seed,
    /// building them once and reusing them until the seed changes.
    /// Thread-safe: concurrent callers may build duplicate tables once,
    /// but never observe a torn pair.
    /// Noise tables for mesh building. Internal for performance: lets
    /// MTMeshBuilder hoist the pair once instead of taking locks per-vertex.
    internal func noisePair() -> (MTPerlinNoise, MTPerlinNoise) {
        let currentSeed = seed  // single locked read; seed can't change mid-build
        noiseLock.lock()
        if cachedNoiseSeed != currentSeed || cachedNoise == nil {
            cachedNoise = MTPerlinNoise(seed: currentSeed)
            cachedWarpNoise = MTPerlinNoise(seed: currentSeed ^ Self.warpSeedXor)
            cachedStructureDensityNoise = MTPerlinNoise(seed: currentSeed ^ Self.structureSeedXor)
            cachedStructureKindNoise = MTPerlinNoise(
                seed: (currentSeed ^ Self.structureSeedXor) ^ Self.kindSeedXor)
            cachedNoiseSeed = currentSeed
        }
        let pair = (cachedNoise!, cachedWarpNoise!)
        noiseLock.unlock()
        return pair
    }

    /// Returns the cached (density, kind) structure noise tables.
    private func structureNoisePair() -> (MTPerlinNoise, MTPerlinNoise) {
        _ = noisePair()  // ensure tables are built
        noiseLock.lock()
        let pair = (cachedStructureDensityNoise!, cachedStructureKindNoise!)
        noiseLock.unlock()
        return pair
    }

    // Domain separation constants for the independent noise fields.
    private static let warpSeedXor: UInt64 = 0x9E3779B97F4A7C15
    private static let structureSeedXor: UInt64 = 0x94D049BB133111EB
    private static let kindSeedXor: UInt64 = 0xD1B54A32D192ED03
    private static let chunkSeedA: UInt64 = 0x9E3779B97F4A7C15
    private static let chunkSeedB: UInt64 = 0xBF58476D1CE4E5B9
    private static let chunkSeedC: UInt64 = 0xA24BAED4963EE407

    public init(seed: UInt64, config: MTTerrainConfig = .default) {
        self._seed = seed
        self._config = config
    }

    // MARK: - Height

    /// Normalized height in [0, 1] at world (x, z).
    /// Domain-warped fbm (or ridged, per `config.noise.ridged`).
    /// Pure function of seed + config.
    public func heightAt(x: Double, z: Double) -> Float {
        let (noise, warpNoise) = noisePair()
        return mtHeightSample(x: x, y: z, config: config.noise,
                              noise: noise, warpNoise: warpNoise)
    }

    /// World-space Y of a normalized height.
    public func worldY(forHeight h: Float) -> Float {
        h * config.heightScale
    }

    /// Finds a safe spawn point: land above sea level, below the mountains.
    /// Searches a spiral starting at the origin. Returns (0, 0) if nothing
    /// suitable is found (e.g. an ocean-heavy seed).
    public func findSafeSpawn() -> SIMD2<Float> {
        let seaLevel = config.seaLevel
        for radius: Double in [0, 100, 200, 400, 800, 1600] {
            for angle in stride(from: 0.0, to: 6.28, by: 0.5) {
                let x = radius * cos(angle)
                let z = radius * sin(angle)
                let h = heightAt(x: x, z: z)
                if h > seaLevel + 0.05 && h < 0.70 {
                    return SIMD2<Float>(Float(x), Float(z))
                }
            }
        }
        return SIMD2<Float>(0, 0)
    }

    // MARK: - Volcanoes (v1.3.0)

    /// A volcano vent: a tall, prominent peak that becomes a volcano.
    public struct MTVolcanoVent {
        /// World-space XZ of the vent (crater center).
        public var position: SIMD2<Float>
        /// Normalized height of the peak (before crater carving).
        public var peakHeight: Float
        /// Crater radius in world units.
        public var craterRadius: Float
        /// Normalized crater depth (subtracted at the vent center).
        public var craterDepth: Float
        /// World-space Y of the vent rim (for lava spawn).
        public var ventY: Float
    }

    // Volcano cache, keyed by (seed, configVersion). Guarded by volcanoLock.
    private let volcanoLock = NSLock()
    private var cachedVolcanoKey: (UInt64, UInt64)?
    private var cachedVents: [MTVolcanoVent] = []

    /// Volcano vents for this world. Deterministic per (seed, config):
    /// tall, prominent peaks become volcanoes (1–3 per world).
    /// Computed lazily on first access; thread-safe.
    public var volcanoVents: [MTVolcanoVent] {
        let key = (seed, configVersion)
        volcanoLock.lock()
        if let ck = cachedVolcanoKey, ck.0 == key.0 && ck.1 == key.1 {
            let v = cachedVents
            volcanoLock.unlock()
            return v
        }
        volcanoLock.unlock()
        let vents = computeVolcanoVents()
        volcanoLock.lock()
        cachedVolcanoKey = key
        cachedVents = vents
        volcanoLock.unlock()
        return vents
    }

    /// Finds up to 3 volcano candidates: local maxima above 0.55
    /// normalized height with topographic prominence (surroundings
    /// significantly lower), well separated from each other.
    private func computeVolcanoVents() -> [MTVolcanoVent] {
        // Coarse grid search. 200m step over ±4000m: 41×41 samples.
        // Each heightAt is a full noise eval; ~1681 evals one-time.
        let step: Double = 200
        let extent: Double = 4000
        let n = Int(extent * 2 / step) + 1
        var grid = [Float](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = -extent + Double(i) * step
                let z = -extent + Double(j) * step
                grid[j * n + i] = heightAt(x: x, z: z)
            }
        }
        struct Peak { var i: Int; var j: Int; var h: Float }
        var peaks: [Peak] = []
        // Local maxima strictly above 0.75.
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let h = grid[j * n + i]
                guard h > 0.55 else { continue }
                var isMax = true
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        if grid[(j + dj) * n + (i + di)] >= h { isMax = false; break }
                    }
                    if !isMax { break }
                }
                if isMax { peaks.append(Peak(i: i, j: j, h: h)) }
            }
        }
        // Prominence check: the terrain 600m away must be well below the peak.
        var prominent: [Peak] = []
        for p in peaks {
            let px = -extent + Double(p.i) * step
            let pz = -extent + Double(p.j) * step
            var ringMin = Float.greatestFiniteMagnitude
            let ringR: Double = 600
            for k in 0..<12 {
                let a = Double(k) * .pi * 2 / 12
                let h = heightAt(x: px + cos(a) * ringR, z: pz + sin(a) * ringR)
                if h < ringMin { ringMin = h }
            }
            if p.h - ringMin > 0.12 {
                prominent.append(p)
            }
        }
        // Tallest first; keep up to 3 with ≥2000m separation.
        prominent.sort { $0.h > $1.h }
        var chosen: [Peak] = []
        for p in prominent {
            let px = -extent + Double(p.i) * step
            let pz = -extent + Double(p.j) * step
            var ok = true
            for c in chosen {
                let cx = -extent + Double(c.i) * step
                let cz = -extent + Double(c.j) * step
                let d = hypot(px - cx, pz - cz)
                if d < 2000 { ok = false; break }
            }
            if ok { chosen.append(p) }
            if chosen.count >= 3 { break }
        }
        // Refine: sample a finer neighborhood to center the vent on the
        // true peak (the coarse grid can be up to ~140m off).
        return chosen.map { p in
            var bx = -extent + Double(p.i) * step
            var bz = -extent + Double(p.j) * step
            var bh = p.h
            for dj in stride(from: -100.0, through: 100.0, by: 50) {
                for di in stride(from: -100.0, through: 100.0, by: 50) {
                    let h = heightAt(x: bx + di, z: bz + dj)
                    if h > bh { bh = h; bx += di; bz += dj }
                }
            }
            let craterRadius = Float(55 + Double(bh) * 40)  // 85–95m
            return MTVolcanoVent(
                position: SIMD2<Float>(Float(bx), Float(bz)),
                peakHeight: bh,
                craterRadius: craterRadius,
                craterDepth: 0.035,
                ventY: worldY(forHeight: bh) - 0.035 * config.heightScale * 0.5
            )
        }
    }

    /// Carves volcano craters into a chunk heightmap (in place).
    /// The crater edge is wobbled by angle so it looks natural, not circular.
    /// v1.3.0-refine: also shapes the volcano into a regular cone within
    /// 4x crater radius (steeper, more natural volcanic profile).
    /// `x0/z0` = chunk origin (world), `step` = texel spacing, `res` = grid size.
    public func carveCraters(into heights: inout [UInt16],
                             x0: Double, z0: Double, step: Double, res: Int) {
        let vents = volcanoVents
        guard !vents.isEmpty, heights.count == res * res else { return }
        for v in vents {
            let vx = Double(v.position.x), vz = Double(v.position.y)
            let r = Double(v.craterRadius)
            let coneR = r * 4.0
            // Skip vents far from this chunk (cone region + margin).
            let margin = coneR * 1.05
            if vx < x0 - margin || vx > x0 + Double(res - 1) * step + margin { continue }
            if vz < z0 - margin || vz > z0 + Double(res - 1) * step + margin { continue }
            let depth = Double(v.craterDepth)
            let rTex = Int(ceil(margin / step))
            let cx = (vx - x0) / step, cz = (vz - z0) / step
            let ix0 = max(0, Int(floor(cx)) - rTex), ix1 = min(res - 1, Int(ceil(cx)) + rTex)
            let iz0 = max(0, Int(floor(cz)) - rTex), iz1 = min(res - 1, Int(ceil(cz)) + rTex)
            // Wobble phases match the GPU kernel (pos used directly).
            let ph1 = Double(v.position.x), ph2 = Double(v.position.y)
            let peakH = Double(v.peakHeight)
            for iz in iz0...iz1 {
                for ix in ix0...ix1 {
                    let wx = x0 + Double(ix) * step
                    let wz = z0 + Double(iz) * step
                    let dx = wx - vx, dz = wz - vz
                    let dist = sqrt(dx * dx + dz * dz)
                    if dist >= coneR { continue }
                    let idx = iz * res + ix
                    var h = Double(heights[idx]) / 65535.0
                    // Cone shaping: blend toward idealized cone profile.
                    do {
                        let t = dist / coneR
                        let coneH = peakH * pow(1.0 - t, 1.25)
                        let w = 0.45 * (1.0 - t) * (1.0 - t)
                        h = h * (1.0 - w) + coneH * w
                    }
                    // Crater carving (wobbled edge).
                    if dist < r * 1.35 {
                        let ang = atan2(dz, dx)
                        let wobble = 1.0 + 0.22 * sin(ang * 3 + ph1) * sin(ang * 5 + ph2)
                        let t = min(dist / (r * wobble), 1.0)
                        if t < 1.0 {
                            h += -(1.0 - t * t) * depth
                        } else {
                            h += 0.15 * depth * (1.0 - (t - 1.0) / 0.35)
                        }
                    }
                    h = min(max(h, 0), 1)
                    heights[idx] = UInt16((h * 65535.0).rounded())
                }
            }
        }
    }

    /// Safe spawn that stays away from volcanoes (post-death respawn).
    /// Falls back to `findSafeSpawn()` when no safe spot is found.
    public func findSafeSpawnAwayFromVolcanoes(minDistance: Float = 1500) -> SIMD2<Float> {
        let vents = volcanoVents
        let seaLevel = config.seaLevel
        for radius: Double in [0, 200, 400, 800, 1600, 3200] {
            for angle in stride(from: 0.0, to: 6.28, by: 0.4) {
                let x = radius * cos(angle)
                let z = radius * sin(angle)
                let h = heightAt(x: x, z: z)
                guard h > seaLevel + 0.05 && h < 0.70 else { continue }
                var safe = true
                for v in vents {
                    let d = hypot(Float(x) - v.position.x, Float(z) - v.position.y)
                    if d < minDistance { safe = false; break }
                }
                if safe { return SIMD2<Float>(Float(x), Float(z)) }
            }
        }
        return findSafeSpawn()
    }

    // MARK: - Biomes

    /// Biome for a normalized height. `height` is clamped to [0, 1].
    /// Custom biomes (via `setBiome`) take precedence in insertion
    /// order; then the built-in `config.biomes` list is consulted.
    public func biomeAt(height: Float) -> MTBiome {
        let h = min(max(height, 0), 1)
        if let b = firstBiome(matching: h, inclusiveTop: false) { return b }
        if let b = firstBiome(matching: h, inclusiveTop: true) { return b }
        // Absolute fallback (e.g. empty biome lists): flat gray.
        return MTBiome(name: "void", minHeight: 0, maxHeight: 1,
                       groundColor: SIMD3<Float>(repeating: 0.5))
    }

    private func firstBiome(matching h: Float, inclusiveTop: Bool) -> MTBiome? {
        for b in customBiomes + config.biomes {
            guard h >= b.minHeight else { continue }
            if h < b.maxHeight || (inclusiveTop && h <= b.maxHeight) {
                return b
            }
        }
        return nil
    }

    /// Add a custom biome, or replace the existing custom biome with
    /// the same name. Custom biomes take precedence over built-ins.
    public func setBiome(_ biome: MTBiome) {
        if let i = customBiomes.firstIndex(where: { $0.name == biome.name }) {
            customBiomes[i] = biome
        } else {
            customBiomes.append(biome)
        }
    }

    /// Remove a custom biome by name. Built-in biomes are unaffected.
    public func removeBiome(named name: String) {
        customBiomes.removeAll(where: { $0.name == name })
    }

    /// Clear custom biomes and restore the built-in biome list.
    public func resetBiomesToDefault() {
        customBiomes.removeAll()
        config.biomes = MTBiome.default
    }

    /// All biomes in lookup order (custom first, then config biomes) — the
    /// same order `biomeAt` consults. Used by the mesh-shader biome table.
    public var allBiomes: [MTBiome] { customBiomes + config.biomes }

    // MARK: - Chunks

    // GPU heightmap generator, installed by the renderer (which owns the
    // MTLDevice). Nil when the renderer never set it or the compute
    // kernel is unavailable — generateChunk then uses the CPU path.
    // v1.2.5: guarded by gpuLock (set on main, read on build queues).
    private let gpuLock = NSLock()
    private var _heightmapCompute: MTHeightmapCompute?
    internal var heightmapCompute: MTHeightmapCompute? {
        get { gpuLock.withLock { _heightmapCompute } }
        set { gpuLock.withLock { _heightmapCompute = newValue } }
    }

    /// Generate a chunk's heightmap. Deterministic: the same seed,
    /// config, and coord always yield the same grid.
    public func generateChunk(at coord: MTChunkCoord, resolutionScale: Float = 1) -> MTChunk {
        // LOD: distant chunks generate at reduced resolution (fewer noise evals).
        // resolutionScale=0.5 -> half the vertices per side -> 4x fewer evals.
        let res = max(2, Int(Float(max(2, config.chunkResolution)) * resolutionScale))
        let size = config.chunkWorldSize
        // Compute the chunk origin in Double: Float's 24-bit mantissa loses
        // integer precision past ~16M, which would misalign distant chunks.
        let x0 = Double(coord.x) * Double(size)
        let z0 = Double(coord.z) * Double(size)
        let step = Double(size) / Double(res - 1)

        // Reuse the cached noise tables (built once per seed).
        let (noise, warpNoise) = noisePair()
        let currentSeed = seed
        // Hoist config.noise out of the inner loop: `config` is a locking
        // computed property, so accessing it per-vertex = 62.5K lock acquisitions.
        // M1: build the height field config once (avoids 4 struct copies/vertex).
        // v1.0.5: pass through configurable terrain scales.
        let field = MTHeightFieldConfig(base: config.noise,
                                        continentScale: config.continentScale,
                                        riverScale: config.riverScale,
                                        mountainSharpness: config.mountainSharpness)

        // v1.2.5: GPU compute path — the MSL kernel replicates the Swift
        // noise math exactly. Any failure falls through to the CPU path.
        if let compute = heightmapCompute,
           let gpuHeights = compute.generateHeights(
               x0: x0, z0: z0, step: step, res: res, field: field,
               seed: currentSeed, noise: noise, warpNoise: warpNoise,
               vents: volcanoVents) {
            // v1.3.0: craters are carved in the GPU kernel (vent buffer).
            var minH: Float = .greatestFiniteMagnitude
            var maxH: Float = -.greatestFiniteMagnitude
            for q in gpuHeights {
                let h = Float(q) / 65535.0
                if h < minH { minH = h }
                if h > maxH { maxH = h }
            }
            return MTChunk(coord: coord, heights: gpuHeights, resolution: res,
                           minHeight: minH, maxHeight: maxH)
        }

        var heights = [UInt16](repeating: 0, count: res * res)
        // v1.2.4: parallelize across CPU cores with concurrentPerform.
        // Each row is independent (noise is stateless per-coordinate).
        // v1.3.0: min/max computed after crater carving (single pass below).
        heights.withUnsafeMutableBufferPointer { hbuf in
            DispatchQueue.concurrentPerform(iterations: res) { iz in
                let wz = z0 + Double(iz) * step
                for ix in 0..<res {
                    let wx = x0 + Double(ix) * step
                    let h = mtHeightSampleField(
                        x: wx, y: wz, field: field,
                        noise: noise, warpNoise: warpNoise)
                    // Quantize to 16-bit (6mm at 400m scale — invisible).
                    hbuf[iz * res + ix] = UInt16((h * 65535.0).rounded())
                }
            }
        }
        // v1.3.0: carve volcano craters, then min/max over carved heights.
        carveCraters(into: &heights, x0: x0, z0: z0, step: step, res: res)
        var cmin: Float = .greatestFiniteMagnitude
        var cmax: Float = -.greatestFiniteMagnitude
        for q in heights {
            let h = Float(q) / 65535.0
            if h < cmin { cmin = h }
            if h > cmax { cmax = h }
        }
        return MTChunk(coord: coord, heights: heights, resolution: res,
                       minHeight: cmin, maxHeight: cmax)
    }

    // MARK: - Structures

    /// Live structures toggle. Reads/writes `config.structuresEnabled`.
    public var structuresEnabled: Bool {
        get { config.structuresEnabled }
        set { config.structuresEnabled = newValue }
    }

    /// Structure placements for a chunk. Deterministic per (seed, coord).
    /// Returns [] when `structuresEnabled` is false.
    ///
    /// Algorithm: K candidate points from a chunk-seeded PRNG; keep a
    /// candidate when the structure-noise fbm exceeds a density-derived
    /// threshold and the terrain height is in [beachTop, 0.85]; the kind
    /// comes from a second noise field mapped over the 7 kinds, and
    /// rotation/scale come from the PRNG.
    public func structures(in coord: MTChunkCoord) -> [MTStructurePlacement] {
        guard structuresEnabled else { return [] }

        // M6: hoist all locking property accesses (was ~29 locks/chunk).
        let cfg = config
        let size = Double(cfg.chunkWorldSize)
        let x0 = Double(coord.x) * size
        let z0 = Double(coord.z) * size
        let structNoiseCfg = cfg.structureNoise
        let threshold = 1.0 - Double(cfg.structureDensity)
        let customB = customBiomes  // hoist (1 lock instead of per-access)

        var rng = MTSeededRandom(seed: chunkSeed(for: coord))
        let (densityNoise, kindNoise) = structureNoisePair()

        // Higher density -> lower keep threshold -> more structures.
        let beachTop: Float =
            customB.first(where: { $0.name == "beach" })?.maxHeight
            ?? cfg.biomes.first(where: { $0.name == "beach" })?.maxHeight
            ?? (cfg.seaLevel + 0.04)

        // Hoist noise pair for lock-free height sampling (avoid heightAt locks).
        let (hNoise, hWarpNoise) = noisePair()
        let hField = MTHeightFieldConfig(base: cfg.noise,
                                           continentScale: cfg.continentScale,
                                           riverScale: cfg.riverScale,
                                           mountainSharpness: cfg.mountainSharpness)

        var out: [MTStructurePlacement] = []
        let candidateCount = 12

        // Per-kind spawn weights (default 1.0 each = legacy uniform behavior).
        // Clamped here too, since the dict is mutable post-init.
        let kinds = MTStructureKind.allCases
        let kindWeights: [Float] = kinds.map { kind in
            min(max(cfg.structureKindWeights[kind.rawValue] ?? 1.0, 0), 10)
        }
        let totalWeight = kindWeights.reduce(0, +)

        for _ in 0..<candidateCount {
            let px = x0 + rng.nextDouble() * size
            let pz = z0 + rng.nextDouble() * size

            let density = mtFBM01(config: structNoiseCfg,
                                  x: px, y: pz, noise: densityNoise)
            guard density > threshold else { continue }

            let h = mtHeightSampleField(x: px, y: pz, field: hField,
                                        noise: hNoise, warpNoise: hWarpNoise)
            guard h >= beachTop && h <= 0.85 else { continue }

            let t = mtFBM01(config: structNoiseCfg,
                            x: px + 173.3, y: pz - 91.7, noise: kindNoise)
            // All weights zero -> no kind can spawn; skip this candidate.
            guard totalWeight > 0 else { continue }
            // Weighted pick via cumulative weights (t in 0...1).
            let pick = t * Double(totalWeight)
            var cumulative: Double = 0
            var kindIndex = kinds.count - 1  // fallback covers t == 1.0
            for i in 0..<kinds.count {
                cumulative += Double(kindWeights[i])
                if pick < cumulative {
                    kindIndex = i
                    break
                }
            }

            out.append(MTStructurePlacement(
                kind: kinds[kindIndex],
                position: SIMD3<Float>(Float(px), worldY(forHeight: h), Float(pz)),
                rotationY: Float(rng.nextDouble() * Double.pi * 2.0),
                scale: Float(0.8 + rng.nextDouble() * 0.6)))
        }
        return out
    }

    /// Deterministic per-chunk seed mixing the world seed with the coord.
    private func chunkSeed(for coord: MTChunkCoord) -> UInt64 {
        let cx = UInt64(bitPattern: Int64(coord.x))
        let cz = UInt64(bitPattern: Int64(coord.z))
        return seed
            ^ (cx &* Self.chunkSeedA)
            ^ (cz &* Self.chunkSeedB)
            ^ Self.chunkSeedC
    }
}
