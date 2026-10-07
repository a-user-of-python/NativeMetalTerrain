// MTHeightmapCompute.swift
// MetalTerrain — GPU heightmap generation via a Metal compute kernel.
//
// v1.2.5: ports the MTNoise.swift height pipeline to MSL
// (Sources/MetalTerrain/Shaders/MTHeightmapCompute.metal) so chunk
// heightfields build on the GPU instead of the CPU.
//
// The permutation tables are built on CPU with the same MTSeededRandom
// Fisher-Yates shuffle and uploaded as buffers, and the kernel replicates
// the Swift math (double precision, LUT mountain rounding, UInt16
// quantization), so GPU heights match the CPU path.
//
// Every failure mode returns nil — callers fall back to the CPU path.

import Metal
import Foundation

/// Parameter block for `mtHeightmapKernel`.
/// Layout must match `HeightmapParams` in MTHeightmapCompute.metal exactly:
/// 13 floats followed by 9 uints.
private struct HeightmapParams {
    var x0: Float
    var z0: Float
    var step: Float
    var baseFreq: Float
    var lacunarity: Float
    var gain: Float
    var baseAmplitude: Float
    var warpStrength: Float
    var warpScale: Float
    var continentFreq: Float
    var mtnFreq: Float
    var riverFreq: Float
    var mountainSharpness: Float
    var res: UInt32
    var baseOctaves: UInt32
    var continentOctaves: UInt32
    var warpOctaves: UInt32
    var rangeOctaves: UInt32
    var riverOctaves: UInt32
    var baseRidged: UInt32
    var doWarp: UInt32
    var ventCount: UInt32  // v1.3.0
}

/// GPU vent layout. Must match `MTVolcanoVentGPU` in MTHeightmapCompute.metal
/// (float2 + float + float + float = 20 bytes).
private struct MTVolcanoVentGPU {
    var pos: SIMD2<Float>
    var radius: Float
    var depth: Float
    var peakHeight: Float
}

/// GPU heightmap generator. Internal: owned by the renderer, handed to
/// `MTTerrainWorld` so `generateChunk` can try the GPU path first.
final class MTHeightmapCompute {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue
    /// 256-entry pow(x, 0.72) table — must match MTNoise.swift exactly.
    private let lutBuffer: MTLBuffer

    /// Cached permutation-table buffers, keyed by seed.
    private let tableLock = NSLock()
    private var tableSeed: UInt64?
    private var permBuffer: MTLBuffer?
    private var warpPermBuffer: MTLBuffer?

