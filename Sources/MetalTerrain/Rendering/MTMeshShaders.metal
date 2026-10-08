// MTMeshShaders.metal — mesh-shader terrain path for the MetalTerrain library.
//
// M3-family GPUs only (Apple GPU family 9+: M3/M4/M5, A17 Pro, A18/A18 Pro,
// A19/A19 Pro and later). Everything in this file is wrapped in
// `#ifdef M3_FEATURES`, so without the M3_FEATURES Metal compilation
// condition none of these symbols exist in the default library.
//
// What it does: renders terrain chunks with no CPU-side vertex buffers.
//   - `mesh_terrain_object` ([[object]]): one threadgroup per chunk. Reads
//     per-chunk params (object buffer 0) and the shared MTUniforms block
//     (object buffer 1), frustum-culls the chunk's bounding sphere, and on
//     a hit writes the MTMeshPayload and dispatches the tile grid.
//   - `mesh_terrain_mesh` ([[mesh]]): one threadgroup per 8x8-quad tile.
//     Expands the chunk heightmap (mesh buffer 0) into vertices — world
//     position from the height sample, normals by central differences,
//     colors by the same biome rules as MTMeshBuilder.groundColor — then
//     emits indexed triangles with the same winding as
//     MTMeshBuilder.gridIndices.
//   - `mesh_terrain_fragment`: pixel-for-pixel port of `terrain_fragment`
//     (detail noise + directional NdotL/ambient + per-material specular +
//     exponential fog), renamed so it cannot collide with MTShaders.metal.
//
// Visual parity: the mesh path must look identical to the standard vertex
// path. Height sampling, normal math, biome coloring (including the h>0.65
// rock rule, the cliff rule, 0.12 border blending, and the emissive boost),
// and the fragment lighting are direct ports of the CPU/Swift code.
//
// Known intentional difference: the standard path appends vertical skirts
// around each chunk edge; the mesh path emits the surface only. (A skirt
// tile pass can be added later without touching the surface tiles.)
//
// Buffer index map (object/mesh stages have their own binding namespaces,
// separate from the vertex/fragment stages):
//   object   buffer(0): MTMeshChunkParams (one chunk, via setObjectBytes)
//   object   buffer(1): MTUniforms (192 bytes, same layout as MTShaders.metal)
//   mesh     buffer(0): heightmap, `device ushort*` (resolution*resolution
//                       quantized heights, row-major — MTChunk.heights layout)
//   mesh     buffer(1): MTMeshBiome table (constant, up to 16 entries)
//   mesh     buffer(2): biome count (uint, via setMeshBytes)
//   fragment buffer(1): MTUniforms — intentionally the same index the
//                       standard terrain_fragment uses, so the renderer
//                       binds uniforms identically for both paths.

#include <metal_stdlib>
using namespace metal;

#ifdef M3_FEATURES

// One mesh-shader tile covers at most 8x8 quads: 9x9 = 81 vertices and
// 8*8*2 = 128 triangles.
#define MT_MESH_TILE_QUADS 8
#define MT_MESH_TILE_MAX_VERTS 81
#define MT_MESH_TILE_MAX_TRIS 128
// Max biomes in the constant color table (7 built-in + headroom for customs).
#define MT_MESH_MAX_BIOMES 16

/// Per-chunk input to the object shader. Swift mirror: `MTMeshChunkParams`
/// in MTTerrainRenderer.swift (40 bytes — the renderer asserts the stride).
struct MTMeshChunkParams {
    float2 chunkOrigin;  // world XZ of the chunk's (0,0) heightmap corner
    float  worldSize;    // world units per chunk side
    float  heightScale;  // world Y at normalized height 1
    float  resolution;   // heightmap samples per side (as float)
    float  lodStride;    // 1 = full resolution, 2 = half resolution
    float  minY;         // world-space min height (padded AABB, for culling)
    float  maxY;         // world-space max height (padded AABB, for culling)
    float2 pad;          // tail padding to a 16-byte multiple
};

