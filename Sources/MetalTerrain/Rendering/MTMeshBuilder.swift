// MTMeshBuilder.swift — ORIGINAL code for the MetalTerrain library.
//
// Turns heightmap chunks into indexed triangle meshes: grid triangulation,
// per-vertex normals from central differences of the heightfield, and vertex
// colors from biomes (with border blending and slope-based cliffs).

import Foundation
import simd

// MARK: - Canonical vertex

/// The one shared vertex format for every MetalTerrain mesh.
///
/// Packed 20-byte layout (was 48 bytes as 3x SIMD4):
/// - position: 3x Float, 12 bytes — world-space XYZ
/// - normal:   UInt32, 4 bytes — octahedral-encoded unit normal (2x Int16)
/// - color:    UInt32, 4 bytes — RGBA8888; rgb = linear color 0...1,
///             a = material ID (0=grass, 1=rock, 2=sand, 3=snow,
///             4=deep snow, 5=water)
///
/// The color quantizes to 8 bits/channel (display precision — visually
/// lossless) and the normal uses octahedral encoding (max error ~0.01°,
/// visually lossless for terrain).
///
/// Layout: Swift lays out (Float, Float, Float, UInt32, UInt32) as
/// 12 + 4 + 4 = 20 bytes with 4-byte alignment — no padding. This must
/// match `MTVertexIn` in MTShaders.metal exactly (all scalar fields).
///
/// NOTE (cross-module contract): the sibling Structures module defines
/// `MTSimpleVertex { position/normal/color: SIMD3<Float> }`. Structure
/// meshes are copied field-by-field through the `MTVertex` inits below,
/// so the packing is applied uniformly to structures, terrain, and water.
public struct MTVertex {
    public var px: Float
    public var py: Float
    public var pz: Float
    public var normalXY: UInt32  // octahedral-encoded normal, 2x Int16 packed
    public var rgba: UInt32      // RGBA8888: rgb = color, a = material ID

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, color: SIMD3<Float>) {
        self.px = position.x
        self.py = position.y
        self.pz = position.z
        self.normalXY = Self.encodeNormal(normal)
        // Material defaults to 1 (rock), matching the old SIMD4(color, 1).
        self.rgba = Self.encodeColor(color, material: 1)
    }

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, color: SIMD4<Float>) {
        self.px = position.x
        self.py = position.y
        self.pz = position.z
        self.normalXY = Self.encodeNormal(normal)
        self.rgba = Self.encodeColor(SIMD3<Float>(color.x, color.y, color.z),
                                     material: Int(color.w.rounded()))
    }

    /// World-space position (unpacked).
    public var position: SIMD3<Float> { SIMD3<Float>(px, py, pz) }

    /// World-space unit normal (unpacked from octahedral encoding).
    public var normal: SIMD3<Float> { Self.decodeNormal(normalXY) }

    /// Linear RGB color with material ID in `w` (unpacked from RGBA8888).
    public var color: SIMD4<Float> {
        let r = Float(rgba & 0xFF) / 255.0
        let g = Float((rgba >> 8) & 0xFF) / 255.0
        let b = Float((rgba >> 16) & 0xFF) / 255.0
        let m = Float((rgba >> 24) & 0xFF)
        return SIMD4<Float>(r, g, b, m)
    }

    // MARK: Packing

    /// Octahedral-encode a unit normal into 2x Int16 packed in a UInt32.
    /// Projects onto the octahedron |x|+|y|+|z|=1 and unfolds the lower
    /// hemisphere. Max angular error ~0.01° — invisible on terrain.
    static func encodeNormal(_ n: SIMD3<Float>) -> UInt32 {
        let l1 = abs(n.x) + abs(n.y) + abs(n.z)
        guard l1 > 0 else { return 0 }
        let inv = 1.0 / l1
        var ex = n.x * inv
        var ey = n.y * inv
        if n.z < 0 {
            let ox = ex, oy = ey
            ex = (1.0 - abs(oy)) * (ox >= 0 ? 1.0 : -1.0)
            ey = (1.0 - abs(ox)) * (oy >= 0 ? 1.0 : -1.0)
        }
        let ix = UInt32(bitPattern: Int32(Int16((ex * 32767.0).rounded()))) & 0xFFFF
        let iy = UInt32(bitPattern: Int32(Int16((ey * 32767.0).rounded()))) & 0xFFFF
        return ix | (iy << 16)
    }

    /// Decode an octahedral-encoded normal (CPU-side; the GPU uses the
    /// matching `mtDecodeNormal` in MTShaders.metal).
    static func decodeNormal(_ packed: UInt32) -> SIMD3<Float> {
        let ex = Float(Int16(bitPattern: UInt16(packed & 0xFFFF))) / 32767.0
        let ey = Float(Int16(bitPattern: UInt16((packed >> 16) & 0xFFFF))) / 32767.0
        var n = SIMD3<Float>(ex, ey, 1.0 - abs(ex) - abs(ey))
        if n.z < 0 {
            let ox = n.x, oy = n.y
            n.x = (1.0 - abs(oy)) * (ox >= 0 ? 1.0 : -1.0)
            n.y = (1.0 - abs(ox)) * (oy >= 0 ? 1.0 : -1.0)
        }
        return normalize(n)
    }

    /// Pack an RGB color (0...1) and material ID into RGBA8888.
    static func encodeColor(_ c: SIMD3<Float>, material: Int) -> UInt32 {
        let r = UInt32(min(max((c.x * 255.0).rounded(), 0), 255))
        let g = UInt32(min(max((c.y * 255.0).rounded(), 0), 255))
        let b = UInt32(min(max((c.z * 255.0).rounded(), 0), 255))
        let m = UInt32(min(max(material, 0), 255))
        return r | (g << 8) | (b << 16) | (m << 24)
    }
}

