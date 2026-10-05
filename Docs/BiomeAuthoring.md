# Biome Authoring

Biomes are how MetalTerrain turns raw heights into a world that *reads* —
ocean vs. beach vs. forest vs. snow. This guide covers how the mapping works,
the built-in table, and how to write your own biomes: higher mountains, lava
fields, underwater zones, and more.

## How biomes map from height

Every point in the world has a **normalized height** from 0 to 1
(`world.heightAt(x:z:)`). A biome claims a slice of that range:

```swift
MTBiome(
    name: "grass",
    minHeight: 0.50,   // inclusive — heights >= 0.50 can match
    maxHeight: 0.65,   // exclusive — heights < 0.65 can match
    groundColor: SIMD3(0.25, 0.55, 0.20),  // linear RGB 0...1
    slopeColor: SIMD3(0.45, 0.38, 0.30),   // cliffs (optional)
    emitsLight: false
)
```

`world.biomeAt(height:)` finds the biome for a height. When chunks are meshed,
each vertex gets the color of its biome — `groundColor` on flat ground,
`slopeColor` on steep slopes (that's what makes cliffs look like cliffs).

**Key rules:**

- `minHeight` is **inclusive**, `maxHeight` is **exclusive**.
- For gapless coverage, stack ranges end-to-start: `0.00–0.15`, `0.15–0.35`, …
- Colors are **linear RGB** in 0…1 (not sRGB 0–255). If your colors look washed
  out, you're probably passing sRGB values — convert first.
- Biome colors are **baked into vertex colors at mesh build time**. Changing a
  biome rebuilds affected chunk meshes (the renderer handles this), but it's
  not free — don't animate biome colors every frame.

## The built-in table

`MTBiome.default` ships seven biomes that tile the full 0…1 range, low to high.
Thresholds mirror the classic `sb_terrain` zone layout:

| Biome | Height range | Look |
|---|---|---|
| `deepOcean` | bottom of range → low | dark blue water floor |
| `ocean` | low → below sea level | mid blue water floor |
| `beach` | around sea level (`seaLevel` ≈ 0.45) | sand |
| `grass` | lowlands above the beach | green plains |
| `forest` | rolling highlands | darker, denser green |
| `mountain` | high altitude | grey rock (with `slopeColor` cliffs) |
| `snowyPeak` | top of range | white |

The exact boundary values live in `MTBiome.swift` (`MTBiome.default`). The
`beach` band straddles `config.seaLevel`, so raising `seaLevel` widens the
ocean and narrows the land — biomes and sea level are tuned to work together.

## Custom biomes: the three operations

```swift
// Add a NEW biome (or REPLACE the one with the same name)
world.setBiome(MTBiome(name: "volcano", minHeight: 0.90, maxHeight: 1.0,
                       groundColor: SIMD3(0.15, 0.05, 0.05),
                       slopeColor: SIMD3(0.35, 0.10, 0.05),
                       emitsLight: true))

// Remove a custom biome you added (built-ins can't be removed individually)
world.removeBiome(named: "volcano")

// Throw away ALL custom biomes, restore the built-in table
world.resetBiomesToDefault()
```

### Precedence rules (read this before overlapping ranges)

1. **Custom biomes are checked first, in insertion order.** The first custom
   biome whose range contains the height wins.
2. **Built-ins are the fallback.** If no custom biome matches, the built-in
   list is checked.
3. **`setBiome` with an existing name replaces in place** — it does not add a
   duplicate, and the replacement keeps behaving like the entry it replaced
   (including overriding a built-in of the same name).

Practical consequence: a custom biome overlapping a built-in range *shadows*
the built-in there. That's a feature — it's how you override `snowyPeak`
below — but overlapping two customs means insertion order decides, so keep
custom ranges tidy.

## Recipe 1: Higher mountains than default

The default `snowyPeak` only crowns the very top of the range. To push
dramatic high-altitude terrain lower (bigger white/purple peaks, more rock),
**replace `snowyPeak` by name** and widen its band downward, then stretch
`mountain` to meet it:

```swift
// Snow starts lower and covers more of the highlands
world.setBiome(MTBiome(name: "snowyPeak",
                       minHeight: 0.80, maxHeight: 1.0,
                       groundColor: SIMD3(0.92, 0.94, 0.97),  // bright snow
                       slopeColor: SIMD3(0.55, 0.50, 0.58))) // purple-grey cliffs

// Stretch mountain down to meet it so there's no gap or overlap
world.setBiome(MTBiome(name: "mountain",
                       minHeight: 0.68, maxHeight: 0.80,
                       groundColor: SIMD3(0.42, 0.40, 0.44),
                       slopeColor: SIMD3(0.30, 0.28, 0.32)))
```

Pair this with `noise.ridged = true` and a higher `heightScale` (see
[NoiseTuning.md](NoiseTuning.md)) for genuinely jagged alpine terrain.

## Recipe 2: Lava biome (with `emitsLight`)

A volcanic band high on the mountains that glows in the shader:

```swift
// Insert AFTER replacing snowyPeak above, so ordering stays sane:
world.setBiome(MTBiome(name: "snowyPeak",
                       minHeight: 0.88, maxHeight: 1.0,
                       groundColor: SIMD3(0.92, 0.94, 0.97),
                       slopeColor: SIMD3(0.55, 0.50, 0.58)))

// Lava fields between mountain and snow
world.setBiome(MTBiome(name: "lava",
                       minHeight: 0.80, maxHeight: 0.88,
                       groundColor: SIMD3(0.85, 0.18, 0.05),  // molten orange-red
                       slopeColor: SIMD3(0.25, 0.05, 0.03),   // cooled crust on cliffs
                       emitsLight: true))                     // glows in the shader
```

Because `lava` is custom, it takes precedence over the built-in `mountain`
range it overlaps — insertion order only matters against *other customs*, and
here there's just one. The renderer's fragment shader treats `emitsLight`
vertices as self-illuminated (they skip the NdotL darkening and fog less
aggressively), so lava reads as glowing even at night or in fog.

**Tip:** keep `emitsLight` bands narrow. A little glowing lava reads as
volcanic; half the map glowing reads as a bug.

## Recipe 3: Underwater biome

The ocean floor is just the `deepOcean`/`ocean` ground seen through the water
plane. To make shallows glow tropical or the abyss go pitch black, override by
name:

```swift
// Tropical shallows: bright turquoise sand under the water
world.setBiome(MTBiome(name: "ocean",
                       minHeight: 0.15, maxHeight: 0.42,   // match the built-in band
                       groundColor: SIMD3(0.15, 0.65, 0.60)))

// Abyssal plain: near-black
world.setBiome(MTBiome(name: "deepOcean",
                       minHeight: 0.00, maxHeight: 0.15,
                       groundColor: SIMD3(0.01, 0.03, 0.06)))
```

(Use the actual built-in boundary values from `MTBiome.swift` for the ranges —
the numbers above illustrate the shape.)

Remember the water plane itself is `config.waterColor`, drawn translucent
*over* these ground colors — final look is the blend of the two.

## Tips

- **Design top-down or bottom-up, but cover 0…1.** Any height with no matching
  biome falls back to the built-in list — usually fine, but if you intended a
  full custom set, call `resetBiomesToDefault()` first, then add your customs
  in height order so precedence is obvious.
- **Mind the sea.** `config.seaLevel` (default 0.45) decides what's underwater.
  A beach biome far from sea level looks wrong; keep water-adjacent bands
  near it.
- **Slope colors sell cliffs.** Any biome with real elevation change looks
  dramatically better with a `slopeColor` — rock on mountains, dark loam in
  forests, pale sand on dunes.
- **Structures avoid some biomes.** Placement keeps structures on land between
  beach top and snow — lava fields and deep ocean won't sprout houses, which
  is usually what you want.
- **Name discipline.** Names are identity: `"SnowyPeak"` and `"snowyPeak"` are
  different biomes. Reuse the exact built-in names when overriding.
- **Test with wireframe off, fog on.** `renderer.wireframe = true` is for mesh
  debugging; judge biome colors in normal rendering with fog enabled, because
  fog shifts distant colors toward `fogColor`.
