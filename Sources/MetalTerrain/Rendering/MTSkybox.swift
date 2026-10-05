// MTSkybox.swift — Skybox for the MetalTerrain library.
//
// Renders a sky gradient plus a visible, movable sun as a fullscreen
// triangle (3 vertices, no buffers) drawn first, before the terrain.
// Works on all devices (standard Metal 3 — not M3/Apple-Silicon gated).
//
// Integration (MTTerrainRenderer): create one in init, then in draw(in:)
// encode it FIRST into the render encoder before setting the terrain's
// depth state / fill mode:
//
//     if let skybox = skybox {
//         skybox.sunAzimuth = self.sunAzimuth
//         skybox.sunElevation = self.sunElevation
//         skybox.draw(encoder: renderEncoder, viewProjection: viewProj)
//     }
//
// The skybox sets its own pipeline, depth-stencil, and cull state on the
// encoder; the caller re-sets the terrain state afterward as usual.

import Foundation
import Metal
import simd

/// Must match `MTSkyUniforms` in MTSkyShaders.metal (112 bytes).
/// All 16-byte aligned: float4x4 (64) + 3x float4 (48).
private struct MTSkyUniforms {
    var viewProjInverse: simd_float4x4
    var cameraPos: SIMD4<Float>  // xyz = world-space camera position
    var sunDir: SIMD4<Float>     // xyz = direction TOWARD the sun
    var skyParams: SIMD4<Float>  // x = sun elevation, radians
}

/// A skybox: sky gradient + visible movable sun, rendered as one
/// fullscreen triangle. Drawn first each frame; terrain, structures, and
/// water are drawn over it with their normal depth testing.
///
/// The sun's rendered position uses the same azimuth/elevation → direction
/// mapping as the terrain lighting, so the visible sun disc always agrees
/// with the light direction shading the terrain.
public final class MTSkybox {

    /// Sun azimuth in degrees, 0-360. Same convention as the terrain
    /// lighting: 0° points along +Z, 90° along +X.
    public var sunAzimuth: Float = 45
    /// Sun elevation in degrees. Positive = above the horizon (day),
    /// near 0 = sunset/sunrise tint, negative = night (sun hidden).
    public var sunElevation: Float = 50

    /// Compiles the sky pipeline from the default Metal library. The
    /// `.metal` file lives in the same target, so
    /// `makeDefaultLibrary(bundle: .module)` finds `sky_vertex` /
    /// `sky_fragment` (same pattern as MTTerrainRenderer's pipelines).
    ///
    /// - Parameter device: The Metal device used to build the pipeline.
    public init(device: MTLDevice) {
        let library: MTLLibrary
        do {
            // Newer SDKs: makeDefaultLibrary(bundle:) throws and returns
            // non-optional.
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            preconditionFailure("MTSkybox: default Metal library not found in bundle (.module). " +
                                "MTSkyShaders.metal must be part of the MetalTerrain target: \(error)")
        }
        guard let vertex = library.makeFunction(name: "sky_vertex"),
              let fragment = library.makeFunction(name: "sky_fragment") else {
            preconditionFailure("MTSkybox: missing shader function sky_vertex/sky_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // Match the renderer's framebuffer formats.
        descriptor.colorAttachments[0]?.pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            preconditionFailure("MTSkybox: pipeline creation failed: \(error)")
        }

        // Depth state for the sky triangle, drawn FIRST:
        // - compare .lessEqual: the triangle is at the far plane (NDC depth
        //   exactly 1.0), so it passes on a cleared depth buffer (cleared to
        //   1.0, the MTKView default). (.always would also pass since the sky
        //   is drawn first, but .lessEqual is the conservative choice: if a
        //   future caller ever draws something before the sky that wrote
        //   depth, the sky still behaves sanely.)
        // - depthWriteEnabled = false: the sky leaves the depth buffer
        //   untouched, so terrain/structures/water drawn afterward test with
        //   their normal .less depth states and occlude the sky correctly.
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = false
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            preconditionFailure("MTSkybox: depth stencil state creation failed")
        }
        depthState = depth
    }

    /// Direction from the scene TOWARD the sun (unit vector), from the
    /// azimuth/elevation properties. This is the exact mapping the terrain
    /// shader lighting uses for `lightDir` (see MTTerrainRenderer
    /// `writeUniforms`), so the rendered sun disc matches the lighting.
    private func sunDirection() -> SIMD3<Float> {
        let az = sunAzimuth * .pi / 180
        let el = sunElevation * .pi / 180
        return normalize(SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az)))
    }

    /// Encodes the skybox into `encoder`: the fullscreen sky triangle with
    /// the sun, drawn at the far plane with no depth writes. Call this FIRST
    /// in the frame, before the terrain draws (the caller's own depth state
    /// and fill mode are re-set by the terrain pass afterward).
    ///
    /// - Parameters:
    ///   - encoder: The frame's render command encoder (created by the caller).
    ///   - viewProjection: The camera view-projection matrix for this frame
    ///     (the renderer's `viewProj`).
    public func draw(encoder: MTLRenderCommandEncoder,
                     viewProjection: matrix_float4x4) {
        let inv = viewProjection.inverse
        // Recover the world-space camera position from the inverse
        // view-projection: the camera sits at the projection origin.
        let c4 = inv * SIMD4<Float>(0, 0, 0, 1)
        let camPos = SIMD3<Float>(c4.x, c4.y, c4.z) / c4.w

        var uniforms = MTSkyUniforms(
            viewProjInverse: inv,
            cameraPos: SIMD4<Float>(camPos, 1),
            sunDir: SIMD4<Float>(sunDirection(), 0),
            skyParams: SIMD4<Float>(sunElevation * .pi / 180, 0, 0, 0))

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        // Fullscreen triangle: cull nothing so winding can't hide it; fill
        // mode stays whatever the encoder had (the caller re-sets wireframe
        // mode for terrain afterward, so the sky is always solid).
        encoder.setCullMode(.none)
        let stride = MemoryLayout<MTSkyUniforms>.stride
        encoder.setVertexBytes(&uniforms, length: stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
}
