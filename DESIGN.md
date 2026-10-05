# MetalTerrain — Design Contract

A 3D terrain generation library for iOS (iOS 17+, Apple Silicon), rendered with
native Metal 3 (Metal 4 features where available via `@available` / feature-set
checks). All code is original — concepts are inspired by the sb_terrain Scratch
extension (seeded noise, height-threshold biomes, structure noise field) but
every line is written fresh.

## Goals

- Drop-in library: an app integrates with ~10 lines of code.
- Chunked, seeded, infinite 3D heightmap terrain with streaming.
- Data-driven biomes keyed on height (built-ins + developer custom biomes).
- Exposed noise configuration (seed, octaves, frequency, gain, warp, ridged).
- Automatic seeded structure placement (houses, towers, trees, boulders,
  wells, windmills, dungeons as low-poly 3D meshes) with an on/off toggle.
- iOS-optimized: chunk pooling, LOD, instanced structures, Metal-friendly
  buffers, 60fps target on M1+.
- Demo iOS app proving the API.
- Extensive docs.

## Module layout

```
Sources/MetalTerrain/
  Noise/
    MTSeededRandom.swift   — deterministic PRNG (xorshift64*, original)
    MTPerlinNoise.swift    — 2D gradient noise, permutation table from seed
    MTNoise.swift          — fbm, ridged, domain warp; MTNoiseConfig struct
  Core/
    MTConfig.swift         — MTTerrainConfig (all tweakables, .default)
    MTBiome.swift          — MTBiome (name, height range, colors, rules)
    MTChunk.swift          — MTChunkCoord (Hashable), MTChunk (heightmap grid)
    MTTerrainWorld.swift   — public MTTerrainWorld class (main API)
  Structures/
    MTStructures.swift     — MTStructureKind, MTStructurePlacement,
                             MTStructureBuilder (low-poly meshes per kind),
                             seeded placement via structure noise field
  Rendering/
    MTMeshBuilder.swift    — heightmap grid -> indexed triangle mesh,
                             vertex colors from biomes, slope-based cliffs,
                             LOD levels
    MTShaders.metal        — vertex/fragment shaders (lighting, fog, water)
    MTTerrainRenderer.swift— Metal 3 renderer, Metal 4 upgrades where
                             available, chunk streaming, instanced structures
```

## Public API (must match exactly)

```swift
// MARK: - Noise
public struct MTNoiseConfig {
    public var seed: UInt64
    public var octaves: Int          // 1...12, default 5
    public var baseFrequency: Double // default 0.008
    public var amplitude: Double     // default 1.0
    public var lacunarity: Double    // default 2.03
    public var gain: Double          // default 0.5
    public var warpStrength: Double  // default 0.35 (0 = off)
    public var warpFrequency: Double // default 0.02
    public var ridged: Bool          // default false (mountain mode)
    public init(seed: UInt64 = 1337, octaves: Int = 5,
                baseFrequency: Double = 0.008, amplitude: Double = 1.0,
                lacunarity: Double = 2.03, gain: Double = 0.5,
                warpStrength: Double = 0.35, warpFrequency: Double = 0.02,
                ridged: Bool = false)
}

// MARK: - Biomes
public struct MTBiome {
    public var name: String
    public var minHeight: Float   // normalized 0...1, inclusive
    public var maxHeight: Float   // normalized 0...1, exclusive
    public var groundColor: SIMD3<Float>  // linear RGB 0...1
    public var slopeColor: SIMD3<Float>?  // steep-slope override (cliffs)
    public var emitsLight: Bool           // e.g. lava biome
    public init(name: String, minHeight: Float, maxHeight: Float,
                groundColor: SIMD3<Float>, slopeColor: SIMD3<Float>? = nil,
                emitsLight: Bool = false)
}
extension MTBiome {
    public static var `default`: [MTBiome] { ... } // deepOcean, ocean, beach,
        // grass, forest, mountain, snowyPeak — mirrors sb_terrain thresholds
}

// MARK: - Config
public struct MTTerrainConfig {
    public var chunkResolution: Int   // vertices per chunk side, default 64
    public var chunkWorldSize: Float  // world units, default 128
    public var viewDistance: Int      // chunk radius around camera, default 6
    public var seaLevel: Float        // normalized 0...1, default 0.45
    public var heightScale: Float     // world units at height=1, default 60
    public var biomes: [MTBiome]      // default MTBiome.default
    public var noise: MTNoiseConfig
    public var structureNoise: MTNoiseConfig
    public var structuresEnabled: Bool    // default true
    public var structureDensity: Float    // 0...1, default 0.35
    public var waterColor: SIMD3<Float>
    public var fogColor: SIMD3<Float>
    public var fogDensity: Float
    public static var `default`: MTTerrainConfig { ... }
}

// MARK: - Chunks
public struct MTChunkCoord: Hashable {
    public var x: Int
    public var z: Int
    public init(x: Int, z: Int)
}
public struct MTChunk {
    public var coord: MTChunkCoord
    public var heights: [Float]  // chunkResolution*chunkResolution, normalized 0...1
    public var resolution: Int
}

// MARK: - Structures
public enum MTStructureKind: String, CaseIterable {
    case house, tower, tree, boulder, well, windmill, dungeon
}
public struct MTStructurePlacement {
    public var kind: MTStructureKind
    public var position: SIMD3<Float>  // world coords, y = terrain height
    public var rotationY: Float
    public var scale: Float
}

// MARK: - World (main entry point)
public final class MTTerrainWorld {
    public init(seed: UInt64, config: MTTerrainConfig = .default)
    public var config: MTTerrainConfig
    public var seed: UInt64
    /// Normalized height 0...1 at world (x, z). Pure function of seed.
    public func heightAt(x: Double, z: Double) -> Float
    /// Biome for a normalized height (custom biomes take precedence in
    /// insertion order; falls back to built-in list).
    public func biomeAt(height: Float) -> MTBiome
    /// Generate a chunk's heightmap. Deterministic.
    public func generateChunk(at coord: MTChunkCoord) -> MTChunk
    /// Structures toggle (live).
    public var structuresEnabled: Bool
    /// Structure placements intersecting a chunk. Deterministic.
    public func structures(in coord: MTChunkCoord) -> [MTStructurePlacement]
    /// Add or replace a custom biome (matched by name).
    public func setBiome(_ biome: MTBiome)
    public func removeBiome(named name: String)
    public func resetBiomesToDefault()
    /// World-space Y of a normalized height.
    public func worldY(forHeight h: Float) -> Float
}

// MARK: - Rendering
public final class MTTerrainRenderer {
    public init(device: MTLDevice, world: MTTerrainWorld)
    public var world: MTTerrainWorld
    public func setCamera(position: SIMD3<Float>, target: SIMD3<Float>,
                          fovDegrees: Float, aspect: Float,
                          near: Float, far: Float)
    /// Call every frame. Handles chunk streaming around the camera target.
    public func update(cameraTarget: SIMD2<Float>)
    public func draw(in view: MTKView)
    public var wireframe: Bool
    public var showsWater: Bool
}
```

