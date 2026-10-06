// MTShaders.metal — ORIGINAL shaders for the MetalTerrain library.
//
// Terrain, water, and instanced-structure shaders sharing one vertex format
// (position/normal/color float3) and one lighting model: directional NdotL +
// ambient, with exponential distance fog. Metal 3 baseline; no Metal 4-only
// shading-language features are used, so the same source compiles on both.

#include <metal_stdlib>
using namespace metal;

// Must match MTVertex in MTMeshBuilder.swift (36 bytes).
struct MTVertexIn {
    float4 position;  // xyz
    float4 normal;    // xyz
    float4 color;     // rgb
};

// Must match MTUniforms in MTTerrainRenderer.swift (208 bytes).
// Uses float4 packing on both sides: Swift's SIMD3<Float> is 16-byte
// aligned (unlike Metal's 12-byte float3), so float3 fields would desync
// the layout. Pack small fields into float4s instead.
struct MTUniforms {
    float4x4 viewProj;
    float4x4 model;
    float4 cameraPos;   // xyz = camera position
    float4 fogColor;    // rgb = fog color, w = fog density
    float4 lightDir;    // xyz = light direction, w = ambient strength
    float4 misc;        // x = time, y = shaderFX (0/1), z = wireframe (0/1), w = detailAmount
    float4 seaLevel;    // x = world-space water level (for shoreline foam)
};

// Must match MTInstanceData in MTTerrainRenderer.swift (80 bytes).
struct MTInstanceData {
    float4x4 model;
    float4 tint;        // rgb = color tint
};

struct MTVaryings {
    float4 clipPos [[position]];
    float3 worldPos;
    float3 normal;
    float3 color;
    float material;  // 0=grass, 1=rock, 2=sand, 3=snow, 4=deep snow, 5=water
};

/// Hash-based value noise for procedural geometric detail (standard path).
float meshHash21Std(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}
float meshValueNoiseStd(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    return mix(mix(meshHash21Std(i), meshHash21Std(i + float2(1,0)), u.x),
               mix(meshHash21Std(i + float2(0,1)), meshHash21Std(i + float2(1,1)), u.x), u.y);
}
float meshDetailNoiseStd(float2 p) {
    return meshValueNoiseStd(p) * 0.65f + meshValueNoiseStd(p * 2.7f + 13.7f) * 0.35f;
}
/// Procedural displacement (amplitude, frequency) per material.
float2 meshDetailParamsStd(float material) {
    if (material < 0.5f) return float2(0.9f, 0.55f);       // grass: tufty bumps
    else if (material < 1.5f) return float2(1.6f, 0.35f);  // rock: craggy
    else if (material < 2.5f) return float2(0.35f, 1.4f); // sand: ripples
    else if (material < 4.5f) return float2(0.5f, 0.22f); // snow: drifts
    // Water (5): NO geometric displacement — the water plane must stay
    // perfectly flat to avoid shore glitching and z-fighting. Water
    // animation is handled in the fragment shader instead.
    return float2(0.0f, 1.0f);
}

// Shared vertex transform: model matrix, then view-projection.
// Applies procedural geometric detail displacement (same as the mesh
// shader path) so standard-path terrain also gets real 3D texture.
vertex MTVaryings terrain_vertex(const device MTVertexIn *vertices [[buffer(0)]],
                                 constant MTUniforms &uniforms [[buffer(1)]],
                                 uint vid [[vertex_id]]) {
    MTVertexIn v = vertices[vid];
    float material = v.color.a;
    float3 worldPos = (uniforms.model * float4(v.position.xyz, 1.0)).xyz;
    float3 nrm = normalize((uniforms.model * float4(v.normal.xyz, 0.0)).xyz);
    // Procedural detail: displace along normal by material noise.
    // misc: x=time, y=shaderFX, z=wireframe, w=detailAmount
    float detailAmt = uniforms.misc.w;
    if (detailAmt > 0.001f) {
        float2 dp = meshDetailParamsStd(material);
        float2 np = worldPos.xz * dp.y;
        float timeOff = (material > 4.5f && material < 5.5f) ? uniforms.misc.x * 0.8f : 0.0f;
        float n0 = meshDetailNoiseStd(np + float2(timeOff, timeOff * 0.7f));
        worldPos.y += (n0 - 0.5f) * 2.0f * dp.x * detailAmt * nrm.y;
    }
    float4 world = float4(worldPos, 1.0);
    MTVaryings out;
    out.clipPos = uniforms.viewProj * world;
    out.worldPos = worldPos;
    out.normal = nrm;
    out.color = v.color.rgb;
    out.material = material;
    return out;
}

