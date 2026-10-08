// MTRoadNetwork.swift
// MetalTerrain — deterministic infinite procedural road network.
//
// Design:
// - Highways are infinite parametric curves (direction + sinusoidal lateral
//   offset), fully determined by the world seed. Any chunk can sample the
//   curve segment passing through it — no global state, infinite by construction.
// - Highways cross each other (different angles guarantee intersection);
//   crossings get simple diamond interchanges with 4 curved ramps.
// - Towns sit alongside highways at deterministic intervals; each town has a
//   jittered street grid connected to its highway by a connector road.
// - Result: one connected network. Highways never end; streets tie into them.
//
// All randomness derives from MTSeededRandom seeded from the world seed,
// so identical seeds produce identical roads.

import Foundation
import simd

/// Road classification. Determines width, lanes, and shader markings.
public enum MTRoadKind: Int {
    case highway = 0   // 4 lanes, divided
    case ramp = 1      // 1-2 lane connector
    case street = 2    // 2 lanes
}

/// A drivable road polyline in world XZ.
public struct MTRoadPath {
    public var points: [SIMD2<Float>]  // world XZ, ordered along the road
    public var kind: MTRoadKind
    public var width: Float            // total paved width, meters
    public var lanes: Int

    public init(points: [SIMD2<Float>], kind: MTRoadKind, width: Float, lanes: Int) {
        self.points = points
        self.kind = kind
        self.width = width
        self.lanes = lanes
    }
}

/// Parametric infinite highway definition.
struct MTHighwayDef {
    var dir: SIMD2<Float>      // unit direction of travel
    var normal: SIMD2<Float>   // left perpendicular
    var a1, f1, p1: Float      // lateral offset sine 1: a1 * sin(t * f1 + p1)
    var a2, f2, p2: Float      // lateral offset sine 2
    var baseOffset: Float      // constant lateral shift

    /// Lateral offset at arc distance t (meters along dir).
    func lateral(t: Float) -> Float {
        baseOffset + a1 * sin(t * f1 + p1) + a2 * sin(t * f2 + p2)
    }

    /// World XZ at arc distance t.
    func position(t: Float) -> SIMD2<Float> {
        dir * t + normal * lateral(t: t)
    }

    /// Max |lateral| for bound computations.
    var maxAmplitude: Float { abs(baseOffset) + abs(a1) + abs(a2) }
}

/// A town: street grid anchored near a highway.
struct MTTownDef {
    var center: SIMD2<Float>
    var angle: Float        // grid rotation
    var blocksX: Int        // blocks across
    var blocksZ: Int        // blocks deep
    var spacing: Float      // meters between street centerlines
    var connectorT: Float   // highway arc position of the connector
    var highwayIndex: Int
}

/// Deterministic infinite road network for a world seed.
public class MTRoadNetwork {
    private let seed: UInt64
    private let highways: [MTHighwayDef]

    // Tuning
    private let highwaySampleStep: Float = 25      // meters between samples
    private let townSpacing: Float = 4200          // meters between towns along a highway
    private let townSideOffset: Float = 700        // town center offset from highway

    public init(seed: UInt64) {
        self.seed = seed
        var rng = MTSeededRandom(seed: seed ^ 0x524F4144_4E455457) // "ROADNETW"
        var defs: [MTHighwayDef] = []
        // Three highways at spread angles so every pair crosses.
        let baseAngles: [Float] = [0.26, 1.83, 3.65] // ~15°, ~105°, ~209°
        for i in 0..<3 {
            let angle = baseAngles[i] + (rng.nextFloat() - 0.5) * 0.35
            let dir = SIMD2<Float>(cos(angle), sin(angle))
            let normal = SIMD2<Float>(-dir.y, dir.x)
            // Gentle curves: 600-1400m wavelength, 80-260m amplitude.
            let a1 = 80 + rng.nextFloat() * 180
            let f1 = 2 * Float.pi / (600 + rng.nextFloat() * 800)
            let p1 = rng.nextFloat() * 2 * Float.pi
            let a2 = 40 + rng.nextFloat() * 80
            let f2 = 2 * Float.pi / (1800 + rng.nextFloat() * 1600)
            let p2 = rng.nextFloat() * 2 * Float.pi
            let base = (rng.nextFloat() - 0.5) * 1200
            // Stagger base offsets so highways don't all pile at origin.
            let stagger = Float(i - 1) * 2500
            defs.append(MTHighwayDef(dir: dir, normal: normal,
                                     a1: a1, f1: f1, p1: p1,
                                     a2: a2, f2: f2, p2: p2,
                                     baseOffset: base + stagger * 0.2))
        }
        self.highways = defs
    }

    // MARK: - Public query

