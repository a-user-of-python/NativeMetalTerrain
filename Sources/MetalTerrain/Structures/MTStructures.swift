// MTStructures.swift
// MetalTerrain — structure kinds, placements, and procedural low-poly meshes.
//
// Original code: every mesh below is built fresh from boxes, prisms,
// cylinders, cones, and displaced spheres. Meshes are unit-ish in scale
// (a few world units tall, base at y = 0) and get their world transform
// from MTStructurePlacement (position / rotationY / scale).

import Foundation
import simd

// MARK: - Shared minimal vertex

/// Minimal vertex used by the structure meshes: position, normal, and
/// color (float3 each) — the same layout as the terrain vertex format.
///
/// NOTE (renderer child): this intentionally does NOT define `MTVertex`
/// to avoid a duplicate-symbol clash. The renderer's `MTVertex` should
/// be layout-identical (`position`/`normal`/`color` as SIMD3<Float>);
/// convert field-wise, e.g.
/// `MTVertex(position: v.position, normal: v.normal, color: v.color)`.
public struct MTSimpleVertex {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var color: SIMD3<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>,
                color: SIMD3<Float>) {
        self.position = position
        self.normal = normal
        self.color = color
    }
}

// MARK: - Kinds & placements

/// The seven placeable structure kinds.
public enum MTStructureKind: String, CaseIterable {
    case house, tower, tree, boulder, well, windmill, dungeon
}

/// Where (and how) to draw one structure instance.
public struct MTStructurePlacement {
    public var kind: MTStructureKind
    public var position: SIMD3<Float>  // world coords, y = terrain height
    public var rotationY: Float        // radians about Y
    public var scale: Float            // uniform scale

    public init(kind: MTStructureKind, position: SIMD3<Float>,
                rotationY: Float, scale: Float) {
        self.kind = kind
        self.position = position
        self.rotationY = rotationY
        self.scale = scale
    }
}

// MARK: - Mesh builder

/// Builds the low-poly mesh for a structure kind.
/// Deterministic: `mesh(for:)` always returns identical geometry.
public enum MTStructureBuilder {
    public static func mesh(for kind: MTStructureKind)
        -> (vertices: [MTSimpleVertex], indices: [UInt32])
    {
        var m = MTMeshAccumulator()
        switch kind {
        case .house: buildHouse(&m)
        case .tower: buildTower(&m)
        case .tree: buildTree(&m)
        case .boulder: buildBoulder(&m)
        case .well: buildWell(&m)
        case .windmill: buildWindmill(&m)
        case .dungeon: buildDungeon(&m)
        }
        return (m.vertices, m.indices)
    }
}

// MARK: - Mesh accumulator (private helpers)

