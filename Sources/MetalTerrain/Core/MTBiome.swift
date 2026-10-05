// MTBiome.swift
// MetalTerrain — height-keyed biomes with vertex colors.

import Foundation

/// A height band of terrain with its own coloring rules.
/// Matches DESIGN.md exactly.
public struct MTBiome {
    public var name: String
    public var minHeight: Float   // normalized 0...1, inclusive
    public var maxHeight: Float   // normalized 0...1, exclusive
    public var groundColor: SIMD3<Float>  // linear RGB 0...1
    public var slopeColor: SIMD3<Float>?  // steep-slope override (cliffs)
    public var emitsLight: Bool           // e.g. lava biome

    public init(name: String, minHeight: Float, maxHeight: Float,
                groundColor: SIMD3<Float>, slopeColor: SIMD3<Float>? = nil,
                emitsLight: Bool = false) {
        self.name = name
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.groundColor = groundColor
        self.slopeColor = slopeColor
        self.emitsLight = emitsLight
    }
}

extension MTBiome {
    /// Built-in biome ladder, mirroring the sb_terrain height thresholds:
    /// deep ocean → ocean → beach → grass → forest → mountain → snowy peak.
    /// Colors are linear RGB.
    public static var `default`: [MTBiome] {
        [
            MTBiome(name: "deepOcean", minHeight: 0.00, maxHeight: 0.32,
                    groundColor: SIMD3<Float>(0.02, 0.12, 0.30)),
            MTBiome(name: "ocean", minHeight: 0.32, maxHeight: 0.45,
                    groundColor: SIMD3<Float>(0.05, 0.28, 0.55)),
            MTBiome(name: "beach", minHeight: 0.40, maxHeight: 0.52,
                    groundColor: SIMD3<Float>(0.85, 0.75, 0.55)),
            MTBiome(name: "grass", minHeight: 0.52, maxHeight: 0.62,
                    groundColor: SIMD3<Float>(0.25, 0.55, 0.20)),
            MTBiome(name: "forest", minHeight: 0.62, maxHeight: 0.72,
                    groundColor: SIMD3<Float>(0.12, 0.38, 0.12)),
            MTBiome(name: "mountain", minHeight: 0.72, maxHeight: 0.80,
                    groundColor: SIMD3<Float>(0.45, 0.42, 0.38),
                    slopeColor: SIMD3<Float>(0.32, 0.30, 0.28)),
            MTBiome(name: "snowyPeak", minHeight: 0.80, maxHeight: 1.00,
                    groundColor: SIMD3<Float>(0.90, 0.92, 0.95),
                    slopeColor: SIMD3<Float>(0.55, 0.56, 0.58)),
        ]
    }
}
