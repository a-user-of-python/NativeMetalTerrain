// MTHeightmapCompute.metal
// MetalTerrain — GPU heightmap generation.
//
// Bit-faithful MSL port of the MTNoise.swift height pipeline
// (mtHeightSampleField + MTPerlinNoise + mtFBMSumOctaves/mtRidgedSumOctaves).
// The permutation tables are built on CPU (MTSeededRandom Fisher-Yates)
// and uploaded as buffers, so the lattice hashing is identical to Swift.
//
// Precision notes:
//  - Lattice coordinates use double floor + 64-bit masking, matching
//    Swift's `Int(floor(x)) & 255` including negative coordinates.
//  - All octave math is double, matching Swift's Double.
//  - mountainPow replicates the Float LUT path exactly (same 256-entry
//    table uploaded from CPU) when sharpness == 0.72f.
//  - Final quantization replicates `UInt16((Float(h) * 65535).rounded())`.

#include <metal_stdlib>
using namespace metal;

// Must match HeightmapParams in MTHeightmapCompute.swift exactly:
// 13 doubles (8-byte aligned) followed by 8 uints (4-byte aligned).
struct HeightmapParams {
    double x0;
    double z0;
    double step;
    double baseFreq;
    double lacunarity;
    double gain;
    double baseAmplitude;
    double warpStrength;
    double warpScale;
    double continentFreq;
    double mtnFreq;
    double riverFreq;
    double mountainSharpness;
    uint   res;
    uint   baseOctaves;
    uint   continentOctaves;
    uint   warpOctaves;
    uint   rangeOctaves;
    uint   riverOctaves;
    uint   baseRidged;   // 1 = ridged detail, 0 = fbm detail
    uint   doWarp;       // 1 = domain warp enabled
};

// MARK: - Perlin gradient noise (port of MTPerlinNoise.noise)

