# Performance Guide

MetalTerrain targets 60 fps on Apple Silicon (M1+). This guide gives you the
math to budget chunks, explains what LOD and instancing buy you, estimates
memory, recommends settings per device, and shows how to profile with Metal
System Trace.

All numbers below use the defaults (`chunkResolution` 64, `chunkWorldSize` 128,
`viewDistance` 6) unless stated otherwise.

## Chunk budget math

`viewDistance` is a chunk **radius** around the camera target. The number of
live chunks is:

```
chunks = (2 × viewDistance + 1)²
```

| viewDistance | Chunks | Horizon (chunks × 128 units) |
|---|---|---|
| 4 | 81 | ~512 |
| **6 (default)** | **169** | **~768** |
| 8 | 289 | ~1024 |
| 10 | 441 | ~1280 |

Each chunk at full resolution is a 64×64 vertex grid → **63×63×2 = 7,938
triangles**. At `viewDistance` 6 that's 169 × 7,938 ≈ **1.34M triangles**
worst case — before LOD helps (see below). Triangle count scales with the
*square* of `viewDistance`, so think twice before raising it: 6 → 8 nearly
doubles the geometry.

**Vertex spacing** = `chunkWorldSize / chunkResolution` = 128 / 64 = **2 world
units** between height samples. Raising `chunkResolution` sharpens terrain
detail but quadruples vertex data each doubling (64 → 128 = 4× vertices).

### The two dials and what they cost

- **`viewDistance`** — controls *how much world* is visible. Cost scales with
  the square. This is the dial to turn down first when frames drop.
- **`chunkResolution`** — controls *how detailed* each chunk is. Cost scales
  with the square per chunk. Turn down second.

## LOD behavior

Chunks **beyond `viewDistance / 2`** build at **half resolution** automatically
(32×32 instead of 64×64 with defaults) — 1/4 the vertices, 1/4 the triangles.

With `viewDistance` 6, chunks within radius 3 are full-res, the rest are
half-res:

| Band | Chunks | Tris per chunk | Total tris |
|---|---|---|---|
| Near (≤ 3) | 7×7 = 49 | 7,938 | ~389K |
| Far (> 3) | 169 − 49 = 120 | ~1,985 | ~238K |
| **Total** | **169** | — | **~627K** |

LOD cuts the worst case roughly in half. The transition is at a fixed radius,
so popping is possible on fast camera moves — fog (`fogDensity`) is your
friend: tune it so the LOD boundary sits inside the haze.

## Instancing (structures)

Structures do **not** cost one draw call each. There is **one low-poly mesh per
kind** (7 kinds) and **one instanced draw call per kind** — per-instance model
matrices and tints live in an instance buffer. A hundred trees = one draw
call, not a hundred.

`structureDensity` (default 0.35) controls how many candidate spots become
structures — it affects instance *count*, not draw calls, so it's cheap to
raise unless you go extreme (tens of thousands of instances will eventually
cost vertex processing).

## Buffer reuse

- **Chunk pooling:** out-of-range chunks aren't freed — their vertex/index
  buffers go back into a pool and are reused for incoming chunks. Steady-state
  camera movement allocates ~zero new GPU buffers.
- **One buffer per chunk mesh:** indexed triangle lists; vertex colors baked
  (no per-frame CPU color work).
- **Shared vertex format** across everything: position (float3) + normal
  (float3) + color (float3) = **36 bytes/vertex**.

## Memory estimates

Per full-res chunk (64×64):

| Buffer | Size |
|---|---|
| Vertices: 4,096 × 36 B | ~144 KB |
| Indices: 7,938 tris × 3 × 4 B | ~95 KB |
| Heightmap (CPU): 4,096 × 4 B | ~16 KB |
| **Total per chunk** | **~255 KB** |

Per half-res chunk (32×32): ~36 KB + ~24 KB + ~4 KB ≈ **~64 KB**.

Steady-state estimate at `viewDistance` 6 (49 full + 120 half):

```
49 × 255 KB  ≈ 12.5 MB
120 × 64 KB  ≈  7.7 MB
Total        ≈ 20 MB  (+ small instance buffers + shader state)
```

Rules of thumb:

- Doubling `viewDistance` roughly **quadruples** memory (chunk count is squared).
- Doubling `chunkResolution` roughly **quadruples** per-chunk memory.
- The CPU heightmap cache is small (~16 KB/chunk) — GPU buffers dominate.
- Generation is the CPU spike, not memory: `octaves` 8+ on a large
  `viewDistance` will show up as frame hitches during fast movement before it
  shows up as memory pressure.

## Recommended settings per device

Start from the defaults, then adjust:

| Device | viewDistance | chunkResolution | octaves | Notes |
|---|---|---|---|---|
| **M1 iPad / iPhone 14-class** | 5 | 64 | 5 | The 60 fps baseline target. |
| **M2 / M3** | 6 | 64 | 5–6 | Defaults are comfortable. |
| **M4** | 7–8 | 64–96 | 6 | Headroom for denser worlds. |

If frames drop on any device, in order: **(1)** lower `viewDistance` by 1–2,
**(2)** lower `chunkResolution` to 48, **(3)** lower `octaves` to 4,
**(4)** disable structures (`structuresEnabled = false`) to isolate the cost.

`renderer.wireframe = true` is a quick visual check that you're fill-rate vs.
vertex bound: if wireframe runs dramatically faster, you're fragment-bound
(overdraw, water transparency, fog) — reduce overdraw, not chunks.

## Profiling with Metal System Trace

Xcode 16 + Instruments → **Metal System Trace** template, run on a physical
device (the Simulator tells you nothing useful about GPU performance):

1. **Frame time:** look for the 16.7 ms budget line. Consistent misses =
   structural (too many chunks); occasional spikes = generation hitches.
2. **Vertex vs. fragment:** the trace breaks GPU time into vertex/fragment.
   Vertex-heavy → reduce `chunkResolution`/`viewDistance`. Fragment-heavy →
   check water overdraw and fog cost.
3. **Encoder count:** MetalTerrain uses a small, fixed number of encoders per
   frame (terrain, water, 7 instanced structure draws). If you see encoder
   counts growing, something in *your* code is adding passes.
4. **Memory:** the Allocations instrument with the Metal counters shows GPU
   buffer residency — compare against the ~20 MB estimate above for defaults.
   Growth without bound = chunks leaking out of the pool (file a bug).

**Generation hitches:** chunk generation runs on the CPU during `update`. If
fast camera movement causes hitches, that's generation, not rendering — the
per-frame generation budget bounds it, at the cost of slower pop-in. Profile
with Time Profiler pointed at `generateChunk` / mesh building to confirm.

## Checklist before shipping

- [ ] Profiled on the **lowest device you support**, not just the newest.
- [ ] `far` plane ≥ `viewDistance × chunkWorldSize` (else chunks clip).
- [ ] Fog tuned so the LOD boundary (~`viewDistance/2` chunks out) sits in haze.
- [ ] `aspect` updated on rotation (stretched rendering wastes fill rate).
- [ ] Seed + config versioned together if you persist/share seeds (see
      [NoiseTuning.md](NoiseTuning.md) — reproducibility caveat).
