// MTPerlinNoise.swift
// MetalTerrain — 2D gradient (Perlin-style) noise with a seeded permutation table.
//
// Original implementation of the classic gradient-noise algorithm:
// a permutation table of 0...255 is shuffled with MTSeededRandom and
// doubled to 512 entries, then lattice gradients are faded and
// trilinearly interpolated. Output is bounded within [-1, 1].

import Foundation

/// Seeded 2D gradient noise.
///
/// The permutation table is built once from the seed, so the noise field
/// is a pure function of `(seed, x, y)`.
public struct MTPerlinNoise {
    /// 512-entry permutation table (0...255 shuffled, then doubled).
    private let perm: [Int]

    /// Build the permutation table from `seed`.
    public init(seed: UInt64) {
        var rng = MTSeededRandom(seed: seed)
        var p = Array(0..<256)
        // Fisher–Yates shuffle with the seeded PRNG.
        for i in stride(from: 255, through: 1, by: -1) {
            let j = rng.nextInt(upperBound: i + 1)
            p.swapAt(i, j)
        }
        self.perm = p + p
    }

    /// Gradient noise at `(x, y)`, bounded within [-1, 1].
    ///
    /// Non-finite inputs (NaN / ±infinity) safely return 0 instead of
    /// trapping or producing NaN output.
    public func noise(x: Double, y: Double) -> Double {
        guard x.isFinite && y.isFinite else { return 0 }

        // Lattice coordinates, wrapped to [0, 256) without overflow traps.
        let xi = Int((floor(x).truncatingRemainder(dividingBy: 256) + 256)
            .truncatingRemainder(dividingBy: 256))
        let yi = Int((floor(y).truncatingRemainder(dividingBy: 256) + 256)
            .truncatingRemainder(dividingBy: 256))
        let xf = x - floor(x)
        let yf = y - floor(y)

        let u = MTPerlinNoise.fade(xf)
        let v = MTPerlinNoise.fade(yf)

        // Hash the four lattice corners.
        let aa = perm[perm[xi] + yi]
        let ab = perm[perm[xi] + yi + 1]
        let ba = perm[perm[xi + 1] + yi]
        let bb = perm[perm[xi + 1] + yi + 1]

        let x1 = MTPerlinNoise.lerp(
            MTPerlinNoise.grad(aa, xf, yf),
            MTPerlinNoise.grad(ba, xf - 1, yf), u)
        let x2 = MTPerlinNoise.lerp(
            MTPerlinNoise.grad(ab, xf, yf - 1),
            MTPerlinNoise.grad(bb, xf - 1, yf - 1), u)
        return MTPerlinNoise.lerp(x1, x2, v)
    }

    // MARK: - Helpers

    @inline(__always)
    private static func fade(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    @inline(__always)
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + t * (b - a)
    }

    /// One of 8 gradient directions selected by the low 3 bits of the hash.
    @inline(__always)
    private static func grad(_ hash: Int, _ x: Double, _ y: Double) -> Double {
        switch hash & 7 {
        case 0: return x + y
        case 1: return -x + y
        case 2: return x - y
        case 3: return -x - y
        case 4: return x
        case 5: return -x
        case 6: return y
        default: return -y
        }
    }
}