inline double mtnFade(double t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

inline double mtnLerp(double a, double b, double t) {
    return a + t * (b - a);
}

// One of 8 gradient directions selected by the low 3 bits of the hash.
// Port of MTPerlinNoise.grad.
inline double mtnGrad(uint hash, double x, double y) {
    switch (hash & 7u) {
        case 0:  return  x + y;
        case 1:  return -x + y;
        case 2:  return  x - y;
        case 3:  return -x - y;
        case 4:  return  x;
        case 5:  return -x;
        case 6:  return  y;
        default: return -y;
    }
}

// Port of MTPerlinNoise.noise(x:y:). `perm` is the 512-entry table.
inline double perlinNoise(double x, double y, constant uint *perm) {
    if (!isfinite(x) || !isfinite(y)) { return 0.0; }
    double fx = floor(x);
    double fy = floor(y);
    // 64-bit mask matches Swift `Int(fx) & 255` (two's complement).
    long xi = ((long)fx) & 255L;
    long yi = ((long)fy) & 255L;
    double xf = x - fx;
    double yf = y - fy;
    double u = mtnFade(xf);
    double v = mtnFade(yf);
    uint X = (uint)xi;
    uint Y = (uint)yi;
    uint aa = perm[perm[X] + Y];
    uint ab = perm[perm[X] + Y + 1u];
    uint ba = perm[perm[X + 1u] + Y];
    uint bb = perm[perm[X + 1u] + Y + 1u];
    double x1 = mtnLerp(mtnGrad(aa, xf, yf),     mtnGrad(ba, xf - 1.0, yf),     u);
    double x2 = mtnLerp(mtnGrad(ab, xf, yf - 1.0), mtnGrad(bb, xf - 1.0, yf - 1.0), u);
    return mtnLerp(x1, x2, v);
}

// MARK: - Octave sums (ports of mtFBMSumOctaves / mtRidgedSumOctaves)

inline double mtnFbmSum(double amplitude, double lacunarity, double gain,
                        uint octaves, double nx, double ny,
                        constant uint *perm) {
    double sum = 0.0;
    double amp = amplitude;
    double freq = 1.0;
    double norm = 0.0;
    for (uint i = 0; i < octaves; i++) {
        sum += amp * perlinNoise(nx * freq, ny * freq, perm);
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0 ? sum / norm : 0.0;
}

inline double mtnRidgedSum(double amplitude, double lacunarity, double gain,
                           uint octaves, double nx, double ny,
                           constant uint *perm) {
    double sum = 0.0;
    double amp = amplitude;
    double freq = 1.0;
    double norm = 0.0;
    for (uint i = 0; i < octaves; i++) {
        double n = perlinNoise(nx * freq, ny * freq, perm);
        double r = 1.0 - fabs(n);
        sum += amp * r * r;
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0 ? sum / norm : 0.0;
}

// MARK: - Mountain peak rounding (port of mountainPow)

// `lut` is the CPU-built 256-entry pow(x, 0.72) table (floats).
// The sharpness==0.72f float comparison replicates Swift's
// `if sharpness == 0.72` on Float.
inline double mtnMountainPow(float x, float sharpness, constant float *lut) {
    if (!isfinite(x)) { return 0.0; }
    float clamped = clamp(x, 0.0f, 1.0f);
    if (sharpness == 0.72f) {
        uint idx = (uint)(clamped * 255.0f);
        return (double)lut[idx];
    }
    double r = pow((double)clamped, (double)sharpness);
    float rf = (float)r;
    return isfinite(rf) ? (double)rf : 0.0;
}

// MARK: - Full height pipeline (port of mtHeightSampleField)

inline double heightSample(double x, double y,
                           constant HeightmapParams &p,
                           constant uint *perm,
                           constant uint *warpPerm,
                           constant float *lut) {
    // Continent layer (2-octave fbm mask).
    double continent = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                p.continentOctaves,
                                x * p.continentFreq, y * p.continentFreq, perm);

    // Base detail coords, optionally domain-warped.
    double nx = x * p.baseFreq;
    double ny = y * p.baseFreq;
    if (p.doWarp != 0u) {
        double wx = mtnFbmSum(1.0, p.lacunarity, p.gain, p.warpOctaves,
                              nx * p.warpScale + 5.2, ny * p.warpScale + 1.3, warpPerm);
        double wy = mtnFbmSum(1.0, p.lacunarity, p.gain, p.warpOctaves,
                              nx * p.warpScale - 1.7, ny * p.warpScale + 9.2, warpPerm);
        nx += p.warpStrength * wx;
        ny += p.warpStrength * wy;
    }

    double detail;
    if (p.baseRidged != 0u) {
        detail = mtnRidgedSum(p.baseAmplitude, p.lacunarity, p.gain,
                             p.baseOctaves, nx, ny, perm);
    } else {
        detail = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                           p.baseOctaves, nx, ny, perm);
    }

    // Mountain ranges: ridged noise masked to range bands.
    double rangeMask = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                p.continentOctaves,
                                (x + 1000.0) * p.continentFreq,
                                (y - 1000.0) * p.continentFreq, warpPerm);
    double mountainMask = clamp((rangeMask - 0.08) * 2.2, 0.0, 1.0);
    double ridged = mtnRidgedSum(p.baseAmplitude, p.lacunarity, p.gain,
                                p.rangeOctaves,
                                x * p.mtnFreq, y * p.mtnFreq, perm);
    float rxf = (float)max(ridged, 0.0);
    double rounded = mtnMountainPow(rxf, (float)p.mountainSharpness, lut);
    double mountains = rounded * mountainMask * mountainMask;

    // Rivers: warped low-frequency meander carve.
    double riverWarpX = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                 p.continentOctaves,
                                 (x + 5000.0) * p.continentFreq,
                                 (y + 5000.0) * p.continentFreq, warpPerm);
    double riverWarpY = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                 p.continentOctaves,
                                 (x - 5000.0) * p.continentFreq,
                                 (y - 5000.0) * p.continentFreq, perm);
    double riverN = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                              p.riverOctaves,
                              ((x + riverWarpX * 800.0) + 5000.0) * p.riverFreq,
                              ((y + riverWarpY * 800.0) + 5000.0) * p.riverFreq, perm);
    double riverDist = fabs(riverN);
    double riverCarve = max(0.0, 1.0 - riverDist * 6.0);
    double riverCarveSmooth = riverCarve * riverCarve * (3.0 - 2.0 * riverCarve);
    double landMask = clamp((continent + 0.45) * 2.5, 0.0, 1.0);
    double riverCarveMasked = riverCarveSmooth * landMask;

    // Combine.
    double plainsFlatten = 1.0 - mountainMask * 0.7;
    double h = 0.5 + continent * 0.55 + detail * 0.28 * plainsFlatten;
    h += mountains * 0.55;
    double coastalT = clamp((h - 0.40) / 0.15, 0.0, 1.0);
    double coastalFlat = coastalT * coastalT * (3.0 - 2.0 * coastalT);
    h = 0.46 + (h - 0.46) * (0.25 + 0.75 * coastalFlat);
    double riverValleyMask = 1.0 - mountainMask * 0.85;
    double elevationFactor = clamp((h - 0.45) * 3.0, 0.3, 1.0);
    double targetDepth = max(0.0, h - 0.42);
    double carveAmount = min(0.35 * elevationFactor, targetDepth);
    h -= riverCarveMasked * riverValleyMask * carveAmount;

    return clamp(h, 0.0, 1.0);
}

// MARK: - Kernel

// One thread per heightmap texel. Writes UInt16 quantized heights,
// replicating `UInt16((Float(h) * 65535).rounded())`.
kernel void mtHeightmapKernel(
    constant HeightmapParams &p [[buffer(0)]],
    constant uint            *perm     [[buffer(1)]],
    constant uint            *warpPerm [[buffer(2)]],
    constant float           *lut      [[buffer(3)]],
    device ushort            *out      [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.res || gid.y >= p.res) { return; }
    double x = p.x0 + (double)gid.x * p.step;
    double y = p.z0 + (double)gid.y * p.step;
    double h = heightSample(x, y, p, perm, warpPerm, lut);
    float hf = (float)h;
    out[(uint)gid.y * p.res + (uint)gid.x] = (ushort)round(hf * 65535.0f);
}