/// Collects vertices/indices with flat (per-face) normals.
/// Winding: counter-clockwise when viewed from outside; the normal is
/// `normalize(cross(b - a, c - a))` for `quad(a, b, c, d)` / `tri(a, b, c)`.
private struct MTMeshAccumulator {
    var vertices: [MTSimpleVertex] = []
    var indices: [UInt32] = []

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                       _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       color: SIMD3<Float>) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let base = UInt32(vertices.count)
        vertices.append(MTSimpleVertex(position: a, normal: n, color: color))
        vertices.append(MTSimpleVertex(position: b, normal: n, color: color))
        vertices.append(MTSimpleVertex(position: c, normal: n, color: color))
        vertices.append(MTSimpleVertex(position: d, normal: n, color: color))
        indices.append(contentsOf: [base, base + 1, base + 2,
                                    base, base + 2, base + 3])
    }

    /// Same quad emitted with both windings (for thin blades).
    mutating func quadDoubleSided(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                  _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                                  color: SIMD3<Float>) {
        quad(a, b, c, d, color: color)
        quad(a, d, c, b, color: color)
    }

    mutating func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                      _ c: SIMD3<Float>, color: SIMD3<Float>) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let base = UInt32(vertices.count)
        vertices.append(MTSimpleVertex(position: a, normal: n, color: color))
        vertices.append(MTSimpleVertex(position: b, normal: n, color: color))
        vertices.append(MTSimpleVertex(position: c, normal: n, color: color))
        indices.append(contentsOf: [base, base + 1, base + 2])
    }

    /// Axis-aligned box centered at `center` with full `size`.
    mutating func box(center: SIMD3<Float>, size: SIMD3<Float>,
                      color: SIMD3<Float>) {
        let e = size * 0.5
        // +X
        quad(center + SIMD3<Float>( e.x, -e.y,  e.z),
             center + SIMD3<Float>( e.x, -e.y, -e.z),
             center + SIMD3<Float>( e.x,  e.y, -e.z),
             center + SIMD3<Float>( e.x,  e.y,  e.z), color: color)
        // -X
        quad(center + SIMD3<Float>(-e.x, -e.y, -e.z),
             center + SIMD3<Float>(-e.x, -e.y,  e.z),
             center + SIMD3<Float>(-e.x,  e.y,  e.z),
             center + SIMD3<Float>(-e.x,  e.y, -e.z), color: color)
        // +Y
        quad(center + SIMD3<Float>(-e.x,  e.y, -e.z),
             center + SIMD3<Float>(-e.x,  e.y,  e.z),
             center + SIMD3<Float>( e.x,  e.y,  e.z),
             center + SIMD3<Float>( e.x,  e.y, -e.z), color: color)
        // -Y
        quad(center + SIMD3<Float>(-e.x, -e.y, -e.z),
             center + SIMD3<Float>( e.x, -e.y, -e.z),
             center + SIMD3<Float>( e.x, -e.y,  e.z),
             center + SIMD3<Float>(-e.x, -e.y,  e.z), color: color)
        // +Z
        quad(center + SIMD3<Float>(-e.x, -e.y,  e.z),
             center + SIMD3<Float>( e.x, -e.y,  e.z),
             center + SIMD3<Float>( e.x,  e.y,  e.z),
             center + SIMD3<Float>(-e.x,  e.y,  e.z), color: color)
        // -Z
        quad(center + SIMD3<Float>( e.x, -e.y, -e.z),
             center + SIMD3<Float>(-e.x, -e.y, -e.z),
             center + SIMD3<Float>(-e.x,  e.y, -e.z),
             center + SIMD3<Float>( e.x,  e.y, -e.z), color: color)
    }

    /// Triangular roof prism: ridge along Z, eaves at `baseY`.
    mutating func prism(baseY: Float, width: Float, height: Float,
                        depth: Float, color: SIMD3<Float>) {
        let w = width * 0.5, d = depth * 0.5, top = baseY + height
        // Left slope (faces -X/+Y).
        quad(SIMD3<Float>(-w, baseY, -d), SIMD3<Float>(-w, baseY, d),
             SIMD3<Float>(0, top, d), SIMD3<Float>(0, top, -d), color: color)
        // Right slope (faces +X/+Y).
        quad(SIMD3<Float>(w, baseY, d), SIMD3<Float>(w, baseY, -d),
             SIMD3<Float>(0, top, -d), SIMD3<Float>(0, top, d), color: color)
        // Front gable (-Z).
        tri(SIMD3<Float>(-w, baseY, -d), SIMD3<Float>(0, top, -d),
            SIMD3<Float>(w, baseY, -d), color: color)
        // Back gable (+Z).
        tri(SIMD3<Float>(-w, baseY, d), SIMD3<Float>(w, baseY, d),
            SIMD3<Float>(0, top, d), color: color)
    }

    /// Vertical cylinder centered on (centerX, centerZ).
    mutating func cylinder(centerX: Float = 0, centerZ: Float = 0,
                            baseY: Float, radiusTop: Float,
                            radiusBottom: Float, height: Float,
                            segments: Int, phase: Float = 0,
                            color: SIMD3<Float>,
                            cappedTop: Bool = true, cappedBottom: Bool = true) {
        let top = baseY + height
        var ringB: [SIMD3<Float>] = []
        var ringT: [SIMD3<Float>] = []
        for i in 0..<segments {
            let a = phase + Float(i) * 2 * Float.pi / Float(segments)
            let (s, c) = (sin(a), cos(a))
            ringB.append(SIMD3<Float>(centerX + radiusBottom * c, baseY,
                                      centerZ + radiusBottom * s))
            ringT.append(SIMD3<Float>(centerX + radiusTop * c, top,
                                      centerZ + radiusTop * s))
        }
        for i in 0..<segments {
            let j = (i + 1) % segments
            quad(ringB[i], ringT[i], ringT[j], ringB[j], color: color)
        }
        if cappedTop {
            let t = SIMD3<Float>(centerX, top, centerZ)
            for i in 0..<segments {
                let j = (i + 1) % segments
                tri(t, ringT[j], ringT[i], color: color)
            }
        }
        if cappedBottom {
            let b = SIMD3<Float>(centerX, baseY, centerZ)
            for i in 0..<segments {
                let j = (i + 1) % segments
                tri(b, ringB[i], ringB[j], color: color)
            }
        }
    }

    /// Cone (cylinder with an apex point).
    mutating func cone(centerX: Float = 0, centerZ: Float = 0,
                       baseY: Float, radius: Float, height: Float,
                       segments: Int, color: SIMD3<Float>) {
        let apex = SIMD3<Float>(centerX, baseY + height, centerZ)
        var ring: [SIMD3<Float>] = []
        for i in 0..<segments {
            let a = Float(i) * 2 * Float.pi / Float(segments)
            ring.append(SIMD3<Float>(centerX + radius * cos(a), baseY,
                                     centerZ + radius * sin(a)))
        }
        for i in 0..<segments {
            let j = (i + 1) % segments
            tri(ring[i], apex, ring[j], color: color)
        }
        let b = SIMD3<Float>(centerX, baseY, centerZ)
        for i in 0..<segments {
            let j = (i + 1) % segments
            tri(b, ring[i], ring[j], color: color)
        }
    }

    /// Rough rock: lat/long sphere with seeded radial displacement.
    mutating func displacedSphere(center: SIMD3<Float>, radius: Float,
                                  latBands: Int, lonSegments: Int,
                                  seed: UInt64, displacement: Float,
                                  color: SIMD3<Float>) {
        var rng = MTSeededRandom(seed: seed)
        // radii[j][i]: j = 0 (top pole) ... latBands (bottom pole),
        // i = 0 ... lonSegments. The seam column (i = lonSegments) duplicates
        // i = 0 exactly — independent randoms there would leave a visible
        // crack where phi wraps from 2π back to 0.
        var radii: [[Float]] = []
        for _ in 0...latBands {
            var row: [Float] = []
            for _ in 0..<lonSegments {
                row.append(radius * (1 + displacement
                    * (rng.nextFloat() * 2 - 1)))
            }
            row.append(row[0])  // close the seam
            radii.append(row)
        }
        func point(j: Int, i: Int) -> SIMD3<Float> {
            let theta = Float.pi * Float(j) / Float(latBands)
            let phi = 2 * Float.pi * Float(i) / Float(lonSegments)
            let r = radii[j][i]
            return center + SIMD3<Float>(r * sin(theta) * cos(phi),
                                         r * cos(theta),
                                         r * sin(theta) * sin(phi))
        }
        for j in 0..<latBands {
            for i in 0..<lonSegments {
                if j == 0 {
                    tri(point(j: 0, i: 0), point(j: 1, i: i + 1),
                        point(j: 1, i: i), color: color)
                } else if j == latBands - 1 {
                    tri(point(j: j, i: i), point(j: j, i: i + 1),
                        point(j: latBands, i: 0), color: color)
                } else {
                    quad(point(j: j, i: i), point(j: j, i: i + 1),
                         point(j: j + 1, i: i + 1), point(j: j + 1, i: i),
                         color: color)
                }
            }
        }
    }
}

