// MTMeshCompute.swift
// MetalTerrain — GPU terrain mesh building via a Metal compute kernel.
//
// v1.2.6: ports MTMeshBuilder.buildGrid (stride 1) + appendSkirtVertices
// to MSL (Sources/MetalTerrain/Shaders/MTMeshCompute.metal) so chunk
// meshes build fully on the GPU: padded heightmap -> packed vertices,
// no CPU roundtrip. The shared index buffers are untouched (topology
// is identical; indices stay cached by grid size).
//
// Every failure mode returns nil — callers fall back to the CPU path.

import Metal
import Foundation
import simd

/// Parameter block for `mtMeshKernel`.
/// Layout must match `MeshParams` in MTMeshCompute.metal exactly:
/// 7 floats + 2 uints = 36 bytes.
private struct MeshParams {
    var x0: Float
    var z0: Float
    var step: Float
    var heightScale: Float
    var cell: Float
    var skirtDepth: Float
    var pad0: Float
    var res: UInt32
    var biomeCount: UInt32
}

/// One biome slot for the kernel.
/// Layout must match `GPUBiome` in MTMeshCompute.metal exactly:
/// 2 floats, 2 float4s, 2 floats, 1 float2 = 64 bytes, 16-aligned.
private struct GPUBiomeParams {
    var minHeight: Float
    var maxHeight: Float
    var groundColor: SIMD4<Float>  // linear rgb in xyz
    var slopeColor: SIMD4<Float>   // linear rgb in xyz, w = 1 if present
    var materialID: Float
    var emitsLight: Float          // 1 or 0
    var pad: SIMD2<Float>
}

/// GPU mesh builder. Internal: owned by the renderer alongside
/// `MTHeightmapCompute`, which it reuses for the padded heightmap.
final class MTMeshCompute {
    /// Maximum biome slots the kernel accepts.
    private static let maxBiomes = 16

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue
    private let heightmap: MTHeightmapCompute

    /// Returns nil when the kernel is unavailable — the caller then
    /// uses the CPU mesh path.
    init?(device: MTLDevice, heightmap: MTHeightmapCompute) {
        self.device = device
        self.heightmap = heightmap
        guard let library = try? device.makeDefaultLibrary(bundle: .module),
              let function = library.makeFunction(name: "mtMeshKernel"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.pipeline = pipeline
        self.commandQueue = queue
    }

    /// Builds a chunk mesh fully on the GPU.
    ///
    /// - Parameters:
    ///   - coord: chunk coordinate.
    ///   - res: vertices per side (stride is always 1 on the GPU path).
    ///   - world: supplies config, biomes, seed, and noise tables.
    /// - Returns: vertex buffer (packed 20-byte vertices, ready to render),
    ///   grid size `n`, min/max normalized heights (for the AABB), and the
    ///   unpadded heights (for the M3 mesh-shading path) — or nil on any
    ///   GPU failure so the caller falls back to `MTMeshBuilder`.
    func buildMesh(coord: MTChunkCoord, res: Int,
                   world: MTTerrainWorld)
        -> (vertexBuffer: MTLBuffer, gridN: Int,
            minHeight: Float, maxHeight: Float, heights: [UInt16])? {
        guard res >= 2 else { return nil }
        let biomes = world.allBiomes
        guard !biomes.isEmpty, biomes.count <= Self.maxBiomes else { return nil }

        let cfg = world.config
        let size = cfg.chunkWorldSize
        let heightScale = cfg.heightScale
        let x0 = Double(coord.x) * Double(size)
        let z0 = Double(coord.z) * Double(size)
        let step = Double(size) / Double(res - 1)

        let (noise, warpNoise) = world.noisePair()
        let field = MTHeightFieldConfig(base: cfg.noise,
                                        continentScale: cfg.continentScale,
                                        riverScale: cfg.riverScale,
                                        mountainSharpness: cfg.mountainSharpness)

        // Padded heightmap: one extra cell on every side so border
        // vertices sample true neighbors (replaces the CPU path's
        // mtHeightSampleField border calls with identical math).
        let pres = res + 2
        guard let heightsBuf = heightmap.generateHeightsBuffer(
                x0: x0 - step, z0: z0 - step, step: step, res: pres,
                field: field, seed: world.seed,
                noise: noise, warpNoise: warpNoise) else {
            return nil
        }

        // Biome table for the kernel.
        var gpuBiomes = [GPUBiomeParams]()
        gpuBiomes.reserveCapacity(biomes.count)
        for b in biomes {
            let sc = b.slopeColor ?? SIMD3<Float>(0, 0, 0)
            gpuBiomes.append(GPUBiomeParams(
                minHeight: b.minHeight,
                maxHeight: b.maxHeight,
                groundColor: SIMD4<Float>(b.groundColor, 1),
                slopeColor: SIMD4<Float>(sc, b.slopeColor == nil ? 0 : 1),
                materialID: b.materialID,
                emitsLight: b.emitsLight ? 1 : 0,
                pad: SIMD2<Float>(0, 0)))
        }
        guard let biomeBuffer = gpuBiomes.withUnsafeBytes({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!,
                              length: ptr.count,
                              options: .storageModeShared)
        }) else { return nil }

        var params = MeshParams(
            x0: Float(x0), z0: Float(z0), step: Float(step),
            heightScale: heightScale,
            cell: Float(step),
            skirtDepth: heightScale * 0.35 + 10,
            pad0: 0,
            res: UInt32(res),
            biomeCount: UInt32(biomes.count))

        // Main vertices + skirt vertices, 20 bytes each.
        let totalVerts = res * res + 4 * res - 4
        let outLength = totalVerts * 20
        guard let paramBuffer = device.makeBuffer(
                    bytes: &params,
                    length: MemoryLayout<MeshParams>.stride,
                    options: .storageModeShared),
              let outBuffer = device.makeBuffer(length: outLength,
                                                options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(paramBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightsBuf, offset: 0, index: 1)
        encoder.setBuffer(biomeBuffer, offset: 0, index: 2)
        encoder.setBuffer(outBuffer, offset: 0, index: 3)

        let tpt = 256
        let groups = MTLSize(width: (totalVerts + tpt - 1) / tpt,
                             height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups,
                                     threadsPerThreadgroup: MTLSize(width: tpt, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous: buildChunkAsync already runs on a background queue.
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        // Min/max + unpadded heights for the AABB and the M3 path.
        // The padded buffer is .storageModeShared: a plain CPU pass.
        let hptr = heightsBuf.contents().assumingMemoryBound(to: UInt16.self)
        var heights = [UInt16](repeating: 0, count: res * res)
        var minH: Float = .greatestFiniteMagnitude
        var maxH: Float = -.greatestFiniteMagnitude
        heights.withUnsafeMutableBufferPointer { hbuf in
            for j in 0..<res {
                for i in 0..<res {
                    let q = hptr[(j + 1) * pres + (i + 1)]
                    hbuf[j * res + i] = q
                    let h = Float(q) / 65535.0
                    if h < minH { minH = h }
                    if h > maxH { maxH = h }
                }
            }
        }
        return (outBuffer, res, minH, maxH, heights)
    }
}
