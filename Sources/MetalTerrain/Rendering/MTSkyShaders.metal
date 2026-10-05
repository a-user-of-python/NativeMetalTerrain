// MTSkyShaders.metal — Skybox shaders for the MetalTerrain library.
//
// Renders the sky as a FULLSCREEN TRIANGLE (3 vertices, no vertex buffers):
// a vertical zenith→horizon gradient tinted by sun elevation
// (day blue / low-sun sunset orange / below-horizon night), plus a bright
// sun disc with a soft glow halo at the sun direction.
//
// Metal 3 baseline (no Metal 4-only shading-language features); the same
// source compiles through both the device pipeline path and the Metal 4
// compiler path used by MTTerrainRenderer.

#include <metal_stdlib>
using namespace metal;

// Must match the private MTSkyUniforms struct in MTSkybox.swift (112 bytes).
// All fields are float4-packed: Swift's SIMD3<Float> is 16-byte aligned
// (unlike Metal's 12-byte float3), so float3 fields would desync the layout.
struct MTSkyUniforms {
    float4x4 viewProjInverse;  // inverse of the camera view-projection matrix
    float4 cameraPos;           // xyz = world-space camera position
    float4 sunDir;              // xyz = direction from the scene TOWARD the sun
    float4 skyParams;           // x = sun elevation, radians
};

struct MTSkyVaryings {
    float4 clipPos [[position]];
    float3 viewDir;  // world-space direction from the camera through the pixel
};

// Fullscreen triangle from vertex_id alone — no buffers needed.
// The triangle sits exactly at the far plane (clip z = 1, i.e. NDC depth 1),
// so with the .lessEqual depth state from MTSkybox it passes on a freshly
// cleared depth buffer (cleared to 1.0) while writing nothing back.
vertex MTSkyVaryings sky_vertex(uint vid [[vertex_id]],
                                constant MTSkyUniforms &uniforms [[buffer(0)]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0),
    };
    float2 p = positions[vid];
    float4 clip = float4(p, 1.0, 1.0);  // far plane
    // Unproject the far-plane point to world space; the view direction is
    // that point minus the camera position. Interpolating viewDir across the
    // triangle is exact here because it is an affine function of clip coords.
    float4 world = uniforms.viewProjInverse * clip;
    world /= world.w;
    MTSkyVaryings out;
    out.clipPos = clip;
    out.viewDir = world.xyz - uniforms.cameraPos.xyz;
    return out;
}

// Vertical sky gradient. sunElevation is in radians:
//   well above 0  -> day blue
//   near 0        -> sunset orange near the horizon
//   below ~-0.06  -> dark night gradient
float3 skyColor(float3 viewDir, float sunElevation) {
    float dayAmt = smoothstep(-0.05, 0.30, sunElevation);
    // Dusk peaks at/below the horizon and fades out once the sun is up.
    float duskAmt = clamp(1.0 - fabs(sunElevation + 0.02) / 0.22, 0.0, 1.0);
    duskAmt *= (1.0 - dayAmt);

    float3 dayZenith   = float3(0.12, 0.36, 0.86);
    float3 dayHorizon  = float3(0.62, 0.80, 0.94);
    float3 duskZenith  = float3(0.16, 0.14, 0.38);
    float3 duskHorizon = float3(1.00, 0.48, 0.20);
    float3 nightZenith = float3(0.008, 0.012, 0.045);
    float3 nightHorizon= float3(0.030, 0.050, 0.105);

    float3 zenith  = mix(nightZenith,  dayZenith,  dayAmt);
    zenith  = mix(zenith,  duskZenith,  duskAmt);
    float3 horizon = mix(nightHorizon, dayHorizon, dayAmt);
    horizon = mix(horizon, duskHorizon, duskAmt);

    float t = pow(clamp(viewDir.y, 0.0, 1.0), 0.55);
    float3 col = mix(horizon, zenith, t);
    // Below the horizon: darken toward ground haze. The terrain and water
    // normally cover this region; this only shows at grazing angles.
    col = mix(col, horizon * 0.25, clamp(-viewDir.y * 4.0, 0.0, 1.0));
    return col;
}

fragment float4 sky_fragment(MTSkyVaryings in [[stage_in]],
                             constant MTSkyUniforms &uniforms [[buffer(0)]]) {
    float3 viewDir = normalize(in.viewDir);
    float3 sunDir = normalize(uniforms.sunDir.xyz);
    float elev = uniforms.skyParams.x;  // radians

    float3 col = skyColor(viewDir, elev);

    // Sun disc + glow. The disc is ~1.5-2 degrees across (cos thresholds
    // 0.9992..0.9997) so it stays clearly visible; the glow halo softens it.
    // Both fade out as the sun drops below the horizon (night = no sun).
    float cosA = dot(viewDir, sunDir);
    float sunVis = smoothstep(-0.06, 0.02, elev);
    float disc = smoothstep(0.9992, 0.9997, cosA) * sunVis;
    float glow = (pow(max(cosA, 0.0), 350.0) * 0.6
                + pow(max(cosA, 0.0),  24.0) * 0.18) * sunVis;

    // Sun tint follows the sky: white at noon, orange at sunset.
    float dayAmt = smoothstep(-0.05, 0.30, elev);
    float3 sunTint = mix(float3(1.0, 0.45, 0.15), float3(1.0, 0.97, 0.90), dayAmt);

    col += disc * sunTint * 3.0 + glow * sunTint;
    return float4(col, 1.0);
}