// MARK: - Per-kind meshes (origin at base center, y = 0 at ground)

private func buildHouse(_ m: inout MTMeshAccumulator) {
    let plaster = SIMD3<Float>(0.82, 0.74, 0.62)
    let roof = SIMD3<Float>(0.55, 0.25, 0.15)
    let wood = SIMD3<Float>(0.30, 0.20, 0.12)
    let brick = SIMD3<Float>(0.45, 0.42, 0.40)
    m.box(center: SIMD3<Float>(0, 1.0, 0),
           size: SIMD3<Float>(3.0, 2.0, 2.4), color: plaster)
    m.prism(baseY: 2.0, width: 3.4, height: 1.3, depth: 2.8, color: roof)
    m.box(center: SIMD3<Float>(0.8, 2.9, 0.4),
           size: SIMD3<Float>(0.4, 1.0, 0.4), color: brick)
    m.box(center: SIMD3<Float>(0, 0.7, 1.21),
           size: SIMD3<Float>(0.7, 1.4, 0.06), color: wood)
}

private func buildTower(_ m: inout MTMeshAccumulator) {
    let stone = SIMD3<Float>(0.52, 0.50, 0.47)
    let dark = SIMD3<Float>(0.30, 0.29, 0.31)
    m.cylinder(baseY: 0, radiusTop: 1.1, radiusBottom: 1.3, height: 5.0,
               segments: 10, color: stone)
    m.cylinder(baseY: 5.0, radiusTop: 1.55, radiusBottom: 1.55, height: 0.45,
               segments: 10, color: stone)
    for i in 0..<8 {
        let a = Float(i) * Float.pi / 4
        m.box(center: SIMD3<Float>(1.35 * cos(a), 5.7, 1.35 * sin(a)),
               size: SIMD3<Float>(0.45, 0.5, 0.45), color: stone)
    }
    m.box(center: SIMD3<Float>(0, 0.9, 1.24),
           size: SIMD3<Float>(0.8, 1.8, 0.08), color: dark)
}