// MARK: - Mesh builder

/// Builds indexed triangle meshes from terrain data. All methods are pure
/// functions of their inputs and safe to call from a background queue.
public enum MTMeshBuilder {

    /// Biome colors blend toward the neighboring biome within this normalized
    /// height distance of a biome border.
    private static let biomeBlendRange: Float = 0.12

    /// Slopes steeper than this (1 - normal.y) use the biome's slopeColor.
    private static let cliffSlopeThreshold: Float = 0.55

    // MARK: Terrain

    /// Builds a full-resolution indexed mesh for a chunk.
    ///
    /// - Parameters:
    ///   - chunk: the chunk to mesh (`heights` are normalized 0...1).
    ///   - world: the world; supplies world-space Y (`worldY(forHeight:)`),
    ///     biome lookup (`biomeAt(height:)`), and config (chunk size,
    ///     height scale, sea level).
    /// - Returns: vertices, `UInt32` indices (two CCW triangles per quad),
    ///   and the grid size `n` (vertices per side, for index-buffer sharing).
    public static func buildTerrainMesh(
        chunk: MTChunk,
        world: MTTerrainWorld
    ) -> (vertices: [MTVertex], indices: [UInt32], gridN: Int) {
        buildGrid(chunk: chunk, world: world, stride: 1)
    }

    /// Builds a mesh for a chunk at a level of detail chosen by
    /// `distanceFactor` (0 = at the camera, 1 = edge of view distance).
    /// Chunks near the player use full resolution; distant chunks use half
    /// resolution. The skirts hide T-junction cracks between LOD levels.
    public static func buildLOD(
        for chunk: MTChunk,
        world: MTTerrainWorld,
        distanceFactor: Float
    ) -> (vertices: [MTVertex], indices: [UInt32], gridN: Int) {
        // LOD disabled: T-junction vertex mismatches cause visible cracks.
        // The 5x build speedup makes full-res everywhere fast enough.
        // TODO: implement proper border stitching to re-enable LOD.
        buildGrid(chunk: chunk, world: world, stride: 1)
    }

    // MARK: Shared index buffers