// Directional NdotL + ambient, then exponential distance fog.
float3 applyLighting(float3 albedo,
                     float3 normal,
                     float3 worldPos,
                     float material,
                     constant MTUniforms &uniforms) {
    float3 n = normalize(normal);
    float3 viewDir = normalize(uniforms.cameraPos.xyz - worldPos);
    float3 lightDir = normalize(uniforms.lightDir.xyz);

    // Diffuse: NdotL with wrap for softer terminator.
    float ndl = dot(n, lightDir);
    float wrapNdl = clamp((ndl + 0.4) / 1.4, 0.0, 1.0);
    float amb = uniforms.lightDir.w;
    float sunIntensity = uniforms.seaLevel.y;  // v1.0.5: configurable sun intensity

    // Per-material specular: (intensity, shininess)
    // 0=grass, 1=rock, 2=sand, 3=snow, 4=deep snow, 5=water
    // Rock least, sand barely, grass slightly more.
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

    float3 lit = albedo * (amb + wrapNdl * sunIntensity * (1.0 - amb));
    // Shader effects (specular + fresnel) are toggleable.
    if (uniforms.misc.y > 0.5) {
        lit += spec * float3(1.0, 0.98, 0.92);  // warm sun glint
        lit += fresnel * albedo;
    }

    float dist = distance(worldPos, uniforms.cameraPos.xyz);
    float dens = uniforms.fogColor.w;
    float f = 1.0 - exp(-dens * dens * dist * dist);
    return mix(lit, uniforms.fogColor.rgb, clamp(f, 0.0, 1.0));
}