private func buildTree(_ m: inout MTMeshAccumulator) {
    let bark = SIMD3<Float>(0.35, 0.22, 0.12)
    let leaf1 = SIMD3<Float>(0.16, 0.42, 0.16)
    let leaf2 = SIMD3<Float>(0.20, 0.48, 0.18)
    m.cylinder(baseY: 0, radiusTop: 0.28, radiusBottom: 0.35, height: 1.6,
               segments: 7, color: bark)
    m.cone(baseY: 1.2, radius: 1.7, height: 2.2, segments: 9, color: leaf1)
    m.cone(baseY: 2.6, radius: 1.15, height: 1.8, segments: 9, color: leaf2)
}

private func buildBoulder(_ m: inout MTMeshAccumulator) {
    m.displacedSphere(center: SIMD3<Float>(0, 0.75, 0), radius: 1.0,
                      latBands: 6, lonSegments: 9, seed: 1234,
                      displacement: 0.22,
                      color: SIMD3<Float>(0.48, 0.46, 0.43))
}

private func buildWell(_ m: inout MTMeshAccumulator) {
    let stone = SIMD3<Float>(0.55, 0.53, 0.50)
    let dark = SIMD3<Float>(0.05, 0.06, 0.08)
    let wood = SIMD3<Float>(0.40, 0.28, 0.16)
    let roof = SIMD3<Float>(0.50, 0.30, 0.18)
    // Open-topped stone ring.
    m.cylinder(baseY: 0, radiusTop: 1.0, radiusBottom: 1.0, height: 1.0,
               segments: 10, color: stone, cappedTop: false)
    // Dark water disk inside.
    m.cylinder(baseY: 0.72, radiusTop: 0.8, radiusBottom: 0.8, height: 0.06,
               segments: 10, color: dark)
    // Posts + little roof.
    m.box(center: SIMD3<Float>(-0.85, 1.3, 0),
           size: SIMD3<Float>(0.18, 1.6, 0.18), color: wood)
    m.box(center: SIMD3<Float>(0.85, 1.3, 0),
           size: SIMD3<Float>(0.18, 1.6, 0.18), color: wood)
    m.prism(baseY: 2.1, width: 2.3, height: 0.6, depth: 1.2, color: roof)
}