    /// Cache of grid+skirt index arrays keyed by grid size `n`.
    /// The topology is identical for every chunk at a given resolution,
    /// so the index array is built once and shared.
    private static var indexCache: [Int: [UInt32]] = [:]
    private static let indexCacheLock = NSLock()

    /// Grid + skirt indices for an n×n vertex grid. Pure function of `n`;
    /// the result is cached because every chunk at the same resolution
    /// shares it. The renderer caches the corresponding MTLBuffers.
    public static func cachedIndices(n: Int) -> [UInt32] {
        indexCacheLock.lock()
        defer { indexCacheLock.unlock() }
        if let cached = indexCache[n] { return cached }
        var indices = gridIndices(n: n)
        indices.append(contentsOf: skirtIndices(n: n, base: UInt32(n * n)))
        indexCache[n] = indices
        return indices
    }

    /// Skirt quad indices for an n×n grid whose vertices start at 0 and
    /// whose skirt vertices start at `base`. Pure function of (n, base).
    private static func skirtIndices(n: Int, base: UInt32) -> [UInt32] {
        var edge: [UInt32] = []
        edge.reserveCapacity(4 * n)
        for a in 0..<n { edge.append(UInt32(a)) }                                        // j = 0
        for b in 1..<n { edge.append(UInt32(b * n + (n - 1))) }                          // i = n-1
        for a in stride(from: n - 2, through: 0, by: -1) { edge.append(UInt32((n - 1) * n + a)) } // j = n-1
        for b in stride(from: n - 2, through: 1, by: -1) { edge.append(UInt32(b * n)) }  // i = 0
        var indices: [UInt32] = []
        indices.reserveCapacity(edge.count * 6)
        for (k, vi) in edge.enumerated() {
            let si = base + UInt32(k)
            let sj = base + UInt32((k + 1) % edge.count)
            let vj = edge[(k + 1) % edge.count]
            // Outward-facing quad: (vi, vj, sj), (vi, sj, si)
            indices.append(contentsOf: [vi, vj, sj, vi, sj, si])
        }
        return indices
    }

    // MARK: Water

    /// Builds a flat water plane centered on the XZ origin.
    ///
    /// The renderer recenters it on the camera target with a model matrix,
    /// so the plane itself is built once around (0, 0).
    public static func buildWaterMesh(
        size: Float,
        level: Float,
        color: SIMD3<Float> = SIMD3<Float>(0.16, 0.42, 0.66)
    ) -> (vertices: [MTVertex], indices: [UInt32], gridN: Int) {
        let segments = 64
        let n = segments + 1
        var vertices: [MTVertex] = []
        vertices.reserveCapacity(n * n)
        for b in 0..<n {
            for a in 0..<n {
                let x = (Float(a) / Float(segments) - 0.5) * size
                let z = (Float(b) / Float(segments) - 0.5) * size
                vertices.append(MTVertex(
                    position: SIMD3<Float>(x, level, z),
                    normal: SIMD3<Float>(0, 1, 0),
                    color: color
                ))
            }
        }
        // Water has no skirt and is built once (not per chunk);
        // grid indices are cheap here.
        return (vertices, gridIndices(n: n), n)
    }

    // MARK: Structures

    /// Builds one low-poly mesh per structure kind by calling into the
    /// sibling Structures module.
    ///
    /// Expected sibling contract (see Structures/MTStructures.swift):
    /// `MTStructureBuilder.mesh(for: MTStructureKind) -> (vertices: [MTSimpleVertex], indices: [UInt32])`,
    /// where `MTSimpleVertex` is layout-identical to `MTVertex` (see note on
    /// `MTVertex`). Vertices are copied field-by-field for safety.
    public static func buildStructureMeshes(
        kinds: [MTStructureKind] = MTStructureKind.allCases
    ) -> [MTStructureKind: (vertices: [MTVertex], indices: [UInt32])] {
        var out: [MTStructureKind: (vertices: [MTVertex], indices: [UInt32])] = [:]
        out.reserveCapacity(kinds.count)
        for kind in kinds {
            // Cross-module call into the sibling's builder.
            let mesh = MTStructureBuilder.mesh(for: kind)
            let verts = mesh.vertices.map {
                MTVertex(position: $0.position, normal: $0.normal, color: $0.color)
            }
            out[kind] = (verts, mesh.indices)
        }
        return out
    }

