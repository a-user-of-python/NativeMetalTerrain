// MTSeededRandom.swift
// MetalTerrain — deterministic xorshift64* pseudo-random number generator.
//
// Original implementation. All terrain, biome jitter, and structure
// placement derive from this PRNG, so identical seeds always produce
// identical worlds. No system randomness is used anywhere.

import Foundation

/// Deterministic 64-bit PRNG (xorshift64*).
///
/// Create with a seed, then draw values with the `next*` family.
/// The sequence is fully determined by the seed.
public struct MTSeededRandom {
    private var state: UInt64

    /// Create a PRNG from a seed. A zero seed is mapped to a fixed
    /// non-zero constant so the generator never gets stuck at zero.
    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// Next raw 64-bit value (xorshift64*).
    @inline(__always)
    public mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 0x2545F4914F6CDD1D
    }

    /// Next Double in [0, 1), using the top 53 bits for full
    /// double-precision resolution.
    @inline(__always)
    public mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0) // 2^53
    }

    /// Next Float in [0, 1).
    @inline(__always)
    public mutating func nextFloat() -> Float {
        Float(nextDouble())
    }

    /// Next Int in [0, upperBound). `upperBound` must be positive.
    @inline(__always)
    public mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0, "MTSeededRandom.nextInt requires upperBound > 0")
        return Int(next() % UInt64(upperBound))
    }
}