    /// Road paths intersecting an axis-aligned world region.
    /// Deterministic; safe to call per chunk from any thread.
    public func roads(minX: Float, minZ: Float, maxX: Float, maxZ: Float) -> [MTRoadPath] {
        var out: [MTRoadPath] = []
        let margin: Float = 400
        let b = (minX: minX - margin, minZ: minZ - margin,
                 maxX: maxX + margin, maxZ: maxZ + margin)

        // 1. Highway segments.
        for hw in highways {
            if let pts = sampleHighway(hw, in: b), pts.count >= 2 {
                out.append(MTRoadPath(points: pts, kind: .highway, width: 17, lanes: 4))
            }
        }

        // 2. Interchanges where highways cross near this region.
        for i in 0..<highways.count {
            for j in (i + 1)..<highways.count {
                for c in crossings(highways[i], highways[j], near: b) {
                    out.append(contentsOf: interchange(at: c, hwyA: highways[i], hwyB: highways[j]))
                }
            }
        }

        // 3. Towns and their streets + connectors.
        for town in towns(near: b) {
            out.append(contentsOf: townRoads(town, in: b))
        }
        return out
    }

    // MARK: - Highways

    /// Sample highway polyline clipped to bounds. Returns nil if it misses.
    private func sampleHighway(_ hw: MTHighwayDef,
                              in b: (minX: Float, minZ: Float, maxX: Float, maxZ: Float)) -> [SIMD2<Float>]? {
        // Project bounds corners onto highway direction for t range.
        let corners = [
            SIMD2<Float>(b.minX, b.minZ), SIMD2<Float>(b.maxX, b.minZ),
            SIMD2<Float>(b.minX, b.maxZ), SIMD2<Float>(b.maxX, b.maxZ)
        ]
        var tMin = Float.greatestFiniteMagnitude
        var tMax = -Float.greatestFiniteMagnitude
        for c in corners {
            let t = dot(c, hw.dir)
            tMin = min(tMin, t); tMax = max(tMax, t)
        }
        // Also require the lateral offset to plausibly reach the bounds:
        // check perpendicular distance of the curve's centerline band.
        tMin -= 100; tMax += 100
        var pts: [SIMD2<Float>] = []
        var t = tMin
        while t <= tMax {
            let p = hw.position(t: t)
            if p.x >= b.minX && p.x <= b.maxX && p.y >= b.minZ && p.y <= b.maxZ {
                pts.append(p)
            } else if !pts.isEmpty {
                // Keep one point of overhang for clean clipping, then break runs.
                // Simpler: collect all, split into runs below.
                pts.append(p)
            } else {
                // Haven't entered yet; still record for run detection.
                pts.append(p)
            }
            t += highwaySampleStep
        }
        // Split into contiguous in-bounds runs.
        var runs: [[SIMD2<Float>]] = []
        var cur: [SIMD2<Float>] = []
        for p in pts {
            let inside = p.x >= b.minX && p.x <= b.maxX && p.y >= b.minZ && p.y <= b.maxZ
            if inside {
                cur.append(p)
            } else {
                if !cur.isEmpty {
                    // Add the out-of-bounds point as overhang for geometry continuity.
                    cur.append(p)
                    runs.append(cur)
                    cur = []
                }
            }
        }
        if !cur.isEmpty { runs.append(cur) }
        // Return the longest run (a highway crosses a chunk at most once
        // given gentle curvature; multiple runs would mean a U-turn).
        return runs.max(by: { $0.count < $1.count })
    }