    // MARK: - Internals

    /// Gridded mesh builder. `stride` picks every stride-th vertex per side
    /// (1 = full resolution, 2 = half).
    private static func buildGrid(
        chunk: MTChunk,
        world: MTTerrainWorld,
        stride: Int
    ) -> (vertices: [MTVertex], indices: [UInt32], gridN: Int) {
        let res = chunk.resolution
        precondition(res >= 2, "MTChunk resolution must be >= 2")
        precondition(chunk.heights.count == res * res,
                     "MTChunk heights must hold resolution*resolution values")

        let step = max(1, stride)
        // Vertex count per side at this stride. The far edge always lands
        // exactly on the chunk border (res - 1) so neighboring chunks stay
        // aligned — the last strip may be narrower than `step`, which is
        // fine, but a missing border vertex would open a visible crack.
        let n = (res - 1) / step + 1
        let cfg = world.config
        let worldSize = cfg.chunkWorldSize
        let cell = worldSize / Float(res - 1)   // world units per height sample
        let originX = Float(chunk.coord.x) * worldSize
        let originZ = Float(chunk.coord.z) * worldSize
        // Hoist biomes once: biomeAt does 2 locks + array concat per call,
        // and groundColor calls it up to 3x per vertex (190K allocs/chunk).
        let biomes = world.allBiomes
        let heightScale = cfg.heightScale
        // H3: hoist noise pair for lock-free border normal sampling.
        // world.heightAt() takes 2 locks per call; we do ~1000 border
        // samples per chunk. Using mtHeightSample directly avoids all locks.
        let (meshNoise, meshWarpNoise) = world.noisePair()
        let meshField = MTHeightFieldConfig(base: cfg.noise,
                                            continentScale: cfg.continentScale,
                                            riverScale: cfg.riverScale,
                                            mountainSharpness: cfg.mountainSharpness)

        // Heights are UInt16 quantized (0...65535 maps to 0...1).
        func h(_ i: Int, _ j: Int) -> Float {
            Float(chunk.heights[j * res + i]) / 65535.0
        }

        var vertices: [MTVertex] = []
        vertices.reserveCapacity(n * n)
        for b in 0..<n {
            // Clamp the final row/column onto the chunk border.
            let j = (b == n - 1) ? res - 1 : b * step
            for a in 0..<n {
                let i = (a == n - 1) ? res - 1 : a * step
                let height = h(i, j)

                // Central differences of the heightfield -> world-space normal.
                // At chunk borders, sample the true neighbor height via
                // mtHeightSample (not clamped) so adjacent chunks compute
                // identical normals — fixes visible lighting seams.
                // Uses hoisted noise pair (no locks) instead of world.heightAt.
                let wx = originX + Float(i) / Float(res - 1) * worldSize
                let wz = originZ + Float(j) / Float(res - 1) * worldSize
                let hL: Float, hR: Float, hD: Float, hU: Float
                if i == 0 {
                    hL = mtHeightSampleField(x: Double(wx - cell), y: Double(wz), field: meshField, noise: meshNoise, warpNoise: meshWarpNoise)
                    hR = h(i + 1, j)
                } else if i == res - 1 {
                    hL = h(i - 1, j)
                    hR = mtHeightSampleField(x: Double(wx + cell), y: Double(wz), field: meshField, noise: meshNoise, warpNoise: meshWarpNoise)
                } else {
                    hL = h(i - 1, j)
                    hR = h(i + 1, j)
                }
                if j == 0 {
                    hD = mtHeightSampleField(x: Double(wx), y: Double(wz - cell), field: meshField, noise: meshNoise, warpNoise: meshWarpNoise)
                    hU = h(i, j + 1)
                } else if j == res - 1 {
                    hD = h(i, j - 1)
                    hU = mtHeightSampleField(x: Double(wx), y: Double(wz + cell), field: meshField, noise: meshNoise, warpNoise: meshWarpNoise)
                } else {
                    hD = h(i, j - 1)
                    hU = h(i, j + 1)
                }
                let dYdx = cfg.heightScale * (hR - hL) / (2 * cell)
                let dYdz = cfg.heightScale * (hU - hD) / (2 * cell)
                let normal = normalize(SIMD3<Float>(-dYdx, 1.0, -dYdz))

                let wy = height * heightScale

                let (rgb, material) = groundColor(height: height, normalY: normal.y,
                                                   biomes: biomes)
                vertices.append(MTVertex(
                    position: SIMD3<Float>(wx, wy, wz),
                    normal: normal,
                    color: SIMD4<Float>(rgb, material)  // material ID in alpha
                ))
            }
        }
        var allVertices = vertices
        // Solid terrain: add vertical skirts around the chunk edges so the
        // world looks like a solid block, not a floating sheet. The skirt
        // drops straight down from each edge vertex.
        appendSkirtVertices(vertices: &allVertices, n: n,
                            world: world)
        // Grid + skirt indices are topology-fixed for a given n — shared
        // across all chunks via the cache (saves ~1.5MB per chunk).
        return (allVertices, cachedIndices(n: n), n)
    }

