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
        // Hoist config.noise out of the inner loop: `config` is a locking
        // computed property, so accessing it per-vertex = 62.5K lock acquisitions.
        // M1: build the height field config once (avoids 4 struct copies/vertex).
        // v1.0.5: pass through configurable terrain scales.
        let field = MTHeightFieldConfig(base: config.noise,
                                        continentScale: config.continentScale,
                                        riverScale: config.riverScale,
                                        mountainSharpness: config.mountainSharpness)

        var heights = [Float](repeating: 0, count: res * res)
        // M3: track min/max in the fill loop (avoids two extra passes).
        var minH: Float = .greatestFiniteMagnitude
        var maxH: Float = -.greatestFiniteMagnitude
        for iz in 0..<res {
            let wz = z0 + Double(iz) * step
            for ix in 0..<res {
                let wx = x0 + Double(ix) * step
                let h = mtHeightSampleField(
                    x: wx, y: wz, field: field,
                    noise: noise, warpNoise: warpNoise)
                heights[iz * res + ix] = h
                if h < minH { minH = h }
                if h > maxH { maxH = h }
            }
        }
        return MTChunk(coord: coord, heights: heights, resolution: res,
                       minHeight: minH, maxHeight: maxH)
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
            var cumulative: Float = 0
            var kindIndex = kinds.count - 1  // fallback covers t == 1.0
            for i in 0..<kinds.count {
                cumulative += kindWeights[i]
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