    /// Find curve crossings between two highways near bounds.
    private func crossings(_ a: MTHighwayDef, _ b: MTHighwayDef,
                          near bounds: (minX: Float, minZ: Float, maxX: Float, maxZ: Float)) -> [SIMD2<Float>] {
        // Analytic line intersection as the seed guess.
        // Solve a.dir * ta + a.normal * a.baseOffset = b.dir * tb + b.normal * b.baseOffset
        // (ignoring sine terms for the guess).
        let d = a.dir.x * (-b.dir.y) - a.dir.y * (-b.dir.x)
        guard abs(d) > 1e-6 else { return [] }
        let rhsX = b.normal.x * b.baseOffset - a.normal.x * a.baseOffset
        let rhsY = b.normal.y * b.baseOffset - a.normal.y * a.baseOffset
        let ta = (rhsX * (-b.dir.y) - rhsY * (-b.dir.x)) / d
        // Search ta ± 4000m for actual curve crossings (coarse then refine).
        var found: [SIMD2<Float>] = []
        var t = ta - 4000
        var prevDist = Float.greatestFiniteMagnitude
        var prevT = t
        while t <= ta + 4000 {
            let pa = a.position(t: t)
            // For highway b, find tb minimizing |b.position(tb) - pa| via a few Newton-ish steps.
            var tb = dot(pa, b.dir)
            for _ in 0..<6 {
                let pb = b.position(t: tb)
                let err = pa - pb
                // Derivative of b.position wrt tb ≈ b.dir (lateral derivative is small).
                tb += dot(err, b.dir)
            }
            let dist = length(a.position(t: t) - b.position(t: tb))
            if dist < 60 && prevDist >= 60 {
                // Crossing between prevT and t: bisect.
                var lo = prevT, hi = t
                for _ in 0..<20 {
                    let mid = (lo + hi) / 2
                    var tbm = dot(a.position(t: mid), b.dir)
                    for _ in 0..<6 {
                        let pb = b.position(t: tbm)
                        tbm += dot(a.position(t: mid) - pb, b.dir)
                    }
                    let dm = length(a.position(t: mid) - b.position(t: tbm))
                    // Determine side by comparing lateral separation sign.
                    let sepMid = dot(a.position(t: mid) - b.position(t: tbm), a.normal)
                    var tbh = dot(a.position(t: hi), b.dir)
                    for _ in 0..<6 {
                        let pb = b.position(t: tbh)
                        tbh += dot(a.position(t: hi) - pb, b.dir)
                    }
                    let sepHi = dot(a.position(t: hi) - b.position(t: tbh), a.normal)
                    if sepMid * sepHi < 0 { lo = mid } else { hi = mid }
                    _ = dm
                }
                let tc = (lo + hi) / 2
                var tbc = dot(a.position(t: tc), b.dir)
                for _ in 0..<6 {
                    let pb = b.position(t: tbc)
                    tbc += dot(a.position(t: tc) - pb, b.dir)
                }
                let cross = (a.position(t: tc) + b.position(t: tbc)) / 2
                if cross.x >= bounds.minX && cross.x <= bounds.maxX &&
                    cross.y >= bounds.minZ && cross.y <= bounds.maxZ {
                    // Dedup against already-found crossings.
                    if !found.contains(where: { length($0 - cross) < 500 }) {
                        found.append(cross)
                    }
                }
            }
            prevDist = dist; prevT = t
            t += 40
        }
        return found
    }

    /// Diamond interchange: 4 curved ramps linking two crossing highways.
    private func interchange(at c: SIMD2<Float>, hwyA: MTHighwayDef, hwyB: MTHighwayDef) -> [MTRoadPath] {
        var ramps: [MTRoadPath] = []
        // Ramp endpoints: 220m out from the crossing along each highway.
        let tA = dot(c, hwyA.dir)
        let tB = dot(c, hwyB.dir)
        let a1 = hwyA.position(t: tA - 220), a2 = hwyA.position(t: tA + 220)
        let b1 = hwyB.position(t: tB - 220), b2 = hwyB.position(t: tB + 220)
        // 4 connectors: a1->b1, a1->b2, a2->b1, a2->b2 (each a smooth curve).
        for (p, q) in [(a1, b1), (a1, b2), (a2, b1), (a2, b2)] {
            let mid = (p + q) / 2
            // Push control point outward from the crossing for a sweeping curve.
            let away = mid - c
            let ctrl = mid + (length(away) > 1 ? away / length(away) : SIMD2<Float>(1, 0)) * 60
            var pts: [SIMD2<Float>] = []
            for i in 0...12 {
                let t = Float(i) / 12
                let mt = 1 - t
                pts.append(mt * mt * p + 2 * mt * t * ctrl + t * t * q)
            }
            ramps.append(MTRoadPath(points: pts, kind: .ramp, width: 8, lanes: 1))
        }
        return ramps
    }

    // MARK: - Towns