    /// Appends skirt vertices (not indices) around the chunk border. Each
    /// edge vertex gets a duplicate pushed straight down; see `skirtIndices`
    /// for the quad topology, which is shared via `cachedIndices`.
    private static func appendSkirtVertices(
        vertices: inout [MTVertex],
        n: Int,
        world: MTTerrainWorld
    ) {
        let skirtDepth = world.config.heightScale * 0.35 + 10
        // Collect edge vertices in order: bottom, right, top, left.
        // L2: track edge index for axis-aligned normals (no sqrt needed).
        var edge: [UInt32] = []
        var edgeNormal: [SIMD3<Float>] = []
        edge.reserveCapacity(4 * n)
        edgeNormal.reserveCapacity(4 * n)
        let bottomN = SIMD3<Float>(0, 0, -1)
        let rightN = SIMD3<Float>(1, 0, 0)
        let topN = SIMD3<Float>(0, 0, 1)
        let leftN = SIMD3<Float>(-1, 0, 0)
        for a in 0..<n { edge.append(UInt32(a)); edgeNormal.append(bottomN) }                    // j = 0
        for b in 1..<n { edge.append(UInt32(b * n + (n - 1))); edgeNormal.append(rightN) }      // i = n-1
        for a in stride(from: n - 2, through: 0, by: -1) { edge.append(UInt32((n - 1) * n + a)); edgeNormal.append(topN) } // j = n-1
        for b in stride(from: n - 2, through: 1, by: -1) { edge.append(UInt32(b * n)); edgeNormal.append(leftN) }          // i = 0

        for (k, vi) in edge.enumerated() {
            let v = vertices[Int(vi)]
            let p = v.position
            let c = v.color
            // L2: axis-aligned outward normal (no sqrt).
            let nrm = edgeNormal[k]
            vertices.append(MTVertex(
                position: SIMD3<Float>(p.x, p.y - skirtDepth, p.z),
                normal: nrm,
                color: SIMD3<Float>(c.x * 0.55, c.y * 0.55, c.z * 0.55)
            ))
        }
    }