    /// Returns nil when the kernel is unavailable (older GPU, library
    /// issue) — the caller then uses the CPU path.
    init?(device: MTLDevice) {
        self.device = device
        guard let library = try? device.makeDefaultLibrary(bundle: .module),
              let function = library.makeFunction(name: "mtHeightmapKernel"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.pipeline = pipeline
        self.commandQueue = queue
        // Rebuild the exact LUT from MTNoise.swift (Float(pow(Double(x), 0.72))).
        var lut = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let x = Float(i) / 255.0
            lut[i] = Float(pow(Double(x), 0.72))
        }
        guard let lb = lut.withUnsafeBytes({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!,
                              length: ptr.count,
                              options: .storageModeShared)
        }) else {
            return nil
        }
        self.lutBuffer = lb
    }

    /// Generates `res*res` UInt16 heights for the chunk at world origin
    /// (`x0`, `z0`) with vertex spacing `step`.
    ///
    /// - Parameters:
    ///   - field: prebuilt height-field config (same one the CPU path uses).
    ///   - seed: world seed, used to key the cached permutation tables.
    ///   - noise/warpNoise: CPU-built tables for `seed` (from `noisePair()`).
    /// - Returns: quantized heights, or nil on any GPU failure so the
    ///   caller falls back to the CPU implementation.
    func generateHeights(x0: Double, z0: Double, step: Double, res: Int,
                         field: MTHeightFieldConfig,
                         seed: UInt64,
                         noise: MTPerlinNoise,
                         warpNoise: MTPerlinNoise,
                         vents: [MTTerrainWorld.MTVolcanoVent] = []) -> [UInt16]? {
        guard let outBuffer = generateHeightsBuffer(
                x0: x0, z0: z0, step: step, res: res, field: field,
                seed: seed, noise: noise, warpNoise: warpNoise,
                vents: vents) else {
            return nil
        }
        let ptr = outBuffer.contents().assumingMemoryBound(to: UInt16.self)
        return Array(UnsafeBufferPointer(start: ptr, count: res * res))
    }

    /// GPU dispatch returning the raw height buffer (no CPU readback).
    /// The buffer holds `res*res` UInt16 heights in `.storageModeShared`
    /// memory, so callers can read it back or feed it to another kernel.
    /// Returns nil on any failure — callers fall back to the CPU path.
    func generateHeightsBuffer(x0: Double, z0: Double, step: Double, res: Int,
                               field: MTHeightFieldConfig,
                               seed: UInt64,
                               noise: MTPerlinNoise,
                               warpNoise: MTPerlinNoise,
                               vents: [MTTerrainWorld.MTVolcanoVent] = []) -> MTLBuffer? {
        guard res >= 2 else { return nil }

        // Refresh the permutation-table buffers when the seed changes.
        tableLock.lock()
        if tableSeed != seed || permBuffer == nil || warpPermBuffer == nil {
            guard noise.perm.count == 512, warpNoise.perm.count == 512 else {
                tableLock.unlock()
                return nil
            }
            let p = noise.perm.map { UInt32($0) }
            let w = warpNoise.perm.map { UInt32($0) }
            guard let pb = p.withUnsafeBytes({ ptr in
                      device.makeBuffer(bytes: ptr.baseAddress!,
                                        length: ptr.count,
                                        options: .storageModeShared)
                  }),
                  let wb = w.withUnsafeBytes({ ptr in
                      device.makeBuffer(bytes: ptr.baseAddress!,
                                        length: ptr.count,
                                        options: .storageModeShared)
                  }) else {
                tableLock.unlock()
                return nil
            }
            permBuffer = pb
            warpPermBuffer = wb
            tableSeed = seed
        }
        let pb = permBuffer!
        let wb = warpPermBuffer!
        tableLock.unlock()

        let base = field.base
        var params = HeightmapParams(
            x0: Float(x0), z0: Float(z0), step: Float(step),
            baseFreq: Float(base.baseFrequency),
            lacunarity: Float(base.lacunarity),
            gain: Float(base.gain),
            baseAmplitude: Float(base.amplitude),
            warpStrength: Float(base.warpStrength),
            warpScale: Float(field.warpScale),
            continentFreq: Float(field.continentFreq),
            mtnFreq: Float(field.mtnFreq),
            riverFreq: Float(field.riverFreq),
            mountainSharpness: field.mountainSharpness,
            res: UInt32(res),
            baseOctaves: UInt32(field.baseOctaves),
            continentOctaves: UInt32(field.continentOctaves),
            warpOctaves: UInt32(field.warpOctaves),
            rangeOctaves: UInt32(field.rangeOctaves),
            riverOctaves: UInt32(field.riverOctaves),
            baseRidged: base.ridged ? 1 : 0,
            doWarp: field.doWarp ? 1 : 0,
            ventCount: UInt32(min(vents.count, 8))
        )

        // v1.3.0: volcano vent buffer (max 8). Empty buffer when no vents —
        // the kernel loops zero times.
        let gpuVents = vents.prefix(8).map {
            MTVolcanoVentGPU(pos: $0.position, radius: $0.craterRadius,
                             depth: $0.craterDepth, peakHeight: $0.peakHeight)
        }
        var ventArray = Array(gpuVents)
        if ventArray.isEmpty {
            ventArray.append(MTVolcanoVentGPU(pos: SIMD2<Float>(0, 0),
                                             radius: 0, depth: 0, peakHeight: 0))
        }

        let outLength = res * res * MemoryLayout<UInt16>.stride
        guard let paramBuffer = device.makeBuffer(
                    bytes: &params,
                    length: MemoryLayout<HeightmapParams>.stride,
                    options: .storageModeShared),
              let outBuffer = device.makeBuffer(length: outLength,
                                               options: .storageModeShared),
              let ventBuffer = ventArray.withUnsafeBytes({ ptr in
                  device.makeBuffer(bytes: ptr.baseAddress!,
                                    length: ptr.count,
                                    options: .storageModeShared)
              }),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(paramBuffer, offset: 0, index: 0)
        encoder.setBuffer(pb, offset: 0, index: 1)
        encoder.setBuffer(wb, offset: 0, index: 2)
        encoder.setBuffer(lutBuffer, offset: 0, index: 3)
        encoder.setBuffer(outBuffer, offset: 0, index: 4)
        encoder.setBuffer(ventBuffer, offset: 0, index: 5)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (res + 15) / 16,
                             height: (res + 15) / 16,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous: generateChunk already runs on a background queue.
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return outBuffer
    }
}
