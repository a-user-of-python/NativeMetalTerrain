# MetalTerrain API Reference

Every public type in `MetalTerrain`, exactly as defined by `DESIGN.md`.
Semantics and determinism notes are included so you know what you can rely on.

Conventions used below:

- **Deterministic** means: same inputs (same seed, same config) → same output,
  on every run and every device. All world generation is deterministic.
- Heights are **normalized 0…1** unless a function name says otherwise.
  `worldY(forHeight:)` converts normalized heights to world-space Y.

---

## MTNoiseConfig

```swift
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
```

Configuration for one noise field (the terrain height field, or the separate
structure-placement field). Value type — copy and mutate freely.

| Field | Default | Meaning |
|---|---|---|
| `seed` | `1337` | Drives the PRNG, permutation table, and warp offsets. Change it → new world. |
| `octaves` | `5` | Detail layers, 1…12. More = finer detail, slower. |
| `baseFrequency` | `0.008` | Feature size. **Lower = bigger features** (continents vs. bumps). |
| `amplitude` | `1.0` | Overall height scale of this noise field. |
| `lacunarity` | `2.03` | Frequency multiplier per octave. |
| `gain` | `0.5` | Amplitude falloff per octave; higher = rougher detail. |
| `warpStrength` | `0.35` | Domain-warp amount. `0` disables warp entirely. |
| `warpFrequency` | `0.02` | Scale of the warp pattern itself. |
| `ridged` | `false` | Mountain mode: `(1 - |n|)²` per octave → sharp ridges and peaks. |

**Determinism:** the entire noise pipeline (PRNG → permutation table → fbm →
warp) is a pure function of these fields. Same config + same sample point →
same value, always. See [NoiseTuning.md](NoiseTuning.md) for what each knob
does to the landscape.

---

## MTBiome

```swift
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
    /// deepOcean, ocean, beach, grass, forest, mountain, snowyPeak —
    /// thresholds mirror the sb_terrain zone layout.
    public static var `default`: [MTBiome] { ... }
}
```

One biome = one height band of the world, with its colors and behavior.

- `name` is the **identity** of the biome. `setBiome` matches by name: a custom
  biome with an existing name **replaces** that entry.
- `minHeight` is **inclusive**, `maxHeight` is **exclusive** — adjacent biomes
  tile without overlap or gaps when ranges are contiguous.
- Colors are **linear RGB** in 0…1, baked into chunk vertex colors at mesh build.
- `slopeColor`: when set, steep slopes in this biome render as cliffs in this
  color instead of `groundColor`. Leave `nil` for flat-shaded terrain.
- `emitsLight`: marks the biome as light-emitting (used by the renderer for
  lava-style glow in the shader). Purely visual.

`MTBiome.default` is the built-in set: `deepOcean`, `ocean`, `beach`, `grass`,
`forest`, `mountain`, `snowyPeak` — ordered low to high, tiling the full 0…1
range. See [BiomeAuthoring.md](BiomeAuthoring.md) for the full table and how to
customize.

---

## MTTerrainConfig

```swift
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
```

Everything tunable about the world in one value type. Grab
`MTTerrainConfig.default`, change what you want, assign to `world.config`.

| Field | Default | Meaning |
|---|---|---|
| `chunkResolution` | `64` | Vertices per chunk side. 64 → 64×64 height samples per chunk. |
| `chunkWorldSize` | `128` | World units across one chunk. Vertex spacing = `chunkWorldSize / chunkResolution`. |
| `viewDistance` | `6` | Chunk **radius** around the camera — total chunks ≈ (2·6+1)² = 169. |
| `seaLevel` | `0.45` | Normalized height of the water plane. Raise for archipelagos, lower for continents. |
| `heightScale` | `60` | World units of vertical relief at normalized height 1. |
| `biomes` | `MTBiome.default` | The biome table (see BiomeAuthoring.md). |
| `noise` | defaults | Height-field noise config. |
| `structureNoise` | defaults | **Separate** noise field for structure placement — tweak without reshaping terrain. |
| `structuresEnabled` | `true` | Master switch (also settable live via `world.structuresEnabled`). |
| `structureDensity` | `0.35` | 0…1 — fraction of candidate spots that keep a structure. |
| `waterColor` | — | Linear RGB of the water plane. |
| `fogColor` | — | Linear RGB of distance fog. |
| `fogDensity` | — | How fast fog thickens with distance. |

**Performance note:** `viewDistance` and `chunkResolution` dominate both memory
and frame cost — see [PerformanceGuide.md](PerformanceGuide.md) before raising
them.

---

## MTChunkCoord

```swift
public struct MTChunkCoord: Hashable {
    public var x: Int
    public var z: Int
    public init(x: Int, z: Int)
}
```

Identifies one chunk on the infinite XZ grid. `Hashable`, so it works as a
dictionary key and in sets. Chunk `(x, z)` covers world XZ in
`[x·chunkWorldSize, (x+1)·chunkWorldSize)`.

---

## MTChunk

```swift
public struct MTChunk {
    public var coord: MTChunkCoord
    public var heights: [Float]  // chunkResolution*chunkResolution, normalized 0...1
    public var resolution: Int
}
```

One generated heightmap tile. `heights` is row-major, `resolution × resolution`
samples, each normalized 0…1. Returned by `world.generateChunk(at:)`; also the
input the mesh builder turns into renderable geometry.

---

## MTStructureKind