    /// Towns whose street grids could reach bounds. Deterministic per highway.
    private func towns(near b: (minX: Float, minZ: Float, maxX: Float, maxZ: Float)) -> [MTTownDef] {
        var out: [MTTownDef] = []
        for (hi, hw) in highways.enumerated() {
            // Town k center near t = k * townSpacing + jitter.
            // Find k range overlapping bounds via projection.
            let corners = [
                SIMD2<Float>(b.minX, b.minZ), SIMD2<Float>(b.maxX, b.minZ),
                SIMD2<Float>(b.minX, b.maxZ), SIMD2<Float>(b.maxX, b.maxZ)
            ]
            var tMin = Float.greatestFiniteMagnitude
            var tMax = -Float.greatestFiniteMagnitude
            for c in corners {
                let t = dot(c, hw.dir)
                tMin = min(tMin, t); tMax = max(tMax, t)
            }
            // Towns have ~1.5km radius of streets; expand range.
            let kMin = Int(floor((tMin - 2000) / townSpacing))
            let kMax = Int(ceil((tMax + 2000) / townSpacing))
            for k in kMin...kMax {
                var rng = MTSeededRandom(seed: seed ^ UInt64(bitPattern: Int64(hi * 100003 + k * 9176 + 41)))
                let t = Float(k) * townSpacing + (rng.nextFloat() - 0.5) * 1200
                let side: Float = (k & 1) == 0 ? 1 : -1
                let offDist = townSideOffset + rng.nextFloat() * 500
                let center = hw.position(t: t) + hw.normal * side * offDist
                // Quick reject: town too far from bounds.
                if center.x < b.minX - 1800 || center.x > b.maxX + 1800 ||
                    center.y < b.minZ - 1800 || center.y > b.maxZ + 1800 { continue }
                let angle = atan2(hw.dir.y, hw.dir.x) + (rng.nextFloat() - 0.5) * 0.4
                out.append(MTTownDef(
                    center: center, angle: angle,
                    blocksX: 3 + rng.nextInt(upperBound: 3),
                    blocksZ: 3 + rng.nextInt(upperBound: 3),
                    spacing: 140 + rng.nextFloat() * 60,
                    connectorT: t, highwayIndex: hi))
            }
        }
        return out
    }

    /// Street grid + highway connector for a town, clipped to bounds.
    private func townRoads(_ town: MTTownDef,
                           in b: (minX: Float, minZ: Float, maxX: Float, maxZ: Float)) -> [MTRoadPath] {
        var out: [MTRoadPath] = []
        let ca = cos(town.angle), sa = sin(town.angle)
        func localToWorld(_ lx: Float, _ lz: Float) -> SIMD2<Float> {
            town.center + SIMD2<Float>(lx * ca - lz * sa, lx * sa + lz * ca)
        }
        let hw = highways[town.highwayIndex]
        // Grid streets.
        let wX = Float(town.blocksX) * town.spacing
        let wZ = Float(town.blocksZ) * town.spacing
        // North-south streets (vary x).
        for ix in 0...town.blocksX {
            let lx = -wX / 2 + Float(ix) * town.spacing
            let p0 = localToWorld(lx, -wZ / 2 - 60)
            let p1 = localToWorld(lx, wZ / 2 + 60)
            if let clipped = clipSegment(p0, p1, b) {
                out.append(MTRoadPath(points: clipped, kind: .street, width: 9, lanes: 2))
            }
        }
        // East-west streets (vary z).
        for iz in 0...town.blocksZ {
            let lz = -wZ / 2 + Float(iz) * town.spacing
            let p0 = localToWorld(-wX / 2 - 60, lz)
            let p1 = localToWorld(wX / 2 + 60, lz)
            if let clipped = clipSegment(p0, p1, b) {
                out.append(MTRoadPath(points: clipped, kind: .street, width: 9, lanes: 2))
            }
        }
        // Connector: town center -> highway at connectorT (2-lane road).
        let hp = hw.position(t: town.connectorT)
        if let clipped = clipSegment(town.center, hp, b), clipped.count >= 2 {
            // Slight curve via midpoint offset.
            let mid = (town.center + hp) / 2
            let dir = hp - town.center
            let len = max(length(dir), 1)
            let perp = SIMD2<Float>(-dir.y / len, dir.x / len)
            let midOff = mid + perp * min(120, len * 0.15)
            var pts: [SIMD2<Float>] = []
            for i in 0...10 {
                let t = Float(i) / 10
                let mt = 1 - t
                pts.append(mt * mt * town.center + 2 * mt * t * midOff + t * t * hp)
            }
            // Re-clip the curved version coarsely: keep points in expanded bounds.
            let kept = pts.filter { $0.x >= b.minX && $0.x <= b.maxX && $0.y >= b.minZ && $0.y <= b.maxZ }
            if kept.count >= 2 {
                out.append(MTRoadPath(points: kept, kind: .ramp, width: 9, lanes: 2))
            }
        }
        return out
    }

    /// Clip a segment to bounds; returns the clipped polyline (2 pts) or nil.
    private func clipSegment(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>,
                             _ b: (minX: Float, minZ: Float, maxX: Float, maxZ: Float)) -> [SIMD2<Float>]? {
        // Liang-Barsky.
        var t0: Float = 0, t1: Float = 1
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let edges: [(Float, Float)] = [(-dx, p0.x - b.minX), (dx, b.maxX - p0.x),
                                       (-dy, p0.y - b.minZ), (dy, b.maxZ - p0.y)]
        for (p, q) in edges {
            if abs(p) < 1e-9 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                if t0 > t1 { return nil }
            }
        }
        return [p0 + (p1 - p0) * t0, p0 + (p1 - p0) * t1]
    }
}