fragment float4 terrain_fragment(MTVaryings in [[stage_in]],
                                 constant MTUniforms &uniforms [[buffer(1)]]) {
    // Per-pixel detail: subtle high-frequency variation breaks up the flat
    // look of per-vertex biome colors. Uses a cheap hash-based value noise.
    float3 p = in.worldPos * 0.35;
    float n = fract(sin(dot(floor(p.xz), float2(12.9898, 78.233))) * 43758.5453);
    float n2 = fract(sin(dot(floor(p.xz) + 1.0, float2(12.9898, 78.233))) * 43758.5453);
    float detail = mix(n, n2, 0.5) - 0.5;  // -0.5 ... 0.5
    float3 varied = in.color * (1.0 + detail * 0.12);

    // Bump mapping: perturb the normal with per-pixel noise for visible
    // 3D surface texture. Stronger for rock (craggy), subtle for grass.
    float bumpScale;
    if (in.material < 0.5) bumpScale = 0.15;       // grass: subtle
    else if (in.material < 1.5) bumpScale = 0.45;   // rock: craggy
    else if (in.material < 2.5) bumpScale = 0.20;   // sand: ripples
    else bumpScale = 0.25;                          // snow: soft drifts
    float2 bp = in.worldPos.xz * 0.8;
    float bn1 = fract(sin(dot(floor(bp), float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    float bn2 = fract(sin(dot(floor(bp + 0.5), float2(39.346, 11.135))) * 24634.6345) - 0.5;
    float3 bumpedNormal = normalize(in.normal + float3(bn1, 0.0, bn2) * bumpScale);

    float3 col = applyLighting(varied, bumpedNormal, in.worldPos, in.material, uniforms);

    // Smooth animated wireframe overlay (same as mesh-shader path).
    // misc.z = wireframe flag.
    if (uniforms.misc.z > 0.5f) {
        float time = uniforms.misc.x;
        float contourFreq = 0.08f;
        float contour = abs(fract(in.worldPos.y * contourFreq - time * 0.15f) - 0.5f);
        float contourLine = 1.0f - smoothstep(0.0f, fwidth(in.worldPos.y * contourFreq) * 2.0f + 0.02f, contour);
        float2 gp = in.worldPos.xz * 0.02f;
        float2 fw = fwidth(gp) + 1e-4f;
        float2 g = abs(fract(gp - 0.5f) - 0.5f) / fw;
        float gridLine = 1.0f - smoothstep(0.0f, 1.2f, min(g.x, g.y));
        float dist = length(in.worldPos.xz - uniforms.cameraPos.xz);
        float pulse = sin(dist * 0.03f - time * 2.5f);
        float glow = smoothstep(0.6f, 1.0f, pulse) * 0.8f + 0.2f;
        float wire = max(contourLine * 0.9f, gridLine * 0.55f);
        float3 wireColor = mix(float3(0.2f, 0.9f, 1.0f), float3(1.0f, 1.0f, 1.0f), glow);
        float fade = 1.0f - smoothstep(800.0f, 2500.0f, dist);
        col = mix(col, wireColor * (0.6f + glow * 0.6f), wire * fade * 0.85f);
    }
    return float4(col, 1.0);
}

// Water: procedural animated texture. The plane stays geometrically flat
// (no vertex displacement) — all the wave detail is in the fragment
// shader texture, not the physical triangles. No shore-specific effects.
fragment float4 water_fragment(MTVaryings in [[stage_in]],
                               constant MTUniforms &uniforms [[buffer(1)]],
                               constant float &alpha [[buffer(2)]]) {
    float t = uniforms.misc.x;
    float2 p = in.worldPos.xz;

    // Animated wave normals (texture only, not geometry).
    float2 grad = float2(0.0);
    grad += 0.14 * float2(cos(dot(p, float2(0.11, 0.07)) + t * 0.9),
                          cos(dot(p, float2(-0.06, 0.13)) + t * 0.7));
    grad += 0.09 * float2(cos(dot(p, float2(0.31, -0.24)) + t * 1.7),
                          cos(dot(p, float2(0.22, 0.35)) + t * 1.3));
    float n1 = fract(sin(dot(floor(p * 2.0 + t * 0.5), float2(12.9898, 78.233))) * 43758.5453);
    float n2 = fract(sin(dot(floor(p * 2.0 - t * 0.3), float2(39.346, 11.135))) * 24634.6345);
    grad += (float2(n1, n2) - 0.5) * 0.22;

    float3 n = normalize(float3(-grad.x, 1.0, -grad.y));

    // Procedural texture: scrolling noise layers.
    float2 uv1 = p * 0.05 + float2(t * 0.03, t * 0.017);
    float2 uv2 = p * 0.11 - float2(t * 0.021, t * 0.038);
    float tex1 = fract(sin(dot(floor(uv1 * 8.0), float2(12.9898, 78.233))) * 43758.5453);
    float tex2 = fract(sin(dot(floor(uv2 * 8.0), float2(39.346, 11.135))) * 24634.6345);
    float texture_ = (tex1 * 0.6 + tex2 * 0.4);

    float3 deepColor = float3(0.01, 0.22, 0.35);
    float3 shallowColor = float3(0.15, 0.55, 0.65);
    float3 base = mix(deepColor, shallowColor, texture_ * 0.55);

    float3 viewDir = normalize(uniforms.cameraPos.xyz - in.worldPos);
    float3 lightDir = normalize(uniforms.lightDir.xyz);
    float diff = max(dot(n, lightDir), 0.0);

    float3 h = normalize(lightDir + viewDir);
    float spec = pow(max(dot(n, h), 0.0), 70.0) * 1.8;

    float fres = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0);
    float3 skyReflect = float3(0.40, 0.60, 0.75) * fres * 0.7;

    float3 col = base * (0.45 + diff * 0.75) + spec * float3(1.0, 0.95, 0.85) + skyReflect;

    float dist = length(in.worldPos - uniforms.cameraPos.xyz);
    float fogFactor = 1.0 - exp(-dist * uniforms.fogColor.w);
    col = mix(col, uniforms.fogColor.rgb, fogFactor);

    return float4(col, alpha);
}

// Structures: per-instance model matrix + color tint from the instance buffer.
vertex MTVaryings structure_vertex(const device MTVertexIn *vertices [[buffer(0)]],
                                   constant MTUniforms &uniforms [[buffer(1)]],
                                   const device MTInstanceData *instances [[buffer(2)]],
                                   uint vid [[vertex_id]],
                                   uint iid [[instance_id]]) {
    MTVertexIn v = vertices[vid];
    MTInstanceData inst = instances[iid];
    float4 world = inst.model * float4(v.position.xyz, 1.0);
    MTVaryings out;
    out.clipPos = uniforms.viewProj * world;
    out.worldPos = world.xyz;
    out.normal = (inst.model * float4(v.normal.xyz, 0.0)).xyz;
    out.color = v.color.rgb * inst.tint.rgb;
    out.material = 1.0;  // structures are rock-like
    return out;
}

fragment float4 structure_fragment(MTVaryings in [[stage_in]],
                                   constant MTUniforms &uniforms [[buffer(1)]]) {
    float3 col = applyLighting(in.color, in.normal, in.worldPos, in.material, uniforms);
    return float4(col, 1.0);
}

#ifdef M3_FEATURES
// ---- Hardware ray-traced sun shadows (M3+/A17 Pro+) ----
// Bind the TLAS with `encoder.setFragmentAccelerationStructure(tlas, at: 3)`.

#include <metal_raytracing>
using namespace metal::raytracing;

/// Hard shadow test against the terrain TLAS. Returns 1.0 when the segment
/// from `origin` along `dir` (length `maxDistance`) hits terrain, else 0.0.
inline float rt_shadow_occlusion(instance_acceleration_structure tlas,
                                 float3 origin,
                                 float3 dir,
                                 float maxDistance) {
    intersector<instancing, triangle_data> trace;
    trace.assume_geometry_type(geometry_type::triangle);
    trace.force_opacity(forced_opacity::opaque);
    trace.accept_any_intersection(true);
    ray r;
    r.origin = origin;
    r.direction = dir;
    r.min_distance = 0.05;
    r.max_distance = maxDistance;
    intersector<instancing, triangle_data>::result_type hit;
    trace.intersect(r, tlas, hit);
    return (hit.distance < maxDistance - 0.001) ? 1.0 : 0.0;
}

/// Terrain fragment with ray-traced sun shadows. Identical to
/// terrain_fragment except the direct sun term is shadowed by the TLAS.
fragment float4 terrain_fragment_rt(MTVaryings in [[stage_in]],
                                    constant MTUniforms &uniforms [[buffer(1)]],
                                    instance_acceleration_structure tlas [[buffer(3)]]) {
    float3 p = in.worldPos * 0.35;
    float n = fract(sin(dot(floor(p.xz), float2(12.9898, 78.233))) * 43758.5453);
    float n2 = fract(sin(dot(floor(p.xz) + 1.0, float2(12.9898, 78.233))) * 43758.5453);
    float detail = mix(n, n2, 0.5) - 0.5;
    float3 varied = in.color * (1.0 + detail * 0.12);
    // Shadow ray toward the sun; offset along the normal to avoid self-hits.
    float3 sunDir = normalize(uniforms.lightDir.xyz);
    float shadow = rt_shadow_occlusion(tlas, in.worldPos + in.normal * 0.5,
                                       sunDir, 2000.0);
    float3 col = applyLighting(varied, in.normal, in.worldPos, in.material, uniforms);
    // Darken the sun-lit contribution when occluded (keep ambient).
    col *= (1.0 - shadow * 0.65);
    return float4(col, 1.0);
}
#endif // M3_FEATURES
