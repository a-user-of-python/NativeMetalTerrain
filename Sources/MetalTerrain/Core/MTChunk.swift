// MTChunk.swift
// MetalTerrain — chunk coordinates and chunk heightmap data.

import Foundation

/// Integer chunk coordinate. Chunk (x, z) covers the world-space rect
/// `[x * chunkWorldSize, (x+1) * chunkWorldSize)` on X and likewise on Z.
public struct MTChunkCoord: Hashable, Comparable {
    public var x: Int
    public var z: Int

    public init(x: Int, z: Int) {
        self.x = x
        self.z = z
    }

    public static func < (lhs: MTChunkCoord, rhs: MTChunkCoord) -> Bool {
        (lhs.x, lhs.z) < (rhs.x, rhs.z)
    }
}

/// One chunk's heightmap: a `resolution × resolution` grid of normalized
/// heights in [0, 1], stored row-major (`index = iz * resolution + ix`).
public struct MTChunk {
    public var coord: MTChunkCoord
    public var heights: [Float]  // resolution*resolution, normalized 0...1
    public var resolution: Int

    public init(coord: MTChunkCoord, heights: [Float], resolution: Int) {
        self.coord = coord
        self.heights = heights
        self.resolution = resolution
    }

    /// Height at grid vertex (ix, iz); indices are clamped to the grid.
    public func height(ix: Int, iz: Int) -> Float {
        let cx = min(max(ix, 0), resolution - 1)
        let cz = min(max(iz, 0), resolution - 1)
        return heights[cz * resolution + cx]
    }
}
