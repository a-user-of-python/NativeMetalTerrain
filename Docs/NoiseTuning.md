# Noise Tuning

`MTNoiseConfig` is the soul of your world — nine knobs that decide whether you
get an archipelago, rolling hills, jagged peaks, or canyonlands. This guide
explains each knob, gives "turn this up for X" guidance, and ends with four
complete recipes.

The pipeline, briefly: a seeded permutation table drives 2D gradient (Perlin)
noise → fractal layers (fbm) are summed → the sample point is optionally
domain-warped → the result is normalized to a 0…1 height. Every stage is
deterministic.

## The knobs, one by one

### `seed: UInt64` (default `1337`)

Which world. Everything — permutation table, warp offsets, structure placement —
derives from it. Same seed + same config = same planet, on any device, forever.

> **Turn this up for:** a brand-new world when you like the *style* but not the
> *layout*. Keep every other knob fixed and just roll seeds until a coastline
> or mountain range delights you.

### `octaves: Int` (default `5`, range 1…12)

How many detail layers are stacked. Octave 1 is the broad shape (continents,
mountain ranges); each higher octave adds finer detail (hills, bumps, crags).

- **Lower (1–3):** smooth, clean shapes — dunes, rolling plains, stylized worlds.
- **Higher (7–12):** rich, craggy detail — realistic mountains, eroded badlands.
- **Cost:** each octave is one more noise evaluation per sample — roughly linear
  cost. Generation time scales with octaves, so prefer 5–6 for interactive
  regeneration.

> **Turn this up for:** detail and realism. **Turn it down for:** smooth,
> cartoon-like terrain and faster generation.

### `baseFrequency: Double` (default `0.008`)

The size of the biggest features. **This is the most misunderstood knob:**
*lower* frequency = *larger* features.

- `0.004` — vast continents, huge mountain ranges, sweeping plains.
- `0.008` — the default: balanced, interesting at chunk scale.
- `0.02` — busy, small-scale bumps; the world feels "noisy" and cramped.

Think of it as zoom: halving the frequency zooms the noise out 2×.

> **Turn this up for:** dense, small-scale relief (badlands, choppy seas of
> hills). **Turn it down for:** epic scale — broad valleys, giant ranges.

### `lacunarity: Double` (default `2.03`)

How much *finer* each octave gets relative to the previous one (frequency
multiplier per octave). The classic value is ~2.0.

- **Higher (2.5–3.5):** detail gets fine fast — crisp, sharp, almost crystalline.
- **Lower (1.5–1.8):** octaves stay broad — soft, blobby, gentle detail.

> **Turn this up for:** crisp craggy detail on peaks. **Turn it down for:**
> soft, weathered, eroded looks.

### `gain: Double` (default `0.5`)

How much *weaker* each octave is than the previous one (amplitude falloff).
Higher gain = later (finer) octaves contribute more = rougher surface.

- **Higher (0.6–0.75):** rough, textured, chaotic — every scale fights for attention.
- **Lower (0.3–0.4):** the broad shape dominates — smooth with a whisper of detail.

> **Turn this up for:** ruggedness and texture. **Turn it down for:** calm,
> dominant landforms.

### `warpStrength: Double` (default `0.35`, `0` = off)

Domain warp: the sample point is pushed around by a second noise field before
the height is evaluated. This is what makes coastlines wind, valleys meander,
and mountain ranges curve instead of running in straight mathematical lines.

- `0` — clean, classic Perlin look; features align to the noise grid.
- `0.2–0.4` — organic and natural (the default sweet spot).
- `0.6–1.0` — wild, swirly, almost marbled — coastlines fold back on themselves.

> **Turn this up for:** organic, winding, natural coastlines and valleys.
> **Set to 0 for:** stylized, predictable, grid-aligned terrain (or to debug
> what the raw fbm looks like).

### `warpFrequency: Double` (default `0.02`)

The scale of the warp pattern itself — how quickly the *pushing* varies across
the map.

- **Higher:** the warp twists rapidly — tight meanders, convoluted coasts.
- **Lower:** broad, slow swoops — whole ranges bend gently.