## Key algorithms (original implementations)

- **PRNG**: xorshift64* seeded from UInt64.
- **Perlin**: classic 2D gradient noise; permutation table = 0...255 shuffled
  with the seeded PRNG, doubled to 512.
- **fbm**: sum amp*noise(x*freq), amp*=gain, freq*=lacunarity, normalized.
- **ridged**: (1-|n|)^2 per octave, for mountains.
- **Domain warp**: q = fbm(p + warpOffset), height = fbm(p + warpStrength*q).
- **heightAt**: warp the (x,z), fbm/ridged -> 0...1 via *0.5+0.5.
- **Structures**: per chunk, K candidate points from chunk-seeded PRNG;
  keep if structureNoise(x,z) > densityThreshold AND height in [beachTop, snow];
  kind picked by second noise value mapped over 7 kinds; rotation/scale from
  PRNG. Toggle = skip placement entirely.

## Metal notes

- One shared vertex format: position (float3), normal (float3), color (float3).
- Terrain: one MTLBuffer per chunk mesh (indexed), vertex colors baked.
- Water: single large plane at sea level, transparent-ish blue, drawn after.
- Structures: one low-poly mesh per kind; per-instance data (model matrix +
  tint) in an instanced buffer; single draw call per kind.
- Lighting: simple directional (NdotL) + ambient in fragment shader; fog by
  distance.
- Metal 4: use `MTL4CommandBuffer`/argument-table fast paths when
  `@available(iOS 26, *)` and device supports; else Metal 3 path. Keep both
  behind a tiny abstraction; never crash on older OS.
- LOD: chunks beyond `viewDistance/2` build at half resolution.

## Demo app (Demo/TerrainDemo)

SwiftUI + MTKView. Orbit (drag), pinch zoom, pan. Controls: seed field +
"Regenerate", biome preset picker (Default / Desert / Alien + custom add),
structures toggle, wireframe toggle, FPS label. Must read as "10 lines to
integrate".

## Docs (Docs/)

- Quickstart.md — 5-minute integration.
- APIReference.md — every public type/method.
- BiomeAuthoring.md — custom height biomes, examples (higher mountains).
- NoiseTuning.md — what each noise knob does, with pictures described.
- PerformanceGuide.md — chunk budget, LOD, instancing, memory.

## Non-goals

- No physics, no gameplay — pure terrain library.
- No third-party code. No textures — vertex colors only (keeps it portable).
