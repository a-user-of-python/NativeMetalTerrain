// MTHeightmapCompute.metal
// MetalTerrain — GPU heightmap generation.
//
// Bit-faithful MSL port of the MTNoise.swift height pipeline
// (mtHeightSampleField + MTPerlinNoise + mtFBMSumOctaves/mtRidgedSumOctaves).
// The permutation tables are built on CPU (MTSeededRandom Fisher-Yates)
// and uploaded as buffers, so the lattice hashing is identical to Swift.
//
// Precision notes:
//  - Lattice coordinates use float floor + 64-bit masking, matching
//    Swift's `Int(floor(x)) & 255` including negative coordinates.
//  - All octave math is float, matching Swift's Double.
//  - mountainPow replicates the Float LUT path exactly (same 256-entry
//    table uploaded from CPU) when sharpness == 0.72f.
//  - Final quantization replicates `UInt16((Float(h) * 65535).rounded())`.

#include <metal_stdlib>
using namespace metal;

// Must match HeightmapParams in MTHeightmapCompute.swift exactly:
// 13 floats followed by 9 uints.
struct HeightmapParams {
    float x0;
    float z0;
    float step;
    float baseFreq;
    float lacunarity;
    float gain;
    float baseAmplitude;
    float warpStrength;
    float warpScale;
    float continentFreq;
    float mtnFreq;
    float riverFreq;
    float mountainSharpness;
    uint   res;
    uint   baseOctaves;
    uint   continentOctaves;
    uint   warpOctaves;
    uint   rangeOctaves;
    uint   riverOctaves;
    uint   baseRidged;   // 1 = ridged detail, 0 = fbm detail
    uint   doWarp;       // 1 = domain warp enabled
    uint   ventCount;    // v1.3.0: number of volcano vents in vents buffer
};

// v1.3.0: volcano vent for crater carving. Must match the Swift
// MTVolcanoVentGPU layout (float2 + float + float + float = 20 bytes).
struct MTVolcanoVentGPU {
    float2 pos;      // world XZ of crater center
    float  radius;   // crater radius, world units
    float  depth;    // normalized depth subtracted at center
    float  peakHeight; // v1.3.0-refine: normalized peak height (cone shaping)
};

// MARK: - Perlin gradient noise (port of MTPerlinNoise.noise)

inline float mtnFade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

inline float mtnLerp(float a, float b, float t) {
    return a + t * (b - a);
}

