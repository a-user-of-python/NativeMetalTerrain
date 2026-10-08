// MTMeshCompute.metal
// MetalTerrain — GPU terrain mesh building.
//
// Bit-faithful MSL port of MTMeshBuilder.buildGrid (stride = 1) +
// appendSkirtVertices: per-vertex positions from a padded heightmap,
// central-difference normals, biome ground colors, and the packed
// 20-byte MTVertex layout (float3 position + octahedral normal uint +
// RGBA8888 uint) that MTShaders.metal's MTVertexIn expects.
//
// The heightmap input is (res+2)x(res+2) with a one-cell border, so
// every vertex — including chunk borders — samples true neighbor
// heights. This reproduces the CPU path's mtHeightSampleField border
// calls exactly (same kernel math, same coordinates).
//
// One thread per output vertex. Threads [0, n*n) write main vertices
// (row-major, b*n+a); threads [n*n, n*n+4n-4) write skirt vertices in
// the same edge order as appendSkirtVertices.

#include <metal_stdlib>
using namespace metal;

// Must match MeshParams in MTMeshCompute.swift exactly:
// 7 floats + 2 uints = 36 bytes.
struct MeshParams {
    float x0;          // chunk world origin X
    float z0;          // chunk world origin Z
    float step;        // world units per height sample
    float  heightScale;
    float  cell;        // == step as float
    float  skirtDepth;  // heightScale * 0.35 + 10
    float  _pad0;
    uint   res;         // vertices per side (n)
    uint   biomeCount;
};

// One biome slot. Must match GPUBiomeParams in MTMeshCompute.swift:
// 2 floats + 2 float4s + 2 floats + float2 = 64 bytes, 16-aligned.
struct GPUBiome {
    float  minHeight;
    float  maxHeight;
    float4 groundColor;  // rgb in xyz
    float4 slopeColor;   // rgb in xyz, w = 1 if present else 0
    float  materialID;
    float  emitsLight;   // 1 or 0
    float2 _pad;
};

// Packed 20-byte vertex: matches MTVertex (Swift) and MTVertexIn
// (MTShaders.metal). packed_float3 keeps 4-byte alignment so the
// struct is exactly 12 + 4 + 4 = 20 bytes.
struct MeshVertexOut {
    packed_float3 position;
    uint normalXY;
    uint rgba;
};

// MARK: - Packing (ports of MTVertex.encodeNormal / encodeColor)

inline uint meshEncodeNormal(float3 n) {
    float l1 = fabs(n.x) + fabs(n.y) + fabs(n.z);
    if (l1 <= 0.0f) { return 0u; }
    float inv = 1.0f / l1;
    float ex = n.x * inv;
    float ey = n.y * inv;
    if (n.z < 0.0f) {
        float ox = ex, oy = ey;
        ex = (1.0f - fabs(oy)) * (ox >= 0.0f ? 1.0f : -1.0f);
        ey = (1.0f - fabs(ox)) * (oy >= 0.0f ? 1.0f : -1.0f);
    }
    int sx = (int)rint(clamp(ex * 32767.0f, -32768.0f, 32767.0f));
    int sy = (int)rint(clamp(ey * 32767.0f, -32768.0f, 32767.0f));
    return ((uint)(sx & 0xFFFF)) | (((uint)(sy & 0xFFFF)) << 16u);
}

inline uint meshEncodeColor(float3 c, float material) {
    uint r = (uint)clamp(rint(c.x * 255.0f), 0.0f, 255.0f);
    uint g = (uint)clamp(rint(c.y * 255.0f), 0.0f, 255.0f);
    uint b = (uint)clamp(rint(c.z * 255.0f), 0.0f, 255.0f);
    uint m = (uint)clamp(rint(material), 0.0f, 255.0f);
    return r | (g << 8u) | (b << 16u) | (m << 24u);
}

// MARK: - Biome color (port of MTMeshBuilder.groundColor)

inline uint meshBiomeIndex(float h, constant GPUBiome *biomes, uint count) {
    for (uint i = 0; i < count; i++) {
        if (h >= biomes[i].minHeight && h <= biomes[i].maxHeight) {
            return i;
        }
    }
    return count - 1u;
}

inline float meshSmooth01(float t) {
    float c = clamp(t, 0.0f, 1.0f);
    return c * c * (3.0f - 2.0f * c);
}

