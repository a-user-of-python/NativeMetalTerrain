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
        float4 color;
    };
    struct CarUniforms {
        float4x4 viewProj;
        float4x4 model;
        float4 lightDir;   // xyz = sun direction, w = ambient
    };
    struct CarVaryings {
        float4 clipPos [[position]];
        float3 normal;
        float3 color;
    };

    vertex CarVaryings car_vertex(const device CarVertexIn *v [[buffer(0)]],
                                  constant CarUniforms &u [[buffer(1)]],
                                  uint vid [[vertex_id]]) {
        CarVaryings out;
        float4 world = u.model * float4(v[vid].position.xyz, 1.0);
        out.clipPos = u.viewProj * world;
        out.normal = (u.model * float4(v[vid].normal.xyz, 0.0)).xyz;
        out.color = v[vid].color.rgb;
        return out;
    }

    fragment float4 car_fragment(CarVaryings in [[stage_in]],
                                 constant CarUniforms &u [[buffer(1)]]) {
        float3 n = normalize(in.normal);
        float3 l = normalize(u.lightDir.xyz);
        float diff = max(dot(n, l), 0.0);
        float3 c = in.color * (u.lightDir.w + diff * 0.95);
        return float4(c, 1.0);
    }
    """

    /// Must match CarUniforms in the shader (144 bytes).
    private struct Uniforms {
        var viewProj: simd_float4x4
        var model: simd_float4x4
        var lightDir: SIMD4<Float>
    }

    // MARK: Mesh builder

    private struct MeshBuilder {
        var verts: [MTVertex] = []
        var indices: [UInt32] = []

        mutating func addBox(min mn: SIMD3<Float>, max mx: SIMD3<Float>,
                             color: SIMD3<Float>) {
            let c = [
                SIMD3<Float>(mn.x, mn.y, mn.z), SIMD3<Float>(mx.x, mn.y, mn.z),
                SIMD3<Float>(mx.x, mx.y, mn.z), SIMD3<Float>(mn.x, mx.y, mn.z),
                SIMD3<Float>(mn.x, mn.y, mx.z), SIMD3<Float>(mx.x, mn.y, mx.z),
                SIMD3<Float>(mx.x, mx.y, mx.z), SIMD3<Float>(mn.x, mx.y, mx.z),
            ]
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
                    verts.append(MTVertex(position: c[i], normal: n, color: color))
                }
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }

        /// Cylinder with its axle along X (wheel axle direction).
        mutating func addCylinderX(radius r: Float, halfWidth hw: Float,
                                   segments n: Int, center: SIMD3<Float>,
                                   color: SIMD3<Float>) {
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi
                let a1 = Float(i + 1) / Float(n) * 2 * .pi
                let n0 = SIMD3<Float>(0, cos(a0), sin(a0))
                let n1 = SIMD3<Float>(0, cos(a1), sin(a1))
                let base = UInt32(verts.count)
                verts.append(MTVertex(position: center + SIMD3<Float>(-hw, r * cos(a0), r * sin(a0)), normal: n0, color: color))
                verts.append(MTVertex(position: center + SIMD3<Float>(hw, r * cos(a0), r * sin(a0)), normal: n0, color: color))
                verts.append(MTVertex(position: center + SIMD3<Float>(hw, r * cos(a1), r * sin(a1)), normal: n1, color: color))
                verts.append(MTVertex(position: center + SIMD3<Float>(-hw, r * cos(a1), r * sin(a1)), normal: n1, color: color))
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
            // End caps (fans).
            for side: Float in [-1, 1] {
                let nx = SIMD3<Float>(side, 0, 0)
                let centerIdx = UInt32(verts.count)
                verts.append(MTVertex(position: center + SIMD3<Float>(side * hw, 0, 0),
                                       normal: nx, color: color))
                let ringStart = UInt32(verts.count)
                for i in 0...n {
                    let a = Float(i) / Float(n) * 2 * .pi
                    verts.append(MTVertex(
                        position: center + SIMD3<Float>(side * hw, r * cos(a), r * sin(a)),
                        normal: nx, color: color))
                }
                for i in 0..<n {
                    indices += [centerIdx, ringStart + UInt32(i), ringStart + UInt32(i + 1)]
                }
            }
        }
    }

    // MARK: State

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?

    private var bodyVB: MTLBuffer!
    private var bodyIB: MTLBuffer!
    private var bodyIndexCount = 0
    private var wheelVB: MTLBuffer!
    private var wheelIB: MTLBuffer!
    private var wheelIndexCount = 0

    /// Wheel offsets in car space (origin at ground under car center,
    /// forward = +Z). Front pair steers.
    static let wheelOffsets: [(offset: SIMD3<Float>, steers: Bool)] = [
        (SIMD3<Float>(-1.85, 1.0, 2.7), true),
        (SIMD3<Float>(1.85, 1.0, 2.7), true),
        (SIMD3<Float>(-1.85, 1.0, -2.7), false),
        (SIMD3<Float>(1.85, 1.0, -2.7), false),
    ]
    static let maxSteerAngle: Float = 0.5  // radians (~28 deg)

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.commandQueue = q
        buildMeshes()
        buildPipeline()
    }

    // MARK: Meshes

    private func buildMeshes() {
        // Body + cabin share one buffer (one draw call).
        var b = MeshBuilder()
        let red = SIMD3<Float>(0.78, 0.10, 0.10)
        let glass = SIMD3<Float>(0.07, 0.09, 0.14)
        let darkTrim = SIMD3<Float>(0.10, 0.10, 0.12)
        // Main body.
        b.addBox(min: SIMD3<Float>(-2.0, 1.3, -4.0),
                 max: SIMD3<Float>(2.0, 2.9, 4.0), color: red)
        // Cabin (tinted glass).
        b.addBox(min: SIMD3<Float>(-1.5, 2.9, -2.2),
                 max: SIMD3<Float>(1.5, 4.0, 0.8), color: glass)
        // Front/rear bumpers.
        b.addBox(min: SIMD3<Float>(-2.0, 1.0, 3.8),
                 max: SIMD3<Float>(2.0, 1.6, 4.2), color: darkTrim)
        b.addBox(min: SIMD3<Float>(-2.0, 1.0, -4.2),
                 max: SIMD3<Float>(2.0, 1.6, -3.8), color: darkTrim)
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
                       center: .zero, color: SIMD3<Float>(0.11, 0.11, 0.12))
        w.addCylinderX(radius: 0.45, halfWidth: 0.38, segments: 10,
                       center: .zero, color: SIMD3<Float>(0.55, 0.56, 0.60))
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

    /// Draws the car over the current frame. Call AFTER `renderer.draw(in:)`.
    /// - Parameters:
    ///   - viewProj: view-projection matrix matching the terrain pass.
    ///   - sunAzimuth/sunElevation: degrees, matching the renderer's sun.
    ///   - carModel: car world transform (slope-aligned).
    ///   - wheelSpin: wheel rotation about the axle (radians).
    ///   - steer: -1...1 steering input.
    func draw(in view: MTKView,
              viewProj: simd_float4x4,
              sunAzimuth: Float, sunElevation: Float,
              carModel: simd_float4x4,
              wheelSpin: Float, steer: Float) {
        guard let pipeline, let depthState,
              view.currentDrawable != nil else { return }
        // Preserve the terrain pass: load color + depth instead of clearing.
        // (Load actions must be set on the descriptor BEFORE the encoder
        // is created.)
        guard let pass = view.currentRenderPassDescriptor else { return }
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .store
        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(MTLCullMode.none)

        let az = sunAzimuth * .pi / 180
        let el = sunElevation * .pi / 180
        let sunDir = SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az))
        let light = SIMD4<Float>(normalize(sunDir), 0.38)

        // Body. (Uniforms go to BOTH stages: setVertexBytes is
        // vertex-only, so the fragment stage needs its own copy.)
        var bu = Uniforms(viewProj: viewProj, model: carModel, lightDir: light)
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
            var wu = Uniforms(viewProj: viewProj, model: m, lightDir: light)
            var wuf = wu
            enc.setVertexBytes(&wu, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&wuf, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: MTLPrimitiveType.triangle, indexCount: wheelIndexCount,
                                      indexType: MTLIndexType.uint32,
                                      indexBuffer: wheelIB, indexBufferOffset: 0)
        }

        enc.endEncoding()
        // No present: the library's command buffer already presented the
        // drawable; this buffer's writes land in the same texture first.
        cb.commit()
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