/// Object → mesh payload. Written once per chunk by the object shader and
/// read by every mesh threadgroup of that chunk.
struct MTMeshPayload {
    float4x4 viewProj;    // clip transform (terrain chunks use identity model)
    float2   chunkOrigin; // world XZ of the chunk's (0,0) heightmap corner
    float    worldSize;
    float    heightScale;
    float    resolution;  // heightmap samples per side (as float)
    float    lodStride;   // 1 = full resolution, 2 = half resolution
    uint     gridN;       // vertices per side at this LOD
    uint     pad0;
    float    time;        // seconds, for animated water/detail
    float    detailAmt;   // 0=off … 1=full procedural geometric detail
};

/// One biome's coloring rules for the mesh shader. Swift mirror:
/// `MTMeshBiomeGPU` in MTTerrainRenderer.swift (48 bytes). The table is
/// packed custom-biomes-first, then built-ins — the same order
/// `MTTerrainWorld.biomeAt` consults.
struct MTMeshBiome {
    float4 groundAndMin;  // rgb = groundColor, w = minHeight
    float4 slopeAndMax;   // rgb = slopeColor (== groundColor when none), w = maxHeight
    float4 ids;           // x = base material id, y = emitsLight 0/1,
                         // z = hasSlopeColor 0/1, w = isSnowyPeak 0/1
};

/// Must stay layout-identical to `MTUniforms` in MTShaders.metal (224
/// bytes). The fragment shader below reads the same uniform buffer the
/// renderer already binds at fragment buffer(1) for the standard path.
struct MTUniforms {
    float4x4 viewProj;
    float4x4 model;
    float4 cameraPos;   // xyz = camera position
    float4 fogColor;    // rgb = fog color, w = fog density
    float4 lightDir;    // xyz = light direction, w = ambient strength
    float4 misc;        // x = time seconds, y = shader effects (0/1)
    float4 seaLevel;    // x = world-space water level (for shoreline foam)
    float4 sunColor;    // rgb = sun tint (time-of-day), w = unused
};

/// Mesh-stage vertex output. Field-for-field identical to `MTVaryings` in
/// MTShaders.metal so the fragment math below matches the standard path.
struct MTMeshVaryings {
    float4 clipPos [[position]];
    float3 worldPos;
    float3 normal;
    float3 color;
    float material;  // 0=grass, 1=rock, 2=sand, 3=snow, 4=deep snow, 5=water
};

/// Normalizes a frustum plane (divides by the xyz length), guarding the
/// degenerate zero-length case. Mirrors `MTTerrainRenderer.normalizePlane`.
float4 meshNormPlane(float4 pl) {
    float len = length(pl.xyz);
    return len > 0.0f ? pl / len : pl;
}

/// Smoothstep 0→1 over [0,1]. Mirrors `MTMeshBuilder.smooth01`.
float meshSmooth01(float t) {
    float c = clamp(t, 0.0f, 1.0f);
    return c * c * (3.0f - 2.0f * c);
}

/// Hash-based value noise for procedural geometric detail. Two octaves
/// give natural-looking bumps without visible tiling at terrain scale.
float meshHash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

float meshValueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    float a = meshHash21(i);
    float b = meshHash21(i + float2(1.0f, 0.0f));
    float c = meshHash21(i + float2(0.0f, 1.0f));
    float d = meshHash21(i + float2(1.0f, 1.0f));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Two-octave detail noise in [0,1].
float meshDetailNoise(float2 p) {
    return meshValueNoise(p) * 0.65f + meshValueNoise(p * 2.7f + 13.7f) * 0.35f;
}

/// Procedural geometric displacement amount for a material.
/// Returns (amplitude, frequency). This is REAL geometry — the mesh shader
/// displaces vertices along the normal, giving grass, rock, sand, and snow
/// actual 3D texture instead of flat shading.
/// Material ids: 0=grass, 1=rock, 2=sand, 3=snow, 4=deep snow, 5=water.
/// Water gets NO displacement (must stay flat to avoid shore glitches).
float2 meshDetailParams(float material) {
    if (material < 0.5f) {          // grass: gentle tufty bumps
        return float2(0.9f, 0.55f);
    } else if (material < 1.5f) {   // rock: craggy
        return float2(1.6f, 0.35f);
    } else if (material < 2.5f) {   // sand: fine ripples
        return float2(0.35f, 1.4f);
    } else if (material < 4.5f) {   // snow: soft drifts
        return float2(0.5f, 0.22f);
    }
    return float2(0.0f, 1.0f);
}

