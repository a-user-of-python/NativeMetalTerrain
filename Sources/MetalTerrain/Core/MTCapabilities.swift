// MTCapabilities.swift — ORIGINAL code for the MetalTerrain library.
//
// Device capability queries for optional GPU features (hardware ray
// tracing, mesh shading). These are pure queries — they never change
// device state — so they are safe to call at startup and to cache.

import Metal

/// Capability queries for optional MetalTerrain GPU features.
///
/// Hardware facts (Apple silicon):
/// - Hardware ray tracing: M3/M4/M5 (all variants), A17 Pro, A18,
///   A18 Pro, A19, A19 Pro and later. NOT on M1/M2/A16 or earlier.
/// - Mesh shading: Apple GPU family 9+ (M3/M4/M5, A17 Pro and later).
public enum MTCapabilities {

    /// True when the GPU has hardware ray-tracing units.
    ///
    /// Backed by `MTLDevice.supportsRayTracing` (available since iOS 16).
    /// This is a hardware query only — the M3_FEATURES Swift flag still
    /// gates whether the ray-tracing code paths are compiled in.
    public static func supportsHardwareRayTracing(device: MTLDevice) -> Bool {
        device.supportsRayTracing
    }

    /// True when the GPU supports mesh shading (Apple GPU family 9+).
    ///
    /// `supportsFamily` needs the iOS 17 / macOS 14 SDK; on older SDKs
    /// this conservatively returns false.
    public static func supportsMeshShading(device: MTLDevice) -> Bool {
        if #available(iOS 17, macOS 14, *) {
            return device.supportsFamily(.apple9)
        } else {
            return false
        }
    }
}