// Port of MTMeshBuilder.groundColor. Outputs linear rgb + material ID.
inline void meshGroundColor(float h, float normalY,
                            constant GPUBiome *biomes, uint biomeCount,
                            thread float3 &rgb, thread float &material) {
    uint bi = meshBiomeIndex(h, biomes, biomeCount);
    GPUBiome biome = biomes[bi];
    material = (biome.materialID == 3.0f && h > 0.92f) ? 4.0f : biome.materialID;
    float slope = 1.0f - normalY;
    // High altitude: rock banding guard, snow cap at the top.
    if (h > 0.65f) {
        if (h > 0.80f) {
            float t = min(1.0f, (h - 0.80f) / 0.12f);
            float3 rock = float3(0.45f, 0.42f, 0.38f);
            float3 snow = float3(0.90f, 0.92f, 0.95f);
            rgb = rock + (snow - rock) * t;
            material = h > 0.92f ? 4.0f : 3.0f;
            return;
        }
        rgb = float3(0.45f, 0.42f, 0.38f);
        material = 1.0f;
        return;
    }
    // Steep slopes use the biome's cliff color.
    if (slope > 0.55f && biome.slopeColor.w > 0.5f) {
        rgb = biome.slopeColor.xyz;
        material = 1.0f;
        return;
    }
    float3 color = biome.groundColor.xyz;
    float e = 0.12f;  // biomeBlendRange
    if (h > biome.maxHeight - e) {
        uint ai = meshBiomeIndex(min(h + e, 1.0f), biomes, biomeCount);
        if (ai != bi) {
            float t = meshSmooth01((biome.maxHeight - h) / e);
            color = mix(biomes[ai].groundColor.xyz, color, t);
        }
    } else if (h < biome.minHeight + e) {
        uint ai = meshBiomeIndex(max(h - e, 0.0f), biomes, biomeCount);
        if (ai != bi) {
            float t = meshSmooth01((h - biome.minHeight) / e);
            color = mix(biomes[ai].groundColor.xyz, color, t);
        }
    }
    if (biome.emitsLight > 0.5f) {
        color = min(color * 1.6f + 0.12f, 1.0f);
    }
    rgb = color;
}

// MARK: - Kernel

kernel void mtMeshKernel(
    constant MeshParams  &p       [[buffer(0)]],
    device const ushort   *heights [[buffer(1)]],  // (res+2)^2 padded
    constant GPUBiome     *biomes  [[buffer(2)]],
    device MeshVertexOut  *out     [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    uint n = p.res;
    uint mainCount = n * n;
    uint pres = n + 2u;

    // Resolve (a, b) grid coords and skirt edge info for this thread.
    uint a, b;
    bool isSkirt = gid >= mainCount;
    float3 skirtNormal = float3(0.0f);
    if (!isSkirt) {
        a = gid % n;
        b = gid / n;
    } else {
        uint k = gid - mainCount;
        uint skirtCount = 4u * n - 4u;
        if (k >= skirtCount) { return; }
        // Same edge order as appendSkirtVertices: bottom, right, top, left.
        if (k < n) {
            a = k; b = 0u; skirtNormal = float3(0.0f, 0.0f, -1.0f);
        } else if (k < n + (n - 1u)) {
            b = (k - n) + 1u; a = n - 1u; skirtNormal = float3(1.0f, 0.0f, 0.0f);
        } else if (k < n + 2u * (n - 1u)) {
            uint t = k - n - (n - 1u);
            a = (n - 2u) - t; b = n - 1u; skirtNormal = float3(0.0f, 0.0f, 1.0f);
        } else {
            uint t = k - n - 2u * (n - 1u);
            b = (n - 2u) - t; a = 0u; skirtNormal = float3(-1.0f, 0.0f, 0.0f);
        }
    }

    // Central differences from the padded heightmap.
    uint pi = a + 1u, pj = b + 1u;
    float h  = (float)heights[pj * pres + pi] / 65535.0f;
    float hL = (float)heights[pj * pres + (pi - 1u)] / 65535.0f;
    float hR = (float)heights[pj * pres + (pi + 1u)] / 65535.0f;
    float hD = (float)heights[(pj - 1u) * pres + pi] / 65535.0f;
    float hU = (float)heights[(pj + 1u) * pres + pi] / 65535.0f;
    float dYdx = p.heightScale * (hR - hL) / (2.0f * p.cell);
    float dYdz = p.heightScale * (hU - hD) / (2.0f * p.cell);
    float3 normal = normalize(float3(-dYdx, 1.0f, -dYdz));

    float wx = p.x0 + (float)a * p.step;
    float wz = p.z0 + (float)b * p.step;
    float wy = h * p.heightScale;

    float3 rgb;
    float material;
    meshGroundColor(h, normal.y, biomes, p.biomeCount, rgb, material);

    MeshVertexOut v;
    if (!isSkirt) {
        v.position = packed_float3(float3((float)wx, wy, (float)wz));
        v.normalXY = meshEncodeNormal(normal);
        v.rgba = meshEncodeColor(rgb, material);
    } else {
        // Skirt: drop straight down, axis-aligned outward normal,
        // darkened color, material forced to rock (matches CPU).
        v.position = packed_float3(float3((float)wx, wy - p.skirtDepth, (float)wz));
        v.normalXY = meshEncodeNormal(skirtNormal);
        v.rgba = meshEncodeColor(rgb * 0.55f, 1.0f);
    }
    out[gid] = v;
}