/// Biome-table lookup mirroring `MTTerrainWorld.biomeAt`: two passes so a
/// height exactly on a maxHeight boundary still matches. Returns -1 when
/// nothing matches (the caller falls back to flat gray, like the Swift
/// "void" biome).
int meshBiomeIndex(float h, constant MTMeshBiome *biomes, uint biomeCount) {
    h = clamp(h, 0.0f, 1.0f);
    for (uint pass = 0; pass < 2; ++pass) {
        for (uint k = 0; k < biomeCount; ++k) {
            float mn = biomes[k].groundAndMin.w;
            float mx = biomes[k].slopeAndMax.w;
            if (h >= mn && (h < mx || (pass == 1u && h <= mx))) {
                return int(k);
            }
        }
    }
    return -1;
}

/// Vertex color for a terrain sample. Direct port of
/// `MTMeshBuilder.groundColor`: the h>0.65 mountain rock rule
/// (anti-banding), the steep-slope cliff override, 0.12 border blending
/// toward neighboring biomes, and the emissive boost.
/// Returns rgb + material id in alpha.
float4 meshGroundColor(float h,
                       float normalY,
                       constant MTMeshBiome *biomes,
                       uint biomeCount) {
    // Mountains: force rock to prevent grass/forest banding from height
    // oscillation; blend rock→snow above 0.80. (Constants hardcoded here
    // exactly as in the CPU builder.)
    if (h > 0.65f) {
        if (h > 0.80f) {
            float t = min(1.0f, (h - 0.80f) / 0.12f);
            float3 c = mix(float3(0.45f, 0.42f, 0.38f),
                           float3(0.90f, 0.92f, 0.95f), t);
            return float4(c, h > 0.92f ? 4.0f : 3.0f);
        }
        return float4(float3(0.45f, 0.42f, 0.38f), 1.0f);
    }
    int bi = meshBiomeIndex(h, biomes, biomeCount);
    if (bi < 0) {
        return float4(float3(0.5f), 0.0f);  // "void" fallback
    }
    MTMeshBiome b = biomes[bi];
    float slope = 1.0f - normalY;
    // Cliffs: slopes steeper than 0.55 use the biome's slope color.
    if (slope > 0.55f && b.ids.z > 0.5f) {
        return float4(b.slopeAndMax.rgb, 1.0f);
    }
    float3 color = b.groundAndMin.rgb;
    const float e = 0.12f;  // biomeBlendRange
    float minH = b.groundAndMin.w;
    float maxH = b.slopeAndMax.w;
    if (h > maxH - e) {
        // Near the top border: blend toward the biome above.
        int ai = meshBiomeIndex(min(h + e, 1.0f), biomes, biomeCount);
        if (ai >= 0 && ai != bi) {
            float t = meshSmooth01((maxH - h) / e);
            color = mix(biomes[ai].groundAndMin.rgb, color, t);
        }
    } else if (h < minH + e) {
        // Near the bottom border: blend toward the biome below.
        int bi2 = meshBiomeIndex(max(h - e, 0.0f), biomes, biomeCount);
        if (bi2 >= 0 && bi2 != bi) {
            float t = meshSmooth01((h - minH) / e);
            color = mix(biomes[bi2].groundAndMin.rgb, color, t);
        }
    }
    // Emissive biomes (e.g. alien crystal fields) glow.
    if (b.ids.y > 0.5f) {
        color = min(color * 1.6f + float3(0.12f), float3(1.0f));
    }
    float material = b.ids.x;
    if (b.ids.w > 0.5f) {  // snowyPeak: deep snow above 0.92
        material = h > 0.92f ? 4.0f : 3.0f;
    }
    return float4(color, material);
}

