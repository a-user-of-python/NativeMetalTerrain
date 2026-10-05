// MTNoise.swift
// MetalTerrain — fractal noise composition: fbm, ridged multifractal,
// and domain-warped height sampling.
//
// Original implementations. `MTNoiseConfig` carries every knob;
// the free functions `fbm`, `ridged`, and `height` are pure functions
// of (config, x, y).

import Foundation

// MARK: - Noise configuration

/// All tunables for the terrain noise field. Matches DESIGN.md exactly.
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
                baseFrequency: Double = 0.004, amplitude: Double = 1.0,
                lacunarity: Double = 2.03, gain: Double = 0.42,
                warpStrength: Double = 0.25, warpFrequency: Double = 0.015,
                ridged: Bool = false) {
        self.seed = seed
        self.octaves = octaves
        self.baseFrequency = baseFrequency
        self.amplitude = amplitude
        self.lacunarity = lacunarity
        self.gain = gain
        self.warpStrength = warpStrength
        self.warpFrequency = warpFrequency
        self.ridged = ridged
    }
}

// MARK: - Public free functions

/// Fractal Brownian motion: layered gradient noise, amplitude-normalized
/// to roughly [-1, 1]. Pure function of (config, x, y).
public func fbm(_ config: MTNoiseConfig, x: Double, y: Double) -> Double {
    let noise = MTPerlinNoise(seed: config.seed)
    return mtFBMSum(config: config,
                    nx: x * config.baseFrequency,
                    ny: y * config.baseFrequency,
                    noise: noise)
}

/// Labeled-`field` alias of `fbm(_:x:y:)`.
public func fbm(field config: MTNoiseConfig, x: Double, y: Double) -> Double {
    fbm(config, x: x, y: y)
}

/// Ridged multifractal: `(1 - |n|)^2` per octave, normalized to [0, 1].
/// Produces sharp mountain ridges. Pure function of (config, x, y).
public func ridged(_ config: MTNoiseConfig, x: Double, y: Double) -> Double {
    let noise = MTPerlinNoise(seed: config.seed)
    return mtRidgedSum(config: config,
                       nx: x * config.baseFrequency,
                       ny: y * config.baseFrequency,
                       noise: noise)
}

/// Domain-warped terrain height in [0, 1].
///
/// The sample point is first warped by a low-octave fbm vector field
/// (`warpStrength == 0` disables warping), then evaluated with fbm or
/// ridged per `config.ridged`, and finally mapped via `0.5 + 0.5 * v`.
/// Pure function of (config, x, y).
public func height(x: Double, y: Double, config: MTNoiseConfig) -> Float {
    let noise = MTPerlinNoise(seed: config.seed)
    let warpNoise = MTPerlinNoise(seed: config.seed ^ 0x9E3779B97F4A7C15)
    return mtHeightSample(x: x, y: y, config: config,
                          noise: noise, warpNoise: warpNoise)
}

// MARK: - Internal sampling core (pre-built noise fields)

/// Octave count clamped to the supported 1...12 range.
func mtClampedOctaves(_ config: MTNoiseConfig) -> Int {
    max(1, min(12, config.octaves))
}

/// Raw fbm octave sum over already frequency-scaled coords,
/// normalized by total amplitude (roughly [-1, 1]).
func mtFBMSum(config: MTNoiseConfig, nx: Double, ny: Double,
              noise: MTPerlinNoise) -> Double {
    var sum = 0.0
    var amp = config.amplitude
    var freq = 1.0
    var norm = 0.0
    for _ in 0..<mtClampedOctaves(config) {
        sum += amp * noise.noise(x: nx * freq, y: ny * freq)
        norm += amp
        amp *= config.gain
        freq *= config.lacunarity
    }
    return norm > 0 ? sum / norm : 0
}

/// Ridged octave sum over already frequency-scaled coords,
/// normalized by total amplitude ([0, 1]).
func mtRidgedSum(config: MTNoiseConfig, nx: Double, ny: Double,
                 noise: MTPerlinNoise) -> Double {
    var sum = 0.0
    var amp = config.amplitude
    var freq = 1.0
    var norm = 0.0
    for _ in 0..<mtClampedOctaves(config) {
        let n = noise.noise(x: nx * freq, y: ny * freq)
        let r = 1.0 - abs(n)
        sum += amp * r * r
        norm += amp
        amp *= config.gain
        freq *= config.lacunarity
    }
    return norm > 0 ? sum / norm : 0
}

/// fbm mapped to [0, 1] — used for structure density / kind fields.
func mtFBM01(config: MTNoiseConfig, x: Double, y: Double,
             noise: MTPerlinNoise) -> Double {
    let v = mtFBMSum(config: config,
                     nx: x * config.baseFrequency,
                     ny: y * config.baseFrequency,
                     noise: noise)
    return min(max(0.5 + 0.5 * v, 0.0), 1.0)
}

