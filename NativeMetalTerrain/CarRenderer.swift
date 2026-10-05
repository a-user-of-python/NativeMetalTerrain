import Metal
import MetalKit
import MetalTerrain
import simd

// MARK: - Debug car renderer (app-only)
//
// Procedural car (box body + cabin + 4 cylinder wheels), drawn in a second
// render pass right after the library's `draw(in:)`.
//
// Why a second pass: MTTerrainRenderer owns its render encoder privately —
// the app cannot inject draws into it. So the car gets its own command
// buffer on the same drawable, with color/depth LOAD actions (the terrain
// image and depth buffer are preserved, nothing is cleared). The car's
// command buffer is committed immediately after the library's, so in
// practice it executes after the terrain pass.
//
// The shader is compiled at runtime from an embedded source string, so no
// .metal file needs to be added to the Xcode target. Vertex layout reuses
// the library's public MTVertex (position/normal/color as float4s).

final class CarRenderer {

    // MARK: Shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CarVertexIn {
        float4 position;
        float4 normal;
        float4 color;    // rgb = base color, a = material id
    };
    struct CarUniforms {
        float4x4 viewProj;
        float4x4 model;
        float4 lightDir;   // xyz = sun direction, w = ambient
        float4 camPos;     // xyz = camera position (for reflections)
    };
    struct CarVaryings {
        float4 clipPos [[position]];
        float3 worldPos;
        float3 normal;
        float3 color;
        float material;
    };

    vertex CarVaryings car_vertex(const device CarVertexIn *v [[buffer(0)]],
                                  constant CarUniforms &u [[buffer(1)]],
                                  uint vid [[vertex_id]]) {
        CarVaryings out;
        float4 world = u.model * float4(v[vid].position.xyz, 1.0);
        out.clipPos = u.viewProj * world;
        out.worldPos = world.xyz;
        out.normal = (u.model * float4(v[vid].normal.xyz, 0.0)).xyz;
        out.color = v[vid].color.rgb;
        out.material = v[vid].color.a;
        return out;
    }

    // Material ids (in color.a): 0=matte metal paint, 1=glass, 2=trim/plastic,
    // 3=tire, 4=hubcap, 5=mirror (reflective)
    fragment float4 car_fragment(CarVaryings in [[stage_in]],
                                 constant CarUniforms &u [[buffer(1)]],
                                 texture2d<float> reflectionTex [[texture(0)]],
                                 sampler reflectionSampler [[sampler(0)]]) {
        float3 n = normalize(in.normal);
        float3 l = normalize(u.lightDir.xyz);
        float3 v = normalize(u.camPos.xyz - in.worldPos);
        float diff = max(dot(n, l), 0.0);
        float3 base = in.color;
        float mat = in.material;

        // Boosted ambient so the car is never pitch black.
        float amb = max(u.lightDir.w, 0.45);

        float3 col;
        if (mat < 0.5) {
            // Matte metal paint: moderate diffuse, broad soft specular
            // (high roughness), subtle fresnel sheen. No sharp highlights.
            float3 h = normalize(l + v);
            float spec = pow(max(dot(n, h), 0.0), 18.0) * 0.35;
            float fres = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.25;
            // Slight metallic tint in reflections
            float3 metalTint = mix(float3(1.0), base, 0.4);
            col = base * (amb + diff * 0.85) + (spec + fres) * metalTint;
        } else if (mat < 1.5) {
            // Glass: dark with strong fresnel
            float fres = pow(1.0 - max(dot(n, v), 0.0), 2.0);
            col = base * (0.4 + diff * 0.5) + fres * float3(0.6, 0.7, 0.8);
        } else if (mat < 4.5) {
            // Trim, tires, hubcaps: simple diffuse with good ambient
            col = base * (amb + diff * 1.0);
        } else {
            // Mirror: sample the live reflection texture.
            // The reflection was rendered from behind the car, so it shows
            // what's behind. Sample directly for a clear mirror image.
            float3 refl = reflectionTex.sample(reflectionSampler, float2(0.5, 0.5)).rgb;
            // Mirror glass: slightly darkened reflection with a hint of blue.
            col = refl * 0.88 + float3(0.02, 0.03, 0.04);
        }
        return float4(col, 1.0);
    }
    """

    /// Must match CarUniforms in the shader (160 bytes).
    private struct Uniforms {
        var viewProj: simd_float4x4
        var model: simd_float4x4
        var lightDir: SIMD4<Float>
        var camPos: SIMD4<Float>
    }

    // MARK: Mesh builder

    private struct MeshBuilder {
        var verts: [MTVertex] = []
        var indices: [UInt32] = []

        /// Adds a box. Material ids: 0=matte metal, 1=glass, 2=trim,
        /// 3=tire, 4=hubcap, 5=mirror (reflective).
        mutating func addBox(min mn: SIMD3<Float>, max mx: SIMD3<Float>,
                             color: SIMD3<Float>, material: Float = 0) {
            let c = [
                SIMD3<Float>(mn.x, mn.y, mn.z), SIMD3<Float>(mx.x, mn.y, mn.z),
                SIMD3<Float>(mx.x, mx.y, mn.z), SIMD3<Float>(mn.x, mx.y, mn.z),
                SIMD3<Float>(mn.x, mn.y, mx.z), SIMD3<Float>(mx.x, mn.y, mx.z),
                SIMD3<Float>(mx.x, mx.y, mx.z), SIMD3<Float>(mn.x, mx.y, mx.z),
            ]
            let col4 = SIMD4<Float>(color, material)
            // (corner indices, face normal). Cull mode is .none so winding
            // is irrelevant; normals are what matter for lighting.
            let faces: [([Int], SIMD3<Float>)] = [
                ([1, 5, 6, 2], SIMD3<Float>(1, 0, 0)),
                ([4, 0, 3, 7], SIMD3<Float>(-1, 0, 0)),
                ([3, 2, 6, 7], SIMD3<Float>(0, 1, 0)),
                ([4, 5, 1, 0], SIMD3<Float>(0, -1, 0)),
                ([5, 4, 7, 6], SIMD3<Float>(0, 0, 1)),
                ([0, 1, 2, 3], SIMD3<Float>(0, 0, -1)),
            ]
            for (corners, n) in faces {
                let base = UInt32(verts.count)
                for i in corners {
                    verts.append(MTVertex(position: c[i], normal: n, color: col4))
                }
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }

        /// Cylinder with its axle along X (wheel axle direction).
        mutating func addCylinderX(radius r: Float, halfWidth hw: Float,
                                   segments n: Int, center: SIMD3<Float>,
                                   color: SIMD3<Float>, material: Float = 3) {
            let col4 = SIMD4<Float>(color, material)
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi
                let a1 = Float(i + 1) / Float(n) * 2 * .pi
                let n0 = SIMD3<Float>(0, cos(a0), sin(a0))
                let n1 = SIMD3<Float>(0, cos(a1), sin(a1))
                let base = UInt32(verts.count)
                verts.append(MTVertex(position: center + SIMD3<Float>(-hw, r * cos(a0), r * sin(a0)), normal: n0, color: col4))
                verts.append(MTVertex(position: center + SIMD3<Float>(hw, r * cos(a0), r * sin(a0)), normal: n0, color: col4))
                verts.append(MTVertex(position: center + SIMD3<Float>(hw, r * cos(a1), r * sin(a1)), normal: n1, color: col4))
                verts.append(MTVertex(position: center + SIMD3<Float>(-hw, r * cos(a1), r * sin(a1)), normal: n1, color: col4))
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
            // End caps (fans).
            for side: Float in [-1, 1] {
                let nx = SIMD3<Float>(side, 0, 0)
                let centerIdx = UInt32(verts.count)
                verts.append(MTVertex(position: center + SIMD3<Float>(side * hw, 0, 0),
                                       normal: nx, color: col4))
                let ringStart = UInt32(verts.count)
                for i in 0...n {
                    let a = Float(i) / Float(n) * 2 * .pi
                    verts.append(MTVertex(
                        position: center + SIMD3<Float>(side * hw, r * cos(a), r * sin(a)),
                        normal: nx, color: col4))
                }
                for i in 0..<n {
                    indices += [centerIdx, ringStart + UInt32(i), ringStart + UInt32(i + 1)]
                }
            }
        }

        /// A flat quad facing +Z or -Z (for mirror glass). The mirror surface
        /// samples the live reflection texture in the fragment shader.
        mutating func addMirrorQuad(center: SIMD3<Float>, width w: Float, height h: Float,
                                    facing: Float) {
            // facing: +1 = +Z, -1 = -Z
            let n = SIMD3<Float>(0, 0, facing)
            let hw = w / 2, hh = h / 2
            let base = UInt32(verts.count)
            // Material 5 = mirror (reflective). Color is ignored for mirrors.
            let col = SIMD4<Float>(0.9, 0.95, 1.0, 5)
            verts.append(MTVertex(position: center + SIMD3<Float>(-hw, -hh, 0), normal: n, color: col))
            verts.append(MTVertex(position: center + SIMD3<Float>(hw, -hh, 0), normal: n, color: col))
            verts.append(MTVertex(position: center + SIMD3<Float>(hw, hh, 0), normal: n, color: col))
            verts.append(MTVertex(position: center + SIMD3<Float>(-hw, hh, 0), normal: n, color: col))
            if facing > 0 {
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            } else {
                indices += [base, base + 2, base + 1, base, base + 3, base + 2]
            }
        }
    }

    // MARK: State

    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var reflectionSampler: MTLSamplerState?
    private var fallbackReflectionTexture: MTLTexture?

    private var bodyVB: MTLBuffer!
    private var bodyIB: MTLBuffer!
    private var bodyIndexCount = 0
    private var wheelVB: MTLBuffer!
    private var wheelIB: MTLBuffer!
    private var wheelIndexCount = 0

    /// Wheel offsets in car space (origin at ground under car center,
    /// forward = +Z). Front pair steers. Scaled for the 1.25x body.
    static let wheelOffsets: [(offset: SIMD3<Float>, steers: Bool)] = [
        (SIMD3<Float>(-2.3, 1.25, 3.4), true),
        (SIMD3<Float>(2.3, 1.25, 3.4), true),
        (SIMD3<Float>(-2.3, 1.25, -3.4), false),
        (SIMD3<Float>(2.3, 1.25, -3.4), false),
    ]
    static let maxSteerAngle: Float = 0.5  // radians (~28 deg)

    init?(device: MTLDevice) {
        self.device = device
        buildMeshes()
        buildPipeline()
        buildReflectionResources()
    }

    private func buildReflectionResources() {
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .notMipmapped
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        reflectionSampler = device.makeSamplerState(descriptor: samplerDesc)

        // 1x1 sky-blue fallback for mirrors before the first reflection renders.
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        texDesc.usage = .shaderRead
        if let tex = device.makeTexture(descriptor: texDesc) {
            var pixel: UInt32 = 0xFF8A6B4A  // sky-ish blue (BGRA)
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &pixel, bytesPerRow: 4)
            fallbackReflectionTexture = tex
        }
    }

    // MARK: Meshes

    private func buildMeshes() {
        // Body + cabin + details share one buffer (one draw call).
        var b = MeshBuilder()
        let paint = SIMD3<Float>(0.62, 0.64, 0.70)  // brighter matte silver-blue
        let glass = SIMD3<Float>(0.07, 0.09, 0.14)
        let darkTrim = SIMD3<Float>(0.10, 0.10, 0.12)
        let handleMetal = SIMD3<Float>(0.75, 0.76, 0.80)
        // Main body (matte metal, material 0). Scaled 1.25x for visibility.
        let s: Float = 1.25
        b.addBox(min: SIMD3<Float>(-2.0 * s, 1.3 * s, -4.0 * s),
                 max: SIMD3<Float>(2.0 * s, 2.9 * s, 4.0 * s), color: paint, material: 0)
        // Cabin (tinted glass, material 1).
        b.addBox(min: SIMD3<Float>(-1.5 * s, 2.9 * s, -2.2 * s),
                 max: SIMD3<Float>(1.5 * s, 4.0 * s, 0.8 * s), color: glass, material: 1)
        // Front/rear bumpers (trim, material 2).
        b.addBox(min: SIMD3<Float>(-2.0 * s, 1.0 * s, 3.8 * s),
                 max: SIMD3<Float>(2.0 * s, 1.6 * s, 4.2 * s), color: darkTrim, material: 2)
        b.addBox(min: SIMD3<Float>(-2.0 * s, 1.0 * s, -4.2 * s),
                 max: SIMD3<Float>(2.0 * s, 1.6 * s, -3.8 * s), color: darkTrim, material: 2)
        // 3D door handles: small protruding boxes on both doors.
        for side: Float in [-1, 1] {
            let x0: Float = side > 0 ? 2.0 * s : -2.12 * s
            let x1: Float = side > 0 ? 2.12 * s : -2.0 * s
            b.addBox(min: SIMD3<Float>(min(x0, x1), 2.35 * s, -0.9 * s),
                     max: SIMD3<Float>(max(x0, x1), 2.55 * s, -0.1 * s),
                     color: handleMetal, material: 0.0)
        }
        // Side mirrors: stalk + housing + reflective glass.
        b.addBox(min: SIMD3<Float>(-2.35 * s, 3.1 * s, 0.55 * s),
                 max: SIMD3<Float>(-2.05 * s, 3.25 * s, 0.75 * s),
                 color: darkTrim, material: 2)
        b.addBox(min: SIMD3<Float>(-2.55 * s, 3.15 * s, 0.45 * s),
                 max: SIMD3<Float>(-2.35 * s, 3.65 * s, 0.95 * s),
                 color: paint, material: 0)
        b.addMirrorQuad(center: SIMD3<Float>(-2.45 * s, 3.4 * s, 0.70 * s),
                        width: 0.18 * s, height: 0.42 * s, facing: -1)
        b.addBox(min: SIMD3<Float>(2.05 * s, 3.1 * s, 0.55 * s),
                 max: SIMD3<Float>(2.35 * s, 3.25 * s, 0.75 * s),
                 color: darkTrim, material: 2)
        b.addBox(min: SIMD3<Float>(2.35 * s, 3.15 * s, 0.45 * s),
                 max: SIMD3<Float>(2.55 * s, 3.65 * s, 0.95 * s),
                 color: paint, material: 0)
        b.addMirrorQuad(center: SIMD3<Float>(2.45 * s, 3.4 * s, 0.70 * s),
                        width: 0.18 * s, height: 0.42 * s, facing: -1)
        bodyVB = device.makeBuffer(bytes: b.verts,
                                   length: b.verts.count * MemoryLayout<MTVertex>.stride,
                                   options: .storageModeShared)
        bodyIB = device.makeBuffer(bytes: b.indices,
                                   length: b.indices.count * MemoryLayout<UInt32>.stride,
                                   options: .storageModeShared)
        bodyIndexCount = b.indices.count

        // One wheel mesh, instanced 4x with per-wheel transforms.
        var w = MeshBuilder()
        w.addCylinderX(radius: 1.0, halfWidth: 0.35, segments: 14,
                       center: .zero, color: SIMD3<Float>(0.11, 0.11, 0.12), material: 3)
        w.addCylinderX(radius: 0.45, halfWidth: 0.38, segments: 10,
                       center: .zero, color: SIMD3<Float>(0.55, 0.56, 0.60), material: 4)
        wheelVB = device.makeBuffer(bytes: w.verts,
                                    length: w.verts.count * MemoryLayout<MTVertex>.stride,
                                    options: .storageModeShared)
        wheelIB = device.makeBuffer(bytes: w.indices,
                                    length: w.indices.count * MemoryLayout<UInt32>.stride,
                                    options: .storageModeShared)
        wheelIndexCount = w.indices.count
    }

    // MARK: Pipeline

    private func buildPipeline() {
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let v = lib.makeFunction(name: "car_vertex"),
                  let f = lib.makeFunction(name: "car_fragment") else { return }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = v
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            pipeline = try device.makeRenderPipelineState(descriptor: d)
            let dd = MTLDepthStencilDescriptor()
            dd.depthCompareFunction = .less
            dd.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: dd)
        } catch {
            // Pipeline stays nil; the car simply won't draw.
        }
    }

    // MARK: Draw

    /// Draws the car into an existing render encoder (called from the
    /// library's draw overlay closure). This avoids the synchronization
    /// issues of a second render pass — the car draws in the SAME encoder
    /// as the terrain, right after it.
    /// - Parameters:
    ///   - encoder: The active render encoder (from the library's draw).
    ///   - viewProj: view-projection matrix matching the terrain pass.
    ///   - cameraPos: camera world position (for specular/reflections).
    ///   - sunAzimuth/sunElevation: degrees, matching the renderer's sun.
    ///   - carModel: car world transform (slope-aligned).
    ///   - wheelSpin: wheel rotation about the axle (radians).
    ///   - steer: -1...1 steering input.
    ///   - reflectionTex: live scene reflection for the mirrors.
    func draw(encoder enc: MTLRenderCommandEncoder,
              viewProj: simd_float4x4,
              cameraPos: SIMD3<Float>,
              sunAzimuth: Float, sunElevation: Float,
              carModel: simd_float4x4,
              wheelSpin: Float, steer: Float,
              reflectionTex: MTLTexture? = nil) {
        guard let pipeline, let depthState else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(MTLCullMode.none)

        // Bind the reflection texture for the mirrors (or a 1x1 fallback).
        if let reflectionTex {
            enc.setFragmentTexture(reflectionTex, index: 0)
        } else if let fallback = fallbackReflectionTexture {
            enc.setFragmentTexture(fallback, index: 0)
        }
        enc.setFragmentSamplerState(reflectionSampler, index: 0)

        let az = sunAzimuth * .pi / 180
        let el = sunElevation * .pi / 180
        let sunDir = SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az))
        let light = SIMD4<Float>(normalize(sunDir), 0.38)
        let cam = SIMD4<Float>(cameraPos, 1)

        // Body. (Uniforms go to BOTH stages: setVertexBytes is
        // vertex-only, so the fragment stage needs its own copy.)
        var bu = Uniforms(viewProj: viewProj, model: carModel, lightDir: light, camPos: cam)
        var buf = bu
        enc.setVertexBuffer(bodyVB, offset: 0, index: 0)
        enc.setVertexBytes(&bu, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&buf, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: MTLPrimitiveType.triangle, indexCount: bodyIndexCount,
                                  indexType: MTLIndexType.uint32,
                                  indexBuffer: bodyIB, indexBufferOffset: 0)

        // Wheels: car transform * offset * steer * spin.
        enc.setVertexBuffer(wheelVB, offset: 0, index: 0)
        for (offset, steers) in Self.wheelOffsets {
            var m = carModel
            m *= Self.translation(offset)
            if steers { m *= Self.rotationY(steer * Self.maxSteerAngle) }
            m *= Self.rotationX(wheelSpin)
            var wu = Uniforms(viewProj: viewProj, model: m, lightDir: light, camPos: cam)
            var wuf = wu
            enc.setVertexBytes(&wu, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&wuf, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: MTLPrimitiveType.triangle, indexCount: wheelIndexCount,
                                      indexType: MTLIndexType.uint32,
                                      indexBuffer: wheelIB, indexBufferOffset: 0)
        }
        // Note: do NOT end encoding or commit — the library owns the encoder
        // lifecycle. Our draws are part of the same render pass.
    }

    // MARK: Small matrix helpers

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.1 = SIMD4<Float>(0, c, s, 0)
        m.columns.2 = SIMD4<Float>(0, -s, c, 0)
        return m
    }

    static func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(c, 0, -s, 0)
        m.columns.2 = SIMD4<Float>(s, 0, c, 0)
        return m
    }
}