private func buildWindmill(_ m: inout MTMeshAccumulator) {
    let wall = SIMD3<Float>(0.78, 0.70, 0.58)
    let cap = SIMD3<Float>(0.45, 0.28, 0.16)
    let blade = SIMD3<Float>(0.85, 0.82, 0.72)
    // Tapered square tower (4-sided cylinder rotated 45°).
    m.cylinder(baseY: 0, radiusTop: 0.85, radiusBottom: 1.25, height: 4.2,
               segments: 4, phase: Float.pi / 4, color: wall)
    m.cone(baseY: 4.2, radius: 1.0, height: 0.9, segments: 4, color: cap)
    // Hub + 4 blades on the +Z face.
    let hub = SIMD3<Float>(0, 3.6, 1.15)
    m.box(center: SIMD3<Float>(0, 3.6, 1.05),
           size: SIMD3<Float>(0.3, 0.3, 0.3), color: cap)
    for i in 0..<4 {
        let a = Float(i) * Float.pi / 2
        let dir = SIMD3<Float>(cos(a), sin(a), 0)
        let perp = SIMD3<Float>(-sin(a), cos(a), 0)
        let r0: Float = 0.25, r1: Float = 2.1, hw: Float = 0.22
        m.quadDoubleSided(hub + dir * r0 + perp * hw,
                          hub + dir * r1 + perp * hw,
                          hub + dir * r1 - perp * hw,
                          hub + dir * r0 - perp * hw,
                          color: blade)
    }
}

private func buildDungeon(_ m: inout MTMeshAccumulator) {
    let darkStone = SIMD3<Float>(0.30, 0.29, 0.31)
    let stone = SIMD3<Float>(0.36, 0.35, 0.37)
    let door = SIMD3<Float>(0.08, 0.07, 0.09)
    // Gate block with battlements.
    m.box(center: SIMD3<Float>(0, 1.5, 0),
           size: SIMD3<Float>(4.2, 3.0, 1.6), color: darkStone)
    for i in 0..<5 {
        m.box(center: SIMD3<Float>(Float(i) * 0.9 - 1.8, 3.25, 0),
               size: SIMD3<Float>(0.5, 0.5, 1.6), color: darkStone)
    }
    m.box(center: SIMD3<Float>(0, 1.1, 0.82),
           size: SIMD3<Float>(1.4, 2.2, 0.08), color: door)
    // Flanking towers with caps and crenellations.
    for sx in [-1.0, 1.0] as [Float] {
        let cx = 3.0 * sx
        m.cylinder(centerX: cx, baseY: 0, radiusTop: 1.05, radiusBottom: 1.15,
                   height: 5.2, segments: 9, color: stone)
        m.cylinder(centerX: cx, baseY: 5.2, radiusTop: 1.3, radiusBottom: 1.3,
                   height: 0.4, segments: 9, color: stone)
        for i in 0..<6 {
            let a = Float(i) * Float.pi / 3
            m.box(center: SIMD3<Float>(cx + 1.1 * cos(a), 5.85, 1.1 * sin(a)),
                   size: SIMD3<Float>(0.4, 0.5, 0.4), color: stone)
        }
    }
}