/// Full height pipeline with pre-built noise fields (fast path for
/// chunk generation: build the tables once, sample many points).
func mtHeightSample(x: Double, y: Double, config: MTNoiseConfig,
                    noise: MTPerlinNoise, warpNoise: MTPerlinNoise) -> Float {
    // ── Continent layer (very low frequency): large landmasses vs oceans ──
    // 2 octaves is visually indistinguishable from 3 for these smooth masks,
    // saves ~6 noise evals per vertex (~19%).
    var continentConfig = config
    continentConfig.octaves = 2
    continentConfig.warpStrength = 0
    let continentFreq = config.baseFrequency * 0.18
    let continent = mtFBMSum(config: continentConfig,
                             nx: x * continentFreq, ny: y * continentFreq,
                             noise: noise)

    // ── Base detail (current behavior) ──
    var nx = x * config.baseFrequency
    var ny = y * config.baseFrequency

    if config.warpStrength > 0 {
        var warpConfig = config
        warpConfig.octaves = 3
        warpConfig.amplitude = 1.0
        warpConfig.ridged = false
        let wScale = config.baseFrequency != 0
            ? config.warpFrequency / config.baseFrequency : 1.0
        let wx = mtFBMSum(config: warpConfig,
                          nx: nx * wScale + 5.2, ny: ny * wScale + 1.3,
                          noise: warpNoise)
        let wy = mtFBMSum(config: warpConfig,
                          nx: nx * wScale - 1.7, ny: ny * wScale + 9.2,
                          noise: warpNoise)
        nx += config.warpStrength * wx
        ny += config.warpStrength * wy
    }

    let detail: Double
    if config.ridged {
        detail = mtRidgedSum(config: config, nx: nx, ny: ny, noise: noise)
    } else {
        detail = mtFBMSum(config: config, nx: nx, ny: ny, noise: noise)
    }

    // ── Mountain ranges: ridged noise, masked to range bands ──
    // Low frequency = wide ranges spanning multiple chunks.
    // Only ~35% of land gets mountains; the rest stays as plains/hills.
    // 6 octaves + peak rounding for smooth (not pointy) summits.
    var rangeConfig = config
    rangeConfig.octaves = 6
    rangeConfig.ridged = true
    let rangeMask = mtFBMSum(config: continentConfig,
                             nx: (x + 1000) * continentFreq,
                             ny: (y - 1000) * continentFreq, noise: warpNoise)
    let mountainMask = max(0, min(1, (rangeMask - 0.08) * 2.2))  // 0..1
    // Mountain shape at 0.35x frequency: ranges 3x wider, spanning chunks.
    let mtnFreq = config.baseFrequency * 0.35
    let ridged = mtRidgedSum(config: rangeConfig,
                             nx: x * mtnFreq, ny: y * mtnFreq,
                             noise: noise)
    // Round the peaks: pow <1 softens the sharp ridged cusps.
    let rounded = pow(max(0, ridged), 0.72)
    let mountains = rounded * mountainMask * mountainMask

    // ── Rivers: wide carved valleys along low-frequency meanders ──
    // Lower frequency = longer, more continuous rivers that reach the ocean.
    var riverConfig = config
    riverConfig.octaves = 3
    riverConfig.warpStrength = 0
    let riverFreq = config.baseFrequency * 0.22
    // Domain-warp the river path so it meanders naturally.
    let riverWarpX = mtFBMSum(config: continentConfig,
                              nx: (x + 5000) * continentFreq,
                              ny: (y + 5000) * continentFreq, noise: warpNoise)
    let riverWarpY = mtFBMSum(config: continentConfig,
                              nx: (x - 5000) * continentFreq,
                              ny: (y - 5000) * continentFreq, noise: noise)
    let riverN = mtFBMSum(config: riverConfig,
                          nx: ((x + riverWarpX * 800) + 5000) * riverFreq,
                          ny: ((y + riverWarpY * 800) + 5000) * riverFreq,
                          noise: noise)
    let riverDist = abs(riverN)
    // Wide smooth valley (not a thin line that breaks).
    let riverCarve = max(0, 1 - riverDist * 6)
    let riverCarveSmooth = riverCarve * riverCarve * (3 - 2 * riverCarve)
    // Let rivers reach the ocean: don't fade at the coast. Instead, scale
    // carve depth by height above sea level so river mouths are shallow
    // channels, not canyons through the beach. Only carve on land.
    let landMask = max(0, min(1, (continent + 0.45) * 2.5))
    let riverCarveMasked = riverCarveSmooth * landMask

    // ── Combine: continent sets the stage, detail adds texture ──
    // Plains: flatten detail where mountains are absent.
    let plainsFlatten = 1 - mountainMask * 0.7
    var h = 0.5 + continent * 0.55 + detail * 0.28 * plainsFlatten
    h += mountains * 0.55
    // Coastal shelf: flatten near sea level for visible beaches.
    // Smoothstep from 0.40 (full flat) to 0.55 (no effect).
    let coastalT = max(0, min(1, (h - 0.40) / 0.15))
    let coastalFlat = coastalT * coastalT * (3 - 2 * coastalT)
    h = 0.46 + (h - 0.46) * (0.25 + 0.75 * coastalFlat)
    // River depth: carve to below sea level near coast (so rivers hold water),
    // shallower in highlands. Masked to avoid carving mountainsides.
    let riverValleyMask = 1 - mountainMask * 0.85
    let elevationFactor = max(0.3, min(1, (h - 0.45) * 3))
    let targetDepth = max(0, h - 0.42)  // carve down to 0.42 (below sea level)
    let carveAmount = min(0.35 * elevationFactor, targetDepth)
    h -= riverCarveMasked * riverValleyMask * carveAmount

    return Float(min(max(h, 0.0), 1.0))
}