> Usually tuned *with* `warpStrength`: strong warp + low warp frequency =
> grand sweeping curves; strong warp + high warp frequency = tangled spaghetti.

### `ridged: Bool` (default `false`)

**Mountain mode.** Each octave becomes `(1 − |n|)²` instead of `n`, turning
smooth bumps into sharp crests and V-shaped valleys. This single flag is the
difference between hills and the Alps.

> **Turn it ON for:** jagged peaks, knife-edge ridges, canyonlands.
> **Leave it OFF for:** dunes, plains, rolling hills, islands.

### `amplitude: Double` (default `1.0`)

Overall multiplier on the noise field before normalization. Combined with
`config.heightScale` (world units at height = 1), this sets total relief.

> **Turn this up for:** more dramatic elevation differences everywhere.
> Prefer `heightScale` when you want the same *shapes* but taller in world units.

## Recipes

Each recipe is a complete `MTNoiseConfig` plus the `MTTerrainConfig` tweaks
that go with it. Start from `.default` and apply:

### Archipelago — scattered islands in a big ocean

```swift
var noise = MTNoiseConfig.default
noise.octaves = 4
noise.baseFrequency = 0.006      // broad features → distinct islands
noise.warpStrength = 0.55        // winding, organic coastlines
noise.ridged = false

var config = MTTerrainConfig.default
config.noise = noise
config.seaLevel = 0.58           // drown everything but the island tops
world.config = config
```

*Why it works:* low frequency makes a few large landmasses; high sea level
keeps only their tops above water; strong warp gives every island an
interesting coastline.

### Rolling hills — gentle pastoral land

```swift
var noise = MTNoiseConfig.default
noise.octaves = 3                // smooth — little fine detail
noise.baseFrequency = 0.006
noise.warpStrength = 0.45
noise.gain = 0.35                // broad shapes dominate
noise.ridged = false

var config = MTTerrainConfig.default
config.noise = noise
config.seaLevel = 0.40           // mostly land, lakes in the dips
config.heightScale = 40          // soft relief
world.config = config
```

### Jagged peaks — alpine ridgelines

```swift
var noise = MTNoiseConfig.default
noise.octaves = 6
noise.baseFrequency = 0.010
noise.lacunarity = 2.2
noise.gain = 0.55                // rough at every scale
noise.warpStrength = 0.30
noise.ridged = true              // ← mountain mode

var config = MTTerrainConfig.default
config.noise = noise
config.seaLevel = 0.35           // deep valleys, high peaks
config.heightScale = 90          // tall in world units
world.config = config
```

Then widen the snow band as shown in [BiomeAuthoring.md](BiomeAuthoring.md)
(Recipe 1) so the peaks read as alpine.

### Canyonlands — eroded plateaus and ravines

```swift
var noise = MTNoiseConfig.default
noise.octaves = 5
noise.baseFrequency = 0.012      // smaller-scale features
noise.lacunarity = 2.6           // detail gets fine fast
noise.gain = 0.6
noise.warpStrength = 0.15        // keep strata readable, not swirly
noise.ridged = true              // sharp V valleys between flat-ish tops

var config = MTTerrainConfig.default
config.noise = noise
config.seaLevel = 0.30
config.heightScale = 70
world.config = config
```

*Why it works:* ridged noise at moderate frequency carves sharp ravines;
low warp keeps the plateau tops calm so the contrast reads as "canyon".

## Seed reproducibility

The headline guarantee: **same seed + same config = same world, everywhere.**

- The PRNG (xorshift64*), the permutation table shuffle, the fbm summation
  order, and the warp are all integer/float-deterministic — no wall-clock, no
  randomness, no device-specific paths in world generation.
- `heightAt(x:z:)` is a pure function of the seed: gameplay code and rendered
  meshes can never disagree about the terrain.
- The **structure field** (`config.structureNoise`) has its own seed — you can
  re-roll structure placement without reshaping the terrain, and vice versa.
- **Caveat:** reproducibility holds for identical configs. Changing *any* noise
  knob — even slightly — produces a different world. If you ship seeds to users
  (shared worlds, save files), version your config alongside the seed so a
  future tuning pass doesn't silently move everyone's mountains.