    /// Two triangles per quad, wound counter-clockwise seen from +Y so they
    /// are front-facing with Metal's default frontFace winding.
    private static func gridIndices(n: Int) -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity((n - 1) * (n - 1) * 6)
        for b in 0..<(n - 1) {
            for a in 0..<(n - 1) {
                let v00 = UInt32(b * n + a)
                let v10 = UInt32(b * n + a + 1)
                let v01 = UInt32((b + 1) * n + a)
                let v11 = UInt32((b + 1) * n + a + 1)
                // Counter-clockwise when viewed from +Y (above): Metal's
                // front face. Was clockwise -> terrain invisible from above.
                indices.append(contentsOf: [v00, v10, v11, v00, v11, v01])
            }
        }
        return indices
    }

    /// Vertex color for a terrain sample: biome ground color, blended toward
    /// the neighboring biome near height borders, overridden by the biome's
    /// slope color on steep slopes (cliffs).
    /// Lock-free biome lookup on a hoisted array. Identical logic to
    /// MTTerrainWorld.biomeAt but without locks or array concatenation.
    /// Called ~190K times per chunk — must stay allocation-free.
    private static func biomeAt(height h: Float, in biomes: [MTBiome]) -> MTBiome {
        for biome in biomes {
            if h >= biome.minHeight && h <= biome.maxHeight {
                return biome
            }
        }
        return biomes.last ?? biomes[0]
    }

    /// Vertex ground color: biome ground color, blended toward the
    /// neighboring biome near height borders, overridden by the biome's
    /// slope color on steep slopes (cliffs). Delegates to baseGroundColor.
    private static func groundColor(
        height h: Float,
        normalY: Float,
        biomes: [MTBiome]
    ) -> (SIMD3<Float>, Float) {
        return baseGroundColor(height: h, normalY: normalY, biomes: biomes)
    }

    private static func baseGroundColor(
        height h: Float,
        normalY: Float,
        biomes: [MTBiome]
    ) -> (SIMD3<Float>, Float) {
        let biome = biomeAt(height: h, in: biomes)
        // Material ID for per-material specular: 0=grass, 1=rock, 2=sand,
        // 3=snow, 4=deep snow, 5=water.
        // M2: uses precomputed biome.materialID (no per-vertex string switch).
        // Note: snowyPeak uses 3, but h > 0.92 upgrades to 4 (deep snow) below.
        let material: Float = biome.materialID == 3 && h > 0.92 ? 4 : biome.materialID
        let slope = 1.0 - normalY
        // On mountains (high altitude), force rock to prevent grass/forest
        // banding from height oscillation. Wide threshold (0.65) ensures
        // no grass stripes appear on mountainsides.
        if h > 0.65 {
            // Blend to snow at the top, rock below.
            if h > 0.80 {
                let t = min(1.0, (h - 0.80) / 0.12)
                let rock = SIMD3<Float>(0.45, 0.42, 0.38)
                let snow = SIMD3<Float>(0.90, 0.92, 0.95)
                let c = rock + (snow - rock) * t
                return (c, h > 0.92 ? 4 : 3)  // snow materials
            }
            return (SIMD3<Float>(0.45, 0.42, 0.38), 1)  // rock, no banding
        }
        if slope > cliffSlopeThreshold, let cliff = biome.slopeColor {
            return (cliff, 1)  // cliffs are rock
        }
        var color = biome.groundColor
        let e = biomeBlendRange
        if h > biome.maxHeight - e {
            // Near the top border: blend toward the biome above.
            let above = biomeAt(height: min(h + e, 1.0), in: biomes)
            if above.name != biome.name {
                let t = smooth01((biome.maxHeight - h) / e)
                color = mix(above.groundColor, color, t: t)
            }
        } else if h < biome.minHeight + e {
            // Near the bottom border: blend toward the biome below.
            let below = biomeAt(height: max(h - e, 0.0), in: biomes)
            if below.name != biome.name {
                let t = smooth01((h - biome.minHeight) / e)
                color = mix(below.groundColor, color, t: t)
            }
        }
        // Emissive biomes (e.g. alien crystal fields) glow: boost the vertex
        // color so the lighting pass reads them as self-lit.
        if biome.emitsLight {
            color = min(color * 1.6 + SIMD3<Float>(repeating: 0.12),
                        SIMD3<Float>(repeating: 1.0))
        }
        return (color, material)
    }

    /// Linear interpolation for SIMD3 colors (Metal's `mix` has no Swift equivalent).
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    private static func smooth01(_ t: Float) -> Float {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
