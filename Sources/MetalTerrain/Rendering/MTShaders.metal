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

// Must match MTUniforms in MTTerrainRenderer.swift (192 bytes).
// Uses float4 packing on both sides: Swift's SIMD3<Float> is 16-byte
// aligned (unlike Metal's 12-byte float3), so float3 fields would desync
// the layout. Pack small fields into float4s instead.
struct MTUniforms {
    float4x4 viewProj;
    float4x4 model;
    float4 cameraPos;   // xyz = camera position
    float4 fogColor;    // rgb = fog color, w = fog density
    float4 lightDir;    // xyz = light direction, w = ambient strength
    float4 misc;        // x = time seconds, y = shader effects (0/1)
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

// Shared vertex transform: model matrix, then view-projection.
vertex MTVaryings terrain_vertex(const device MTVertexIn *vertices [[buffer(0)]],
                                 constant MTUniforms &uniforms [[buffer(1)]],
                                 uint vid [[vertex_id]]) {
    MTVertexIn v = vertices[vid];
    float4 world = uniforms.model * float4(v.position.xyz, 1.0);
    MTVaryings out;
    out.clipPos = uniforms.viewProj * world;
    out.worldPos = world.xyz;
    out.normal = (uniforms.model * float4(v.normal.xyz, 0.0)).xyz;
    out.color = v.color.rgb;
    out.material = v.color.a;
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

    float3 lit = albedo * (amb + wrapNdl * (1.0 - amb));
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
    float3 col = applyLighting(varied, in.normal, in.worldPos, in.material, uniforms);
    return float4(col, 1.0);
}

// Water reuses terrain_vertex; adds alpha and a subtle animated ripple.
fragment float4 water_fragment(MTVaryings in [[stage_in]],
                               constant MTUniforms &uniforms [[buffer(1)]],
                               constant float &alpha [[buffer(2)]]) {
    float t = uniforms.misc.x;
    float3 ripple = float3(0.03 * sin(t * 1.7 + in.worldPos.x * 0.35),
                           0.0,
                           0.03 * cos(t * 1.3 + in.worldPos.z * 0.31));
    float3 n = normalize(in.normal + ripple);
    float3 col = applyLighting(in.color, n, in.worldPos, 5.0, uniforms);  // water
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
