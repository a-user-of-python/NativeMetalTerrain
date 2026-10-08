// MTRoadGeometry.swift
// MetalTerrain — builds renderable triangle meshes from road polylines.
//
// Each road becomes a ribbon following the terrain (+0.35m). Segments over
// water become bridge decks (elevated, with support pillars). Output is a
// single indexed triangle list per chunk with per-vertex UVs for procedural
// lane markings in the shader.

import Foundation
import simd

/// CPU-side road vertex. Must match `MTRoadVertexIn` in MTShaders.metal.
/// Uses SIMD4 for position (16 bytes) to match Metal's float4 alignment.
/// Layout: 16 (pos) + 8 (uv) + 4 (kind) + 4 (bridge) = 32 bytes, no padding.
struct MTRoadVertex {
    var position: SIMD4<Float>  // xyz = world position, w unused
    var uv: SIMD2<Float>       // u = meters along road, v = -1...1 across
    var kind: Float            // 0 = highway, 1 = ramp, 2 = street, 3 = pillar
    var bridge: Float          // 1 on bridge decks and pillars

    static var stride: Int { 32 }
}

/// Baked road mesh for one chunk.
struct MTRoadMesh {
    var vertices: [MTRoadVertex]
    var indices: [UInt32]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var isEmpty: Bool { vertices.isEmpty }
}

class MTRoadGeometry {
    /// Resample spacing along the road centerline.
    private static let step: Float = 8
    /// Vertical offset of pavement above terrain.
    private static let lift: Float = 0.35
    /// Bridge deck height above sea level.
    private static let bridgeClearance: Float = 6

    /// Build a road mesh for road paths in a chunk.
    /// - Parameters:
    ///   - paths: road polylines (world XZ) intersecting the chunk
    ///   - world: terrain world for height sampling
    static func build(paths: [MTRoadPath], world: MTTerrainWorld) -> MTRoadMesh {
        var verts: [MTRoadVertex] = []
        var idx: [UInt32] = []
        var bMin = SIMD3<Float>(Float.greatestFiniteMagnitude,
                                Float.greatestFiniteMagnitude,
                                Float.greatestFiniteMagnitude)
        var bMax = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                                -Float.greatestFiniteMagnitude,
                                -Float.greatestFiniteMagnitude)
        func track(_ p: SIMD3<Float>) {
            bMin = min(bMin, p); bMax = max(bMax, p)
        }

        let seaY = world.worldY(forHeight: world.config.seaLevel)

        for path in paths {
            let pts = resample(path.points, step: step)
            guard pts.count >= 2 else { continue }
            // Smooth centerline heights (moving average) so roads don't
            // jitter over terrain noise.
            var heights = pts.map { sampleHeight($0, world: world) }
            heights = smooth(heights, passes: 2)
            let kindF = Float(path.kind.rawValue)
            let half = path.width / 2
            var dist: Float = 0
            // Track the vertex index of each cross-section's left vertex.
            // (Pillars add extra vertices, so we can't use i*2 directly.)
            var leftIndices: [UInt32] = []
            for i in 0..<pts.count {
                let p = pts[i]
                // Tangent from neighbors.
                let pPrev = pts[max(0, i - 1)]
                let pNext = pts[min(pts.count - 1, i + 1)]
                var tangent = pNext - pPrev
                let tl = length(tangent)
                tangent = tl > 1e-6 ? tangent / tl : SIMD2<Float>(1, 0)
                let n = SIMD2<Float>(-tangent.y, tangent.x)
                if i > 0 { dist += length(pts[i] - pts[i - 1]) }

                let h = heights[i]
                let overWater = h < seaY
                let deckY: Float
                let isBridge: Float
                if overWater {
                    deckY = seaY + bridgeClearance
                    isBridge = 1
                } else {
                    deckY = h + lift
                    isBridge = 0
                }
                let l = SIMD3<Float>(p.x - n.x * half, deckY, p.y - n.y * half)
                let r = SIMD3<Float>(p.x + n.x * half, deckY, p.y + n.y * half)
                leftIndices.append(UInt32(verts.count))
                verts.append(MTRoadVertex(position: SIMD4<Float>(l, 1), uv: SIMD2<Float>(dist, -1),
                                          kind: kindF, bridge: isBridge))
                verts.append(MTRoadVertex(position: SIMD4<Float>(r, 1), uv: SIMD2<Float>(dist, 1),
                                          kind: kindF, bridge: isBridge))
                track(l); track(r)

                // Bridge pillars every ~24m down to the terrain/waterbed.
                if overWater && i % 3 == 0 {
                    addPillar(at: SIMD2<Float>(p.x, p.y), topY: deckY,
                              groundY: h - 2, width: min(half * 0.5, 2.5),
                              verts: &verts, idx: &idx, track: track)
                }

                if i > 0 {
                    let a = leftIndices[i - 1]
                    let b = leftIndices[i]
                    idx.append(contentsOf: [a, a + 1, b, a + 1, b + 1, b])
                }
            }
        }