/// Lighting: directional NdotL + ambient, per-material specular, fresnel
/// rim, exponential distance fog. Pixel-for-pixel port of `applyLighting`
/// in MTShaders.metal (renamed to avoid a duplicate symbol in the default
/// library) — keep the two in sync.
float3 meshApplyLighting(float3 albedo,
                         float3 normal,
                         float3 worldPos,
                         float material,
                         constant MTUniforms &uniforms) {
    float3 n = normalize(normal);
    float3 viewDir = normalize(uniforms.cameraPos.xyz - worldPos);
    float3 lightDir = uniforms.lightDir.xyz;  // v1.3.0: pre-normalized on CPU

    // Diffuse: NdotL with wrap for softer terminator.
    float ndl = dot(n, lightDir);
    float wrapNdl = clamp((ndl + 0.4) / 1.4, 0.0, 1.0);
    float amb = uniforms.lightDir.w;

    // Per-material specular: (intensity, shininess)
    // 0=grass, 1=rock, 2=sand, 3=snow, 4=deep snow, 5=water
    float specIntensity;
    float specShininess;
    if (material < 0.5) {           // grass: slight sheen
        specIntensity = 0.12; specShininess = 24.0;
    } else if (material < 1.5) {    // rock: least reflective, rough
        specIntensity = 0.03; specShininess = 12.0;
    } else if (material < 2.5) {    // sand: barely, diffuse
        specIntensity = 0.06; specShininess = 16.0;
    } else if (material < 3.5) {    // snow: soft glow
        specIntensity = 0.22; specShininess = 32.0;
    } else if (material < 4.5) {    // deep snow: sparkly
        specIntensity = 0.40; specShininess = 64.0;
    } else {                        // water: mirror-like
        specIntensity = 0.85; specShininess = 128.0;
    }

    // Specular: Blinn-Phong using Metal's built-in reflect/normalize/pow.
    float3 halfVec = normalize(lightDir + viewDir);
    float spec = pow(max(dot(n, halfVec), 0.0), specShininess) * specIntensity;
    // Only on upward faces (not cliffs).
    spec *= clamp(n.y * 1.5, 0.0, 1.0);

    // Fresnel rim: subtle edge definition (kept low to avoid plastic look).
    float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0) * 0.12;

    float3 lit = albedo * (amb + wrapNdl * (1.0 - amb) * uniforms.sunColor.rgb);
    // Shader effects (specular + fresnel) are toggleable.
    if (uniforms.misc.y > 0.5) {
        lit += spec * uniforms.sunColor.rgb;  // sun-tinted glint
        lit += fresnel * albedo;
    }

    float dist = distance(worldPos, uniforms.cameraPos.xyz);
    float dens = uniforms.fogColor.w;
    float f = 1.0 - exp(-dens * dens * dist * dist);
    return mix(lit, uniforms.fogColor.rgb, clamp(f, 0.0, 1.0));
}

