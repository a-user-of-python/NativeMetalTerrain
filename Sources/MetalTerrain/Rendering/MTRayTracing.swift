// MTRayTracing.swift — ORIGINAL code for the MetalTerrain library.
//
// Hardware ray-traced shadow acceleration structures for terrain chunks.
//
// One bottom-level acceleration structure (BLAS) per chunk, built from the
// chunk's triangle soup, plus one top-level acceleration structure (TLAS)
// instancing every visible chunk. The TLAS is what the shadow shader traces
// against (see the `rt_shadow_occlusion` Metal helper, which the coordinator
// appends to MTShaders.metal).
//
// Hardware only: there is deliberately NO software ray-tracing fallback.
// On devices without ray-tracing units — or in builds without the
// M3_FEATURES Swift flag — this class compiles to a no-op stub:
// `isSupported == false`, `topLevelStructure == nil`, `update()` does
// nothing.

import Foundation
import Metal
import simd

#if M3_FEATURES

/// Hardware ray-traced shadow acceleration structures (M3/M4/M5, A17 Pro+).
///
/// Build flow: `update(chunks:)` (re)builds one BLAS per chunk (cached by
/// chunk id) and one TLAS over the current chunk set. The TLAS is rebuilt
/// only when the chunk id set or a chunk transform changes, so calling
/// `update` every frame is cheap once the visible set settles.
///
/// Builds are encoded on a blit encoder and waited on synchronously: the
/// TLAS must be resident before the next `draw` binds it. `update` is only
/// expensive when the visible chunk set actually changes (chunk streaming),
/// not per frame.
public final class MTRayTracing {

    /// Creates the ray-tracing helper for `device`. If the device lacks
    /// hardware ray tracing, every method below is a safe no-op.
    public init(device: MTLDevice) {
        self.device = device
        self.supported = MTCapabilities.supportsHardwareRayTracing(device: device)
        self.commandQueue = device.makeCommandQueue()
    }

    /// True when the device has hardware ray-tracing units AND this build
    /// enables them (compiled with M3_FEATURES).
    public var isSupported: Bool { supported }

    /// The built top-level acceleration structure, or nil until the first
    /// successful `update(chunks:)`. Bind it for the shadow pass with
    /// `encoder.setFragmentAccelerationStructure(_:at:)`.
    public var topLevelStructure: MTLAccelerationStructure? {
        lock.lock()
        defer { lock.unlock() }
        return tlas
    }

