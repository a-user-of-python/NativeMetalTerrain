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
    float4 skyParams;           // x = sun elevation (radians), y = time (seconds),
                                // z = cloud amount (0...1), w = stars enabled (0/1)
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

    float t = sqrt(clamp(viewDir.y, 0.0, 1.0));
    float3 col = mix(horizon, zenith, t);
    // Below the horizon: darken toward ground haze. The terrain and water
    // normally cover this region; this only shows at grazing angles.
    col = mix(col, horizon * 0.25, clamp(-viewDir.y * 4.0, 0.0, 1.0));
    return col;
}

// Hash and 2D value noise for procedural clouds. Metal 3 compatible.
float sky_hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float sky_vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(sky_hash12(i), sky_hash12(i + float2(1.0, 0.0)), u.x),
               mix(sky_hash12(i + float2(0.0, 1.0)), sky_hash12(i + float2(1.0, 1.0)), u.x),
               u.y);
}

fragment float4 sky_fragment(MTSkyVaryings in [[stage_in]],
                             constant MTSkyUniforms &uniforms [[buffer(0)]]) {
    float3 viewDir = normalize(in.viewDir);
    float3 sunDir = normalize(uniforms.sunDir.xyz);
    float elev = uniforms.skyParams.x;  // radians
    float time = uniforms.skyParams.y;  // seconds
    float cloudAmt = clamp(uniforms.skyParams.z, 0.0, 1.0);
    float starsOn = uniforms.skyParams.w;

    float3 col = skyColor(viewDir, elev);
    float dayAmt = smoothstep(-0.05, 0.30, elev);

    // ── Clouds (before sun, so the sun disc draws over them) ──
    // Procedural 2-octave value noise on a planar projection of viewDir.
    // Only above the horizon; coverage from cloudAmt (0 = clear, 1 = overcast).
    // Tinted by time of day: white at day, orange at dusk, dark at night.
    if (cloudAmt > 0.001 && viewDir.y > 0.0) {
        // Planar projection: divide xz by y for a stable sky dome mapping.
        // The 0.12 floor avoids extreme stretching near the horizon.
        float2 cuv = viewDir.xz / max(viewDir.y, 0.12);
        // Slow drift with time for a living sky.
        float2 drift = float2(time * 0.008, time * 0.005);
        float c = sky_vnoise(cuv * 1.6 + drift) * 0.65
                + sky_vnoise(cuv * 3.4 - drift * 0.7) * 0.35;
        // Coverage: remap noise so cloudAmt controls how much of the sky
        // is covered. Soft edges for a natural look.
        float cover = smoothstep(1.0 - cloudAmt, 1.0 - cloudAmt + 0.45, c);
        // Fade clouds near the horizon to avoid a hard band.
        float horizFade = smoothstep(0.0, 0.18, viewDir.y);
        // Cloud tint follows the sun: white at noon, orange at dusk, dark at night.
        float duskAmt = clamp(1.0 - fabs(elev + 0.02) / 0.22, 0.0, 1.0) * (1.0 - dayAmt);
        float3 dayCloud   = float3(0.98, 0.99, 1.00);
        float3 duskCloud  = float3(1.00, 0.55, 0.30);
        float3 nightCloud = float3(0.04, 0.05, 0.09);
        float3 cloudCol = mix(nightCloud, dayCloud, dayAmt);
        cloudCol = mix(cloudCol, duskCloud, duskAmt * 0.85);
        // Soft alpha blend: clouds are semi-transparent, more opaque at center.
        float alpha = cover * horizFade * 0.85;
        col = mix(col, cloudCol, alpha);
    }

    // Sun disc + glow. The disc is ~1.5-2 degrees across (cos thresholds
    // 0.9992..0.9997) so it stays clearly visible; the glow halo softens it.
    // Both fade out as the sun drops below the horizon (night = no sun).
    float cosA = dot(viewDir, sunDir);
    float sunVis = smoothstep(-0.06, 0.02, elev);
    float disc = smoothstep(0.9992, 0.9997, cosA) * sunVis;
    // v1.1.0: early-out — pow() only matters near the sun disc.
    float glow = 0.0;
    if (cosA > 0.7) {
        glow = (pow(max(cosA, 0.0), 350.0) * 0.6
              + pow(max(cosA, 0.0),  24.0) * 0.18) * sunVis;
    }

    // Sun tint follows the sky: white at noon, orange at sunset.
    float3 sunTint = mix(float3(1.0, 0.45, 0.15), float3(1.0, 0.97, 0.90), dayAmt);

    col += disc * sunTint * 3.0 + glow * sunTint;

    // ── Stars (after sun, so they draw over everything except terrain) ──
    // Only visible at night, fading in as the sun drops below the horizon.
    // Procedural star field: hash the view direction into cells, place a
    // star in ~0.3% of cells with varying brightness and subtle twinkle.
    // Stars are fixed to view direction (at infinity) and fade near the horizon.
    float nightAmt = 1.0 - smoothstep(-0.12, 0.02, elev);
    if (nightAmt > 0.003 && starsOn > 0.5 && viewDir.y > 0.0) {
        float3 sd = viewDir * 300.0;
        float3 cell = floor(sd);
        float h = fract(sin(dot(cell, float3(12.9898, 78.233, 37.719))) * 43758.5453);
        if (h > 0.995) {
            // Star position within its cell; distance from center = size.
            float3 f = fract(sd) - 0.5;
            float d = length(f);
            // Twinkle: subtle brightness oscillation, different phase/speed per star.
            float tw = 0.65 + 0.35 * sin(time * (1.5 + h * 5.0) + h * 61.7);
            // Brighter stars (higher h) are slightly larger. v1.1.2: bigger.
            float size = 0.09 + (h - 0.995) * 14.0;
            float bright = smoothstep(size, 0.0, d) * tw;
            // Vary star color slightly: blue-white to warm white.
            float3 starCol = mix(float3(0.75, 0.85, 1.0), float3(1.0, 0.95, 0.85), fract(h * 7.31));
            // Fade near the horizon and scale by night amount.
            float horizonFade = smoothstep(0.02, 0.20, viewDir.y);
            col += starCol * bright * nightAmt * horizonFade * 1.2;
        }
    }

    return float4(col, 1.0);
}