```swift
public enum MTStructureKind: String, CaseIterable {
    case house, tower, tree, boulder, well, windmill, dungeon
}
```

The seven placeable structure types. `CaseIterable` — iterate all kinds for
palettes or legends. Each kind has one low-poly mesh built by
`MTStructureBuilder` (boulder smallest ≈ 0.7×, dungeon largest ≈ 1.9×), drawn
with a single instanced draw call per kind.

---

## MTStructurePlacement

```swift
public struct MTStructurePlacement {
    public var kind: MTStructureKind
    public var position: SIMD3<Float>  // world coords, y = terrain height
    public var rotationY: Float       // radians around Y
    public var scale: Float           // uniform scale multiplier
}
```

One placed structure instance. `position.y` is the **world-space** terrain
height at that spot (already converted via `worldY(forHeight:)`), so you can
drop the instance transform straight into your scene. Rotation and scale come
from the seeded PRNG — deterministic per chunk.

---

## MTTerrainWorld

```swift
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
```

The main entry point. Reference type — share one instance between your game
logic and the renderer.

**`init(seed:config:)`** — `seed` is the world's identity. Every height,
biome boundary evaluation, and structure placement derives from it. Same seed +
same config = same planet, on any device.

**`config`** — read/write. Changing it after chunks are built marks cached
meshes stale; the renderer rebuilds them on the next `update`. (Cheap fields
like `structuresEnabled` apply immediately; noise changes regenerate.)

**`seed`** — read/write. Changing the seed regenerates the world on next
`update` (equivalent to creating a new world with the same config).

**`heightAt(x:z:)`** — the core query. Normalized height 0…1 at any world (x, z).
**Pure function of the seed**: call it from gameplay code (spawn heights,
camera clamping, AI) and it always agrees with the rendered mesh, because the
mesh is built from the same function.

```swift
let h: Float = world.heightAt(x: 1234.5, z: -987.0)
let groundY = world.worldY(forHeight: h)   // where to stand the player
```

**`biomeAt(height:)`** — which biome a normalized height belongs to. Custom
biomes (added via `setBiome`) are checked **first, in insertion order**; if
none match, the built-in list is used. Deterministic.

**`generateChunk(at:)`** — builds the chunk's heightmap grid. Deterministic:
same coord + same seed/config → identical heights. Useful for minimaps,
previews, or your own meshing.

**`structuresEnabled`** — live toggle. `false` skips placement entirely (and the
renderer drops instanced structures); `true` restores them. No regeneration
needed.

**`structures(in:)`** — placements intersecting a chunk. Deterministic per
chunk: same chunk + seed/config → same structures. Placement rule: K candidate
points from a chunk-seeded PRNG are kept when the structure-noise field exceeds
the density threshold **and** the height is land (between beach top and snow);
the kind is picked by a second noise value mapped over the 7 kinds.

**`setBiome(_:)` / `removeBiome(named:)` / `resetBiomesToDefault()`** —
runtime biome editing. `setBiome` adds a new custom biome, or **replaces** the
entry with the same name. `removeBiome(named:)` removes a custom biome
(built-ins can only be replaced, never removed — call
`resetBiomesToDefault()` to clear all customs and restore the built-in table).
Custom biomes take precedence over built-ins in insertion order.

**`worldY(forHeight:)`** — converts normalized height → world-space Y using
`heightScale` (height 1 → `heightScale` world units). Use it for camera
clamping, object placement, and anything that lives in world space.

---

## MTTerrainRenderer

```swift
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

The Metal 3 renderer (with Metal 4 fast paths where available). Reference type;
create once per `MTLDevice`.

**`init(device:world:)`** — compiles the shader library, creates the shared
pipeline state, and sets up chunk and structure buffers. Safe to call on a
background thread; first `draw` must be on the main thread's drawable as usual
for `MTKView`.

**`world`** — swap the world to render a different planet with the same
renderer (meshes rebuild on next `update`).

**`setCamera(position:target:fovDegrees:aspect:near:far:)`** — the full camera.
Re-call whenever the view resizes to update `aspect`. `far` must exceed
`viewDistance × chunkWorldSize` or distant chunks get clipped.

**`update(cameraTarget:)`** — call once per frame, before `draw`. Streams
chunks around `cameraTarget` (the XZ your camera is looking at): generates
missing chunks, builds their GPU buffers, recycles out-of-range ones from the
pool, and refreshes structure instance buffers. All CPU-side work is bounded
per frame so a fast camera move causes gradual pop-in, not a hitch.

**`draw(in:)`** — encodes and submits one frame to the `MTKView`: terrain
chunks (front-to-back), the water plane (transparent, drawn after), then one
instanced draw per structure kind. Uses `MTL4CommandBuffer` / argument-table
fast paths on iOS 26+ devices that support them, and the standard Metal 3 path
otherwise — selected at runtime, never crashes on older OS.

**`wireframe`** — `true` renders triangle edges instead of filled faces.
Debugging aid; default `false`.

**`showsWater`** — `true` (default) draws the translucent water plane at sea
level after the terrain.

### Threading & lifecycle

- `update` and `draw` are **not thread-safe with each other** — call both from
  the same thread (normally the main thread via `MTKViewDelegate`).
- `MTTerrainWorld` query methods (`heightAt`, `biomeAt`, `generateChunk`,
  `structures(in:)`) are safe to call from background threads.
- The renderer holds its `world` strongly; breaking a retain cycle (renderer →
  world → …) is your responsibility if you tear the scene down.
