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
///
/// Heights are quantized to UInt16 (0...65535 maps to 0...1): 6mm precision
/// at 400m height scale — invisible — at half the memory of Float.
public struct MTChunk {
    public var coord: MTChunkCoord
    public var heights: [UInt16]  // resolution*resolution, quantized 0...1
    public var resolution: Int
    /// Min/max height, computed during generation (M3: avoids two extra passes).
    public var minHeight: Float
    public var maxHeight: Float

    public init(coord: MTChunkCoord, heights: [UInt16], resolution: Int,
                minHeight: Float = 0, maxHeight: Float = 1) {
        self.coord = coord
        self.heights = heights
        self.resolution = resolution
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }

    /// Height at grid vertex (ix, iz); indices are clamped to the grid.
    public func height(ix: Int, iz: Int) -> Float {
        let cx = min(max(ix, 0), resolution - 1)
        let cz = min(max(iz, 0), resolution - 1)
        return Float(heights[cz * resolution + cx]) / 65535.0
    }
}
