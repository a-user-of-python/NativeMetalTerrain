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
    public var structureKindWeights: [String: Float]  // per-kind spawn weights, 0...10, default all 1.0
    public var waterColor: SIMD3<Float>   // linear RGB (DEPRECATED: use waterDeepColor/waterShallowColor)
    public var fogColor: SIMD3<Float>      // linear RGB
    public var fogDensity: Float
    // v1.0.5: new customizable settings
    public var ambientIntensity: Float    // 0...1, default 0.38
    public var sunIntensity: Float        // 0...2, default 1.0
    public var continentScale: Float      // multiplier, default 1.0
    public var riverScale: Float           // multiplier, default 1.0
    public var mountainSharpness: Float   // power exponent, default 0.72
    // Water controls: colors and animation
    public var waterDeepColor: SIMD3<Float>    // linear RGB, default (0.01, 0.22, 0.35)
    public var waterShallowColor: SIMD3<Float> // linear RGB, default (0.15, 0.55, 0.65)
    public var waveSpeed: Float                // animation speed multiplier, 0...3, default 1.0
    public var waveAmplitude: Float            // wave normal strength, 0...2, default 1.0
    public var waterOpacity: Float             // 0...1, default 0.82

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
        structureKindWeights: [String: Float] = [:],
        waterColor: SIMD3<Float> = SIMD3<Float>(0.10, 0.35, 0.62),
        fogColor: SIMD3<Float> = SIMD3<Float>(0.62, 0.74, 0.86),
        fogDensity: Float = 0.0028,
        ambientIntensity: Float = 0.38,
        sunIntensity: Float = 1.0,
        continentScale: Float = 1.0,
        riverScale: Float = 1.0,
        mountainSharpness: Float = 0.72,
        waterDeepColor: SIMD3<Float> = SIMD3<Float>(0.01, 0.22, 0.35),
        waterShallowColor: SIMD3<Float> = SIMD3<Float>(0.15, 0.55, 0.65),
        waveSpeed: Float = 1.0,
        waveAmplitude: Float = 1.0,
        waterOpacity: Float = 0.82
    ) {
        // Clamp to safe ranges to prevent crashes from extreme slider values.
        // chunkResolution * chunkWorldSize * viewDistance determines memory;
        // 250 res × 3000 size × 10 distance = 18M+ vertices = OOM crash.
        self.chunkResolution = min(max(2, chunkResolution), 250)
        self.chunkWorldSize = min(max(1, chunkWorldSize), 2000)
        self.viewDistance = min(max(1, viewDistance), 10)
        self.seaLevel = min(max(0, seaLevel), 1)
        self.heightScale = max(1, heightScale)
        self.biomes = biomes
        self.noise = noise
        self.structureNoise = structureNoise
        self.structuresEnabled = structuresEnabled
        self.structureDensity = min(max(0, structureDensity), 1)
        // Merge per-kind weights with defaults: missing keys = 1.0
        // (equal weight, preserves legacy behavior). Clamp 0...10.
        var mergedWeights: [String: Float] = [:]
        for kind in MTStructureKind.allCases {
            let w = structureKindWeights[kind.rawValue] ?? 1.0
            mergedWeights[kind.rawValue] = min(max(w, 0), 10)
        }
        // Preserve any unknown keys (clamped), rather than silently dropping them.
        for (key, value) in structureKindWeights where mergedWeights[key] == nil {
            mergedWeights[key] = min(max(value, 0), 10)
        }
        self.structureKindWeights = mergedWeights
        self.waterColor = waterColor
        self.fogColor = fogColor
        self.fogDensity = max(0, fogDensity)
        self.ambientIntensity = min(max(0, ambientIntensity), 1)
        self.sunIntensity = min(max(0, sunIntensity), 2)
        self.continentScale = min(max(0.1, continentScale), 5.0)
        self.riverScale = min(max(0.1, riverScale), 5.0)
        self.mountainSharpness = min(max(0.1, mountainSharpness), 2.0)
        self.waterDeepColor = waterDeepColor
        self.waterShallowColor = waterShallowColor
        self.waveSpeed = min(max(0, waveSpeed), 3)
        self.waveAmplitude = min(max(0, waveAmplitude), 2)
        self.waterOpacity = min(max(0, waterOpacity), 1)
    }

    /// Sensible defaults for every field.
    public static var `default`: MTTerrainConfig {
        MTTerrainConfig()
    }

    /// Environment-aware defaults: `.simulator` in the Xcode Simulator,
    /// `.default` on device. Use this when you want the app to automatically
    /// pick the right settings.
    public static var auto: MTTerrainConfig {
        isSimulator ? .simulator : .default
    }

    /// Reduced settings for Xcode Simulator. The simulator does software
    /// Metal rendering (especially slow on Intel Macs), so this uses
    /// much lower geometry density and fewer chunks. Automatically selected
    /// by MTTerrainView when running in the simulator.
    public static var simulator: MTTerrainConfig {
        MTTerrainConfig(
            chunkResolution: 64,      // 16x fewer verts than 250
            chunkWorldSize: 1000,
            viewDistance: 3,          // fewer chunks to build/draw
            seaLevel: 0.45,
            heightScale: 400,
            structuresEnabled: true,
            structureDensity: 0.2     // fewer structures
        )
    }

    /// True when running in the Xcode Simulator (not on device).
    public static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
