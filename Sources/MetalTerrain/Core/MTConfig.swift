// MTConfig.swift
// MetalTerrain — top-level terrain configuration.

import Foundation

/// All tweakables for a terrain world. Matches DESIGN.md exactly.
public struct MTTerrainConfig {
    public var chunkResolution: Int   // vertices per chunk side, default 96
    public var chunkWorldSize: Float  // world units, default 128
    public var viewDistance: Int      // chunk radius around camera, default 6
    public var seaLevel: Float        // normalized 0...1, default 0.45
    public var heightScale: Float     // world units at height=1, default 60
    public var biomes: [MTBiome]      // default MTBiome.default
    public var noise: MTNoiseConfig
    public var structureNoise: MTNoiseConfig
    public var structuresEnabled: Bool    // default true
    public var structureDensity: Float    // 0...1, default 0.35
    public var waterColor: SIMD3<Float>   // linear RGB
    public var fogColor: SIMD3<Float>      // linear RGB
    public var fogDensity: Float

    public init(
        chunkResolution: Int = 250,
        chunkWorldSize: Float = 1000,
        viewDistance: Int = 6,
        seaLevel: Float = 0.45,
        heightScale: Float = 400,
        biomes: [MTBiome] = MTBiome.default,
        noise: MTNoiseConfig = MTNoiseConfig(),
        structureNoise: MTNoiseConfig = MTNoiseConfig(
            seed: 90210, octaves: 3, baseFrequency: 0.004,
            amplitude: 1.0, lacunarity: 2.03, gain: 0.5,
            warpStrength: 0.0, warpFrequency: 0.02, ridged: false),
        structuresEnabled: Bool = true,
        structureDensity: Float = 0.35,
        waterColor: SIMD3<Float> = SIMD3<Float>(0.10, 0.35, 0.62),
        fogColor: SIMD3<Float> = SIMD3<Float>(0.62, 0.74, 0.86),
        fogDensity: Float = 0.0028
    ) {
        self.chunkResolution = max(2, chunkResolution)
        // Clamp to safe ranges: negative/huge viewDistance crashes or
        // exhausts memory; zero chunkWorldSize divides by zero.
        self.chunkWorldSize = max(1, chunkWorldSize)
        self.viewDistance = min(max(1, viewDistance), 10)
        self.seaLevel = min(max(0, seaLevel), 1)
        self.heightScale = max(1, heightScale)
        self.biomes = biomes
        self.noise = noise
        self.structureNoise = structureNoise
        self.structuresEnabled = structuresEnabled
        self.structureDensity = min(max(0, structureDensity), 1)
        self.waterColor = waterColor
        self.fogColor = fogColor
        self.fogDensity = max(0, fogDensity)
    }

    /// Sensible defaults for every field.
    public static var `default`: MTTerrainConfig {
        MTTerrainConfig()
    }
}