/// Object shader: one threadgroup per chunk — launch with
/// threadsPerObjectThreadgroup = (1,1,1) and threadgroupsPerGrid = (1,1,1),
/// one drawMeshThreadgroups call per chunk (mirrors the standard path's
/// "1 draw call per chunk").
///
/// Reads the chunk params (object buffer 0) and the shared uniforms
/// (object buffer 1), culls the chunk's bounding sphere against the view
/// frustum, and on a hit writes the mesh payload and dispatches a tile
/// grid of ceil((gridN-1)/8)^2 mesh threadgroups. A culled chunk dispatches
/// zero threadgroups.
[[object]]
void mesh_terrain_object(object_data<MTMeshPayload> m,
                         constant MTMeshChunkParams &params [[buffer(0)]],
                         constant MTUniforms &uniforms [[buffer(1)]],
                         uint tid [[thread_index_in_threadgroup]]) {
    if (tid != 0u) {
        return;
    }

    // Frustum planes from the view-projection matrix — the same extraction
    // as MTTerrainRenderer.Frustum in Swift (column-major float4x4).
    const float4x4 vp = uniforms.viewProj;
    const float4 r0 = float4(vp[0][0], vp[1][0], vp[2][0], vp[3][0]);
    const float4 r1 = float4(vp[0][1], vp[1][1], vp[2][1], vp[3][1]);
    const float4 r2 = float4(vp[0][2], vp[1][2], vp[2][2], vp[3][2]);
    const float4 r3 = float4(vp[0][3], vp[1][3], vp[2][3], vp[3][3]);
    float4 planes[6];
    planes[0] = meshNormPlane(r3 + r0);  // left
    planes[1] = meshNormPlane(r3 - r0);  // right
    planes[2] = meshNormPlane(r3 + r1);  // bottom
    planes[3] = meshNormPlane(r3 - r1);  // top
    planes[4] = meshNormPlane(r2);       // near (Metal depth is [0,1])
    planes[5] = meshNormPlane(r3 - r2);  // far

    // Bounding sphere of the chunk. minY/maxY arrive as the chunk's padded
    // AABB Y extents — the same values the CPU path culls against.
    const float3 center = float3(params.chunkOrigin.x + params.worldSize * 0.5f,
                                 (params.minY + params.maxY) * 0.5f,
                                 params.chunkOrigin.y + params.worldSize * 0.5f);
    const float radius = length(float3(params.worldSize * 0.5f,
                                       (params.maxY - params.minY) * 0.5f,
                                       params.worldSize * 0.5f));
    for (int k = 0; k < 6; ++k) {
        if (dot(planes[k].xyz, center) + planes[k].w < -radius) {
            m.set_threadgroup_count(uint3(0u, 0u, 0u));  // culled
            return;
        }
    }

    MTMeshPayload p;
    p.viewProj = uniforms.viewProj;
    p.chunkOrigin = params.chunkOrigin;
    p.worldSize = params.worldSize;
    p.heightScale = params.heightScale;
    p.resolution = params.resolution;
    p.lodStride = params.lodStride;
    // Vertices per side at this LOD — the same integer math as
    // MTMeshBuilder.buildGrid: n = (res-1)/step + 1.
    const int res_i = int(params.resolution + 0.5f);
    const int step_i = int(params.lodStride + 0.5f);
    p.gridN = uint((res_i - 1) / step_i + 1);
    p.pad0 = 0u;
    p.time = uniforms.misc.x;
    p.detailAmt = uniforms.misc.w;
    m.set_payload(p);

    const uint tiles = (p.gridN - 1u + 7u) / 8u;
    m.set_threadgroup_count(uint3(tiles, tiles, 1u));
}