    /// (Re)builds acceleration structures for the visible chunk set.
    ///
    /// - Parameter chunks: one entry per visible chunk:
    ///   - `id`: stable per-chunk identifier; used as the BLAS cache key.
    ///   - `vertexBuffer` / `indexBuffer` / `indexCount`: the chunk's GPU
    ///     mesh. The vertex layout must be `MTVertex` (position as float4
    ///     at offset 0, 48-byte stride; see MTMeshBuilder.swift).
    ///   - `transform`: the chunk's model matrix. The renderer's chunk
    ///     meshes are world-space (drawn with an identity model matrix),
    ///     so this is normally `matrix_identity_float4x4`.
    ///
    /// BLAS entries are cached by `id` and evicted when a chunk leaves the
    /// set. The TLAS is rebuilt only when the chunk id set or any transform
    /// changes. Safe to call every frame; unchanged input costs one
    /// signature comparison.
    public func update(chunks: [(id: Int,
                                vertexBuffer: MTLBuffer,
                                indexBuffer: MTLBuffer,
                                indexCount: Int,
                                transform: matrix_float4x4)]) {
        guard supported, let queue = commandQueue else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !chunks.isEmpty else {
            tlas = nil
            blasCache.removeAll()
            lastSignature = nil
            return
        }
        let signature = chunks.map { ($0.id, $0.transform) }
        if let last = lastSignature, signaturesEqual(last, signature) {
            return  // chunk set and transforms unchanged: TLAS still valid
        }
        // Build (or reuse) one BLAS per chunk.
        var blases: [MTLAccelerationStructure] = []
        var transforms: [matrix_float4x4] = []
        blases.reserveCapacity(chunks.count)
        transforms.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard chunk.indexCount >= 3 else { continue }
            let blas: MTLAccelerationStructure
            if let cached = blasCache[chunk.id] {
                blas = cached
            } else if let built = buildBLAS(vertexBuffer: chunk.vertexBuffer,
                                            indexBuffer: chunk.indexBuffer,
                                            indexCount: chunk.indexCount,
                                            queue: queue) {
                blasCache[chunk.id] = built
                blas = built
            } else {
                continue  // failed BLAS: skip this chunk, keep the rest
            }
            blases.append(blas)
            transforms.append(chunk.transform)
        }
        // Drop BLAS entries for chunks that left the visible set.
        let live = Set(chunks.map(\.id))
        for id in blasCache.keys where !live.contains(id) {
            blasCache.removeValue(forKey: id)
        }
        guard !blases.isEmpty else {
            tlas = nil
            lastSignature = nil
            return
        }
        tlas = buildTLAS(blases: blases, transforms: transforms, queue: queue)
        lastSignature = signature
    }

    // MARK: - Internals

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let supported: Bool
    private let lock = NSLock()
    private var blasCache: [Int: MTLAccelerationStructure] = [:]
    private var tlas: MTLAccelerationStructure?
    private var lastSignature: [(id: Int, transform: matrix_float4x4)]?

    /// Element-wise signature comparison (arrays of tuples don't get `==`).
    private func signaturesEqual(_ a: [(id: Int, transform: matrix_float4x4)],
                                 _ b: [(id: Int, transform: matrix_float4x4)]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id || x.transform != y.transform { return false }
        }
        return true
    }

    /// Encodes one acceleration-structure build on a blit encoder and waits
    /// for completion. Returns nil if any step fails.
    private func build(descriptor: MTLAccelerationStructureDescriptor,
                       queue: MTLCommandQueue) -> MTLAccelerationStructure? {
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard sizes.accelerationStructureSize > 0,
              let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.scratchBufferSize, 1),
                                              options: .storageModePrivate),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        encoder.build(accelerationStructure: accel,
                      descriptor: descriptor,
                      scratchBuffer: scratch,
                      scratchBufferOffset: 0)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? accel : nil
    }

    /// Builds one BLAS from a chunk's triangle soup. The geometry
    /// descriptor must match `MTVertex` exactly: position is the first
    /// float4 (offset 0), 48-byte vertex stride, UInt32 indices.
    private func buildBLAS(vertexBuffer: MTLBuffer,
                           indexBuffer: MTLBuffer,
                           indexCount: Int,
                           queue: MTLCommandQueue) -> MTLAccelerationStructure? {
        let geo = MTLAccelerationStructureTriangleGeometryDescriptor()
        geo.vertexBuffer = vertexBuffer
        geo.vertexBufferOffset = 0
        geo.vertexFormat = .float4
        geo.vertexStride = MemoryLayout<MTVertex>.stride  // 48
        geo.indexBuffer = indexBuffer
        geo.indexBufferOffset = 0
        geo.indexType = .uint32
        geo.indexCount = indexCount
        geo.triangleCount = indexCount / 3
        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geo]
        return build(descriptor: descriptor, queue: queue)
    }

    /// Builds one TLAS instancing every BLAS. Instance transforms are the
    /// chunk model matrices packed to 4x3 (translation kept, projection
    /// row dropped).
    private func buildTLAS(blases: [MTLAccelerationStructure],
                           transforms: [matrix_float4x4],
                           queue: MTLCommandQueue) -> MTLAccelerationStructure? {
        var instances: [MTLAccelerationStructureInstanceDescriptor] = []
        instances.reserveCapacity(blases.count)
        for (i, t) in transforms.enumerated() {
            var inst = MTLAccelerationStructureInstanceDescriptor()
            inst.transformationMatrix = packedFloat4x3(t)
            inst.options = .opaque  // no any-hit shaders; first hit wins
            inst.mask = 0xFF
            inst.intersectionFunctionTableOffset = 0
            inst.accelerationStructureIndex = UInt32(i)
            instances.append(inst)
        }
        let instanceBuffer: MTLBuffer? = instances.withUnsafeBytes { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!,
                              length: ptr.count,
                              options: .storageModeShared)
        }
        guard let instanceBuffer else { return nil }
        let descriptor = MTLInstanceAccelerationStructureDescriptor()
        descriptor.instancedAccelerationStructures = blases
        descriptor.instanceDescriptorBuffer = instanceBuffer
        descriptor.instanceDescriptorStride =
            MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride  // 64
        descriptor.instanceDescriptorBufferOffset = 0
        descriptor.instanceCount = instances.count
        return build(descriptor: descriptor, queue: queue)
    }

    /// Converts a column-major 4x4 model matrix to the packed 4x3 form the
    /// instance descriptor expects.
    private func packedFloat4x3(_ m: matrix_float4x4) -> MTLPackedFloat4x3 {
        var p = MTLPackedFloat4x3()
        p.columns.0 = MTLPackedFloat3Make(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        p.columns.1 = MTLPackedFloat3Make(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        p.columns.2 = MTLPackedFloat3Make(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        p.columns.3 = MTLPackedFloat3Make(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return p
    }
}

#else

/// Stub used when the M3_FEATURES Swift flag is off: hardware ray tracing
/// is compiled out, so this class reports unsupported and does nothing.
/// The type still exists so renderer code referencing it compiles in both
/// build variants.
public final class MTRayTracing {

    /// Creates the stub. The device is ignored.
    public init(device: MTLDevice) {}

    /// Always false in the stub: ray tracing is compiled out.
    public var isSupported: Bool { false }

    /// Always nil in the stub.
    public var topLevelStructure: MTLAccelerationStructure? { nil }

    /// No-op in the stub.
    public func update(chunks: [(id: Int,
                                 vertexBuffer: MTLBuffer,
                                 indexBuffer: MTLBuffer,
                                 indexCount: Int,
                                 transform: matrix_float4x4)]) {}
}

#endif