// One of 8 gradient directions selected by the low 3 bits of the hash.
// Port of MTPerlinNoise.grad.
inline float mtnGrad(uint hash, float x, float y) {
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
inline float perlinNoise(float x, float y, constant uint *perm) {
    if (!isfinite(x) || !isfinite(y)) { return 0.0; }
    float fx = floor(x);
    float fy = floor(y);
    // 64-bit mask matches Swift `Int(fx) & 255` (two's complement).
    long xi = ((long)fx) & 255L;
    long yi = ((long)fy) & 255L;
    float xf = x - fx;
    float yf = y - fy;
    float u = mtnFade(xf);
    float v = mtnFade(yf);
    uint X = (uint)xi;
    uint Y = (uint)yi;
    uint aa = perm[perm[X] + Y];
    uint ab = perm[perm[X] + Y + 1u];
    uint ba = perm[perm[X + 1u] + Y];
    uint bb = perm[perm[X + 1u] + Y + 1u];
    float x1 = mtnLerp(mtnGrad(aa, xf, yf),     mtnGrad(ba, xf - 1.0, yf),     u);
    float x2 = mtnLerp(mtnGrad(ab, xf, yf - 1.0), mtnGrad(bb, xf - 1.0, yf - 1.0), u);
    return mtnLerp(x1, x2, v);
}

// MARK: - Octave sums (ports of mtFBMSumOctaves / mtRidgedSumOctaves)

inline float mtnFbmSum(float amplitude, float lacunarity, float gain,
                        uint octaves, float nx, float ny,
                        constant uint *perm) {
    float sum = 0.0;
    float amp = amplitude;
    float freq = 1.0;
    float norm = 0.0;
    for (uint i = 0; i < octaves; i++) {
        sum += amp * perlinNoise(nx * freq, ny * freq, perm);
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0 ? sum / norm : 0.0;
}

inline float mtnRidgedSum(float amplitude, float lacunarity, float gain,
                           uint octaves, float nx, float ny,
                           constant uint *perm) {
    float sum = 0.0;
    float amp = amplitude;
    float freq = 1.0;
    float norm = 0.0;
    for (uint i = 0; i < octaves; i++) {
        float n = perlinNoise(nx * freq, ny * freq, perm);
        float r = 1.0 - fabs(n);
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
inline float mtnMountainPow(float x, float sharpness, constant float *lut) {
    if (!isfinite(x)) { return 0.0; }
    float clamped = clamp(x, 0.0f, 1.0f);
    if (sharpness == 0.72f) {
        uint idx = (uint)(clamped * 255.0f);
        return (float)lut[idx];
    }
    float r = pow((float)clamped, (float)sharpness);
    float rf = (float)r;
    return isfinite(rf) ? (float)rf : 0.0;
}

// MARK: - Full height pipeline (port of mtHeightSampleField)

inline float heightSample(float x, float y,
                           constant HeightmapParams &p,
                           constant uint *perm,
                           constant uint *warpPerm,
                           constant float *lut) {
    // Continent layer (2-octave fbm mask).
    float continent = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                p.continentOctaves,
                                x * p.continentFreq, y * p.continentFreq, perm);

    // Base detail coords, optionally domain-warped.
    float nx = x * p.baseFreq;
    float ny = y * p.baseFreq;
    if (p.doWarp != 0u) {
        float wx = mtnFbmSum(1.0, p.lacunarity, p.gain, p.warpOctaves,
                              nx * p.warpScale + 5.2, ny * p.warpScale + 1.3, warpPerm);
        float wy = mtnFbmSum(1.0, p.lacunarity, p.gain, p.warpOctaves,
                              nx * p.warpScale - 1.7, ny * p.warpScale + 9.2, warpPerm);
        nx += p.warpStrength * wx;
        ny += p.warpStrength * wy;
    }

    float detail;
    if (p.baseRidged != 0u) {
        detail = mtnRidgedSum(p.baseAmplitude, p.lacunarity, p.gain,
                             p.baseOctaves, nx, ny, perm);
    } else {
        detail = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                           p.baseOctaves, nx, ny, perm);
    }

    // Mountain ranges: ridged noise masked to range bands.
    float rangeMask = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                p.continentOctaves,
                                (x + 1000.0) * p.continentFreq,
                                (y - 1000.0) * p.continentFreq, warpPerm);
    float mountainMask = clamp((rangeMask - 0.08) * 2.2, 0.0, 1.0);
    float ridged = mtnRidgedSum(p.baseAmplitude, p.lacunarity, p.gain,
                                p.rangeOctaves,
                                x * p.mtnFreq, y * p.mtnFreq, perm);
    float rxf = (float)max(ridged, 0.0);
    float rounded = mtnMountainPow(rxf, (float)p.mountainSharpness, lut);
    float mountains = rounded * mountainMask * mountainMask;

    // Rivers: warped low-frequency meander carve.
    float riverWarpX = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                 p.continentOctaves,
                                 (x + 5000.0) * p.continentFreq,
                                 (y + 5000.0) * p.continentFreq, warpPerm);
    float riverWarpY = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                                 p.continentOctaves,
                                 (x - 5000.0) * p.continentFreq,
                                 (y - 5000.0) * p.continentFreq, perm);
    float riverN = mtnFbmSum(p.baseAmplitude, p.lacunarity, p.gain,
                              p.riverOctaves,
                              ((x + riverWarpX * 800.0) + 5000.0) * p.riverFreq,
                              ((y + riverWarpY * 800.0) + 5000.0) * p.riverFreq, perm);
    float riverDist = fabs(riverN);
    float riverCarve = max(0.0, 1.0 - riverDist * 6.0);
    float riverCarveSmooth = riverCarve * riverCarve * (3.0 - 2.0 * riverCarve);
    float landMask = clamp((continent + 0.45) * 2.5, 0.0, 1.0);
    float riverCarveMasked = riverCarveSmooth * landMask;

    // Combine.
    float plainsFlatten = 1.0 - mountainMask * 0.7;
    float h = 0.5 + continent * 0.55 + detail * 0.28 * plainsFlatten;
    h += mountains * 0.55;
    float coastalT = clamp((h - 0.40) / 0.15, 0.0, 1.0);
    float coastalFlat = coastalT * coastalT * (3.0 - 2.0 * coastalT);
    h = 0.46 + (h - 0.46) * (0.25 + 0.75 * coastalFlat);
    float riverValleyMask = 1.0 - mountainMask * 0.85;
    float elevationFactor = clamp((h - 0.45) * 3.0, 0.3, 1.0);
    float targetDepth = max(0.0, h - 0.42);
    float carveAmount = min(0.35 * elevationFactor, targetDepth);
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
    constant MTVolcanoVentGPU *vents   [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.res || gid.y >= p.res) { return; }
    float x = p.x0 + (float)gid.x * p.step;
    float y = p.z0 + (float)gid.y * p.step;
    float h = heightSample(x, y, p, perm, warpPerm, lut);
    // v1.3.0: carve volcano craters. Wobbled edge for a natural look.
    // v1.3.0-refine: volcanic cone shaping first (regularizes slopes
    // toward an idealized cone within 4x crater radius), then carve.
    for (uint v = 0; v < p.ventCount; v++) {
        float2 d = float2(x, y) - vents[v].pos;
        float dist = length(d);
        float r = vents[v].radius;
        float coneR = r * 4.0;
        if (dist < coneR) {
            float t = dist / coneR;
            float coneH = vents[v].peakHeight * pow(1.0 - t, 1.25);
            float w = 0.45 * (1.0 - t) * (1.0 - t);
            h = h * (1.0 - w) + coneH * w;
        }
        if (dist < r * 1.35) {
            float ang = atan2(d.y, d.x);
            float wobble = 1.0 + 0.22 * sin(ang * 3.0 + vents[v].pos.x)
                                       * sin(ang * 5.0 + vents[v].pos.y);
            float t = clamp(dist / (r * wobble), 0.0, 1.0);
            float delta;
            if (t < 1.0) {
                delta = -(1.0 - t * t) * vents[v].depth;
            } else {
                delta = 0.15 * vents[v].depth * (1.0 - (t - 1.0) / 0.35);
            }
            h = clamp(h + delta, 0.0, 1.0);
        }
    }
    float hf = (float)h;
    out[(uint)gid.y * p.res + (uint)gid.x] = (ushort)round(hf * 65535.0f);
}