/// Mesh shader: one threadgroup per 8x8-quad tile of the chunk grid —
/// launch with threadsPerMeshThreadgroup = (128,1,1).
///
/// Threads 0..80 emit the tile's vertices (heightmap sample → world
/// position, central-difference normal, biome color); threads
/// 0..2*qw*qh emit the tile's indexed triangles with the same winding the
/// CPU builder uses. Vertices are a pure function of grid coordinates, so
/// tiles need no cross-threadgroup sharing; the last strip of tiles may be
/// partial (qw/qh < 8) and out-of-range threads simply skip.
///
/// Heights are UInt16 quantized (0...65535 maps to 0...1).
[[mesh]]
void mesh_terrain_mesh(mesh<MTMeshVertexOut, void, MTMeshPayload,
                            MT_MESH_TILE_MAX_VERTS, MT_MESH_TILE_MAX_TRIS,
                            triangle> m,
                       const device ushort *heights [[buffer(0)]],
                       constant MTMeshBiome *biomes [[buffer(1)]],
                       constant uint &biomeCount [[buffer(2)]],
                       uint tid [[thread_index_in_threadgroup]],
                       uint3 tileId [[threadgroup_position_in_grid]]) {
    const MTMeshPayload p = m.get_payload();
    const int res = int(p.resolution + 0.5f);
    const int step = int(p.lodStride + 0.5f);
    const int n = int(p.gridN);
    const float cell = p.worldSize / (p.resolution - 1.0f);  // world units per sample
    const int tx = int(tileId.x);
    const int ty = int(tileId.y);
    // Quads this tile actually covers (the last strip may be partial).
    const int qw = min(MT_MESH_TILE_QUADS, n - 1 - tx * MT_MESH_TILE_QUADS);
    const int qh = min(MT_MESH_TILE_QUADS, n - 1 - ty * MT_MESH_TILE_QUADS);

    // Vertices: one per grid point in the tile's 9x9 layout.
    if (tid < MT_MESH_TILE_MAX_VERTS) {
        const int a = int(tid) % (MT_MESH_TILE_QUADS + 1);
        const int b = int(tid) / (MT_MESH_TILE_QUADS + 1);
        const int ga = tx * MT_MESH_TILE_QUADS + a;
        const int gb = ty * MT_MESH_TILE_QUADS + b;
        if (ga < n && gb < n) {
            // Heightmap sample index, mirroring MTMeshBuilder.buildGrid:
            // the far row/column clamps onto the chunk border.
            int i = (ga == n - 1) ? res - 1 : ga * step;
            int j = (gb == n - 1) ? res - 1 : gb * step;
            i = min(i, res - 1);
            j = min(j, res - 1);
            // UInt16 quantized height → float 0...1.
            const float h = float(heights[j * res + i]) / 65535.0;

            // Central differences of the heightfield -> world-space normal.
            // One-sided at the chunk border.
            const int iL = max(i - 1, 0), iR = min(i + 1, res - 1);
            const int jD = max(j - 1, 0), jU = min(j + 1, res - 1);
            const float dYdx = p.heightScale * (float(heights[j * res + iR]) - float(heights[j * res + iL])) / 65535.0
                             / (float(iR - iL) * cell);
            const float dYdz = p.heightScale * (float(heights[jU * res + i]) - float(heights[jD * res + i])) / 65535.0
                             / (float(jU - jD) * cell);
            const float3 nrm = normalize(float3(-dYdx, 1.0f, -dYdz));

            const float wx = p.chunkOrigin.x + float(i) / (p.resolution - 1.0f) * p.worldSize;
            const float wz = p.chunkOrigin.y + float(j) / (p.resolution - 1.0f) * p.worldSize;
            float wy = h * p.heightScale;
            const float4 rgba = meshGroundColor(h, nrm.y, biomes, biomeCount);

            // Procedural geometric detail: displace along the normal by
            // material-specific noise. This is real 3D texture — grass gets
            // tufty bumps, rock gets craggy displacement, sand gets ripples,
            // snow gets soft drifts. Water animates with time.
            // Time and detail amount arrive via the object-shader payload.
            float detailAmt = p.detailAmt;
            float3 finalNrm = nrm;
            if (detailAmt > 0.001f) {
                float2 dp = meshDetailParams(rgba.a);
                float2 np = float2(wx, wz) * dp.y;
                float baseN = meshDetailNoise(np);
                // Water waves animate; everything else is static.
                float timeOff = (rgba.a > 4.5f && rgba.a < 5.5f) ? p.time * 0.8f : 0.0f;
                float n0 = meshDetailNoise(np + float2(timeOff, timeOff * 0.7f));
                float disp = (n0 - 0.5f) * 2.0f * dp.x * detailAmt;
                wy += disp * nrm.y;
                // Perturb the normal by the noise gradient so lighting
                // follows the bumps. Central differences, small epsilon.
                float e = 0.6f;
                float nx = meshDetailNoise(np + float2(e, 0.0f) + float2(timeOff, 0.0f)) - baseN;
                float nz = meshDetailNoise(np + float2(0.0f, e) + float2(0.0f, timeOff * 0.7f)) - baseN;
                float gradScale = dp.x * detailAmt * 2.0f / e;
                finalNrm = normalize(nrm + float3(-nx * gradScale, 0.0f, -nz * gradScale));
            }

            MTMeshVertexOut v;
            const float4 world = float4(wx, wy, wz, 1.0f);
            v.clipPos = p.viewProj * world;
            v.worldPos = world.xyz;
            v.normal = finalNrm;
            v.color = rgba.rgb;
            v.material = rgba.a;
            m.set_vertex(tid, v);
        }
    }

    // Triangles: two per quad, wound counter-clockwise seen from +Y —
    // Metal's front face, matching MTMeshBuilder.gridIndices.
    // Dense mapping: valid quads are exactly q < qw*qh, so threads
    // tid < 2*qw*qh form a dense prefix with no index-buffer holes.
    const uint triCount = uint(2 * qw * qh);
    if (tid < triCount) {
        const uint q = tid / 2u;
        const uint t = tid % 2u;
        const uint qa = q % uint(qw);
        const uint qb = q / uint(qw);
        const uint v00 = qb * 9u + qa;
        const uint v10 = v00 + 1u;
        const uint v01 = v00 + 9u;
        const uint v11 = v01 + 1u;
        const uint base = tid * 3u;
        if (t == 0u) {
            m.set_index(base, v00);
            m.set_index(base + 1u, v10);
            m.set_index(base + 2u, v11);
        } else {
            m.set_index(base, v00);
            m.set_index(base + 1u, v11);
            m.set_index(base + 2u, v01);
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0u) {
        m.set_primitive_count(triCount);
    }
}

/// Fragment shader for the mesh pipeline: exact port of `terrain_fragment`
/// (per-pixel detail noise + shared lighting/fog). Reads the same
/// MTUniforms block at fragment buffer(1) the renderer already binds for
/// the standard path, so no binding changes are needed.
///
/// Wireframe mode (uniforms.misc.z > 0.5): instead of raw triangle edges
/// (the Lego look), draws smooth anti-aliased contour lines that flow
/// across the terrain with an animated pulse. Much smoother because the
/// lines follow the terrain surface, not the triangulation.
fragment float4 mesh_terrain_fragment(MTMeshVaryings in [[stage_in]],
                                      constant MTUniforms &uniforms [[buffer(1)]]) {
    // Per-pixel detail: subtle high-frequency variation breaks up the flat
    // look of per-vertex biome colors. Uses a cheap hash-based value noise.
    float3 p = in.worldPos * 0.35;
    float n = fract(sin(dot(floor(p.xz), float2(12.9898, 78.233))) * 43758.5453);
    float n2 = fract(sin(dot(floor(p.xz) + 1.0, float2(12.9898, 78.233))) * 43758.5453);
    float detail = mix(n, n2, 0.5) - 0.5;  // -0.5 ... 0.5
    float3 varied = in.color * (1.0 + detail * 0.12);
    float3 col = meshApplyLighting(varied, in.normal, in.worldPos, in.material, uniforms);

    // Smooth animated wireframe overlay.
    if (uniforms.misc.z > 0.5f) {
        float time = uniforms.misc.x;
        // Contour lines: smooth iso-height bands flowing over the surface.
        // Frequency scales with terrain so lines stay readable at any zoom.
        float contourFreq = 0.08f;
        float contour = abs(fract(in.worldPos.y * contourFreq - time * 0.15f) - 0.5f);
        float contourLine = 1.0f - smoothstep(0.0f, fwidth(in.worldPos.y * contourFreq) * 2.0f + 0.02f, contour);
        // Grid lines on XZ, anti-aliased via screen-space derivatives.
        float2 gp = in.worldPos.xz * 0.02f;
        float2 fw = fwidth(gp) + 1e-4f;
        float2 g = abs(fract(gp - 0.5f) - 0.5f) / fw;
        float gridLine = 1.0f - smoothstep(0.0f, 1.2f, min(g.x, g.y));
        // Animated pulse radiating from the camera, brightening lines.
        float dist = length(in.worldPos.xz - uniforms.cameraPos.xz);
        float pulse = sin(dist * 0.03f - time * 2.5f);
        float glow = smoothstep(0.6f, 1.0f, pulse) * 0.8f + 0.2f;
        float wire = max(contourLine * 0.9f, gridLine * 0.55f);
        float3 wireColor = mix(float3(0.2f, 0.9f, 1.0f), float3(1.0f, 1.0f, 1.0f), glow);
        // Fade with distance so far terrain doesn't shimmer.
        float fade = 1.0f - smoothstep(800.0f, 2500.0f, dist);
        col = mix(col, wireColor * (0.6f + glow * 0.6f), wire * fade * 0.85f);
    }
    return float4(col, 1.0);
}

#endif // M3_FEATURES