        if verts.isEmpty {
            bMin = SIMD3<Float>(0, 0, 0); bMax = SIMD3<Float>(0, 0, 0)
        }
        return MTRoadMesh(vertices: verts, indices: idx, boundsMin: bMin, boundsMax: bMax)
    }

    // MARK: - Helpers

    /// Resample a polyline to roughly uniform spacing.
    private static func resample(_ pts: [SIMD2<Float>], step: Float) -> [SIMD2<Float>] {
        guard pts.count >= 2 else { return pts }
        var out: [SIMD2<Float>] = [pts[0]]
        var carry: Float = 0
        for i in 1..<pts.count {
            var segStart = pts[i - 1]
            let segEnd = pts[i]
            var segLen = length(segEnd - segStart)
            var dir = segLen > 1e-6 ? (segEnd - segStart) / segLen : SIMD2<Float>(0, 0)
            while carry + segLen >= step {
                let need = step - carry
                segStart += dir * need
                segLen -= need
                out.append(segStart)
                carry = 0
                if segLen > 1e-6 { dir = (segEnd - segStart) / segLen }
            }
            carry += segLen
        }
        if let last = pts.last, length(last - (out.last ?? last)) > 1 {
            out.append(last)
        }
        return out
    }

    /// Terrain world Y at XZ.
    private static func sampleHeight(_ p: SIMD2<Float>, world: MTTerrainWorld) -> Float {
        world.worldY(forHeight: world.heightAt(x: Double(p.x), z: Double(p.y)))
    }

    /// Simple moving-average smoothing.
    private static func smooth(_ h: [Float], passes: Int) -> [Float] {
        var cur = h
        for _ in 0..<passes {
            var nxt = cur
            for i in 0..<cur.count {
                let a = cur[max(0, i - 1)], b = cur[i], c = cur[min(cur.count - 1, i + 1)]
                nxt[i] = (a + b * 2 + c) / 4
            }
            cur = nxt
        }
        return cur
    }

    /// Axis-aligned box pillar from deck down to ground. kind=3 (no markings).
    private static func addPillar(at p: SIMD2<Float>, topY: Float, groundY: Float,
                                 width: Float,
                                 verts: inout [MTRoadVertex], idx: inout [UInt32],
                                 track: (SIMD3<Float>) -> Void) {
        let hw = width
        // 8 corners.
        let c: [SIMD3<Float>] = [
            SIMD3<Float>(p.x - hw, groundY, p.y - hw), SIMD3<Float>(p.x + hw, groundY, p.y - hw),
            SIMD3<Float>(p.x + hw, groundY, p.y + hw), SIMD3<Float>(p.x - hw, groundY, p.y + hw),
            SIMD3<Float>(p.x - hw, topY, p.y - hw), SIMD3<Float>(p.x + hw, topY, p.y - hw),
            SIMD3<Float>(p.x + hw, topY, p.y + hw), SIMD3<Float>(p.x - hw, topY, p.y + hw),
        ]
        let base = UInt32(verts.count)
        for (i, corner) in c.enumerated() {
            // v coordinate spreads around the pillar so the shader
            // doesn't draw lane lines on it (kind=3 skips markings anyway).
            verts.append(MTRoadVertex(position: SIMD4<Float>(corner, 1), uv: SIMD2<Float>(Float(i) * 2, 0),
                                      kind: 3, bridge: 1))
            track(corner)
        }
        // 12 triangles (outward faces; cull mode handles the rest).
        let faces: [[UInt32]] = [
            [0, 1, 2, 0, 2, 3],       // bottom (unseen)
            [4, 6, 5, 4, 7, 6],       // top (under deck)
            [0, 4, 5, 0, 5, 1],       // -x side... (approx normals fine)
            [1, 5, 6, 1, 6, 2],
            [2, 6, 7, 2, 7, 3],
            [3, 7, 4, 3, 4, 0],
        ]
        for f in faces { idx.append(contentsOf: f.map { $0 + base }) }
    }
}
