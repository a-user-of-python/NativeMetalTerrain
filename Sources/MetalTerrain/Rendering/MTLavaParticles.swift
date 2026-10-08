// MTLavaParticles.swift
// MetalTerrain — volcano lava particle simulation (v1.3.0).
//
// CPU-simulated, GPU-rendered: up to 200 lava blobs arc out of erupting
// volcano vents under gravity; on landing they become glowing deposits
// that fade over several seconds. Eruptions are randomized per vent.
//
// The renderer draws the instances as camera-facing billboards with an
// emissive lava shader (additive blending, visible day and night).

import Foundation
import simd

/// One flying lava blob.
public struct MTLavaParticle {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var life: Float      // seconds remaining
    public var maxLife: Float
    public var size: Float      // world units (billboard half-extent)
}

/// A landed lava deposit: a glowing pool on the terrain that cools over
/// 30-60 seconds. Lethal while hot (heat > 0.3), safe once cooled black.
public struct MTLavaDeposit {
    public var position: SIMD3<Float>  // world, y = terrain surface
    public var radius: Float
    public var life: Float      // seconds of heat remaining
    public var maxLife: Float
}

/// Render-ready lava instance (particle or deposit).
public struct MTLavaRenderInstance {
    public var position: SIMD3<Float>
    public var size: Float
    /// 0 = flying blob (round), 1 = ground deposit (flat disc).
    public var kind: Float
    /// 0...1 freshness: drives brightness in the shader.
    public var heat: Float
}

/// Simulates volcano eruptions and lava. Owned by MTTerrainRenderer.
public final class MTLavaParticles {
    public static let maxParticles = 200
    public static let maxDeposits = 100

    private(set) public var particles: [MTLavaParticle] = []
    private(set) public var deposits: [MTLavaDeposit] = []

    private struct VentState {
        var timer: Float     // seconds until eruption state flips
        var erupting: Bool
        var intensity: Float // 0...1 spawn-rate multiplier
        var spawnAccum: Float
    }
    private var ventStates: [VentState] = []
    private var rng: MTSeededRandom
    private var frame = 0
    /// Cached vents for pool rendering / pool lethality (updated in update()).
    private var poolVents: [MTTerrainWorld.MTVolcanoVent] = []

    public init(seed: UInt64) {
        // Domain-separated from terrain/structure noise.
        self.rng = MTSeededRandom(seed: seed ^ 0x5A1A5A1A5A1A5A1A)
    }

    /// Reset after a seed change / world rebuild.
    public func reset(seed: UInt64) {
        rng = MTSeededRandom(seed: seed ^ 0x5A1A5A1A5A1A5A1A)
        particles.removeAll(keepingCapacity: true)
        deposits.removeAll(keepingCapacity: true)
        ventStates.removeAll(keepingCapacity: true)
        poolVents.removeAll(keepingCapacity: true)
    }

    /// Advance the simulation. Call once per frame from the renderer.
    /// - Parameters:
    ///   - dt: frame delta seconds (clamped internally).
    ///   - world: terrain world (volcano vents + height queries).
    ///   - cameraTarget: world XZ the camera follows; distant vents sleep.
    public func update(dt: Float, world: MTTerrainWorld,
                       cameraTarget: SIMD2<Float>) {
        let dt = min(max(dt, 0), 0.1)
        frame &+= 1
        let vents = world.volcanoVents
        poolVents = vents
        // Rebuild vent state when the vent set changes (seed/config change).
        if ventStates.count != vents.count {
            ventStates = vents.map { _ in
                VentState(timer: 2 + rng.nextFloat() * 8,
                          erupting: false, intensity: 0, spawnAccum: 0)
            }
        }
        let heightScale = world.config.heightScale

        for (vi, vent) in vents.enumerated() {
            // Sleep vents far from the camera (3km): no lava where the
            // player can't see or reach it.
            let dx = vent.position.x - cameraTarget.x
            let dz = vent.position.y - cameraTarget.y
            if dx * dx + dz * dz > 3000 * 3000 { continue }

            var st = ventStates[vi]
            st.timer -= dt
            if st.timer <= 0 {
                st.erupting.toggle()
                if st.erupting {
                    st.timer = 10 + rng.nextFloat() * 10
                    st.intensity = 0.5 + rng.nextFloat() * 0.5
                } else {
                    st.timer = 1 + rng.nextFloat() * 1
                    st.intensity = 0
                    st.spawnAccum = 0
                }
            }
            if st.erupting {
                // ~24 blobs/sec at full intensity.
                st.spawnAccum += dt * 24 * st.intensity
                while st.spawnAccum >= 1 && particles.count < Self.maxParticles {
                    st.spawnAccum -= 1
                    spawnBlob(vent: vent, heightScale: heightScale)
                }
                if st.spawnAccum > 4 { st.spawnAccum = 4 }
            }
            ventStates[vi] = st
        }

        // Integrate particles.
        var i = 0
        while i < particles.count {
            var p = particles[i]
            p.velocity.y -= 32 * dt  // gravity
            p.position += p.velocity * dt
            p.life -= dt
            var kill = p.life <= 0
            // Staggered landing checks: 1/3 of particles per frame.
            if !kill && p.velocity.y < 0 && (frame + i) % 3 == 0 {
                let h = world.heightAt(x: Double(p.position.x),
                                       z: Double(p.position.z))
                let groundY = h * heightScale
                if p.position.y <= groundY + 0.3 {
                    landBlob(p, groundY: groundY)
                    kill = true
                }
            }
            // Safety: never simulate forever.
            if !kill && p.position.y < -500 { kill = true }
            if kill {
                particles.swapAt(i, particles.count - 1)
                particles.removeLast()
            } else {
                particles[i] = p
                i += 1
            }
        }

        // Fade deposits.
        var d = 0
        while d < deposits.count {
            deposits[d].life -= dt
            if deposits[d].life <= 0 {
                deposits.swapAt(d, deposits.count - 1)
                deposits.removeLast()
            } else {
                d += 1
            }
        }
    }

    /// Is there lethal lava at a world position? Blobs kill within 1.3m
    /// (must actually touch). Deposits kill within their radius only while
    /// hot (heat > 0.3) — cooled black lava is safe. Crater lava pools
    /// are always lethal.
    public func isLavaAt(_ p: SIMD3<Float>) -> Bool {
        for b in particles {
            let dx = b.position.x - p.x
            let dy = b.position.y - p.y
            let dz = b.position.z - p.z
            if dx * dx + dy * dy + dz * dz < 1.3 * 1.3 { return true }
        }
        for dep in deposits {
            let heat = dep.life / dep.maxLife
            guard heat > 0.3 else { continue }  // cooled lava is safe
            let dx = dep.position.x - p.x
            let dz = dep.position.z - p.z
            if dx * dx + dz * dz < dep.radius * dep.radius
                && abs(p.y - dep.position.y) < 3.0 {
                return true
            }
        }
        // Crater lava pools: always lethal.
        for v in poolVents {
            let dx = p.x - v.position.x
            let dz = p.z - v.position.y
            let r = v.craterRadius * 0.7
            if dx * dx + dz * dz < r * r
                && p.y < v.ventY + 4.0 && p.y > v.ventY - 12.0 {
                return true
            }
        }
        return false
    }

    /// Instances for the renderer's lava draw call.
    public func renderInstances() -> [MTLavaRenderInstance] {
        var out: [MTLavaRenderInstance] = []
        out.reserveCapacity(particles.count + deposits.count)
        for p in particles {
            out.append(MTLavaRenderInstance(
                position: p.position, size: p.size, kind: 0,
                heat: max(p.life / p.maxLife, 0)))
        }
        for dep in deposits {
            out.append(MTLavaRenderInstance(
                position: dep.position, size: dep.radius, kind: 1,
                heat: max(dep.life / dep.maxLife, 0)))
        }
        return out
    }

    /// Lava pool instances: one glowing disc per nearby vent, rendered
    /// with the deposit shader. Heat pulses for a bubbling look.
    /// Call each frame and append to `renderInstances()` output.
    public func poolInstances(time: Float,
                              cameraTarget: SIMD2<Float>) -> [MTLavaRenderInstance] {
        var out: [MTLavaRenderInstance] = []
        for (i, v) in poolVents.enumerated() {
            let dx = v.position.x - cameraTarget.x
            let dz = v.position.y - cameraTarget.y
            if dx * dx + dz * dz > 3000 * 3000 { continue }
            // Bubbling pulse: 0.72...1.0 heat oscillation, phase per vent.
            let heat = 0.86 + 0.14 * sin(time * 2.2 + Float(i) * 2.1)
            out.append(MTLavaRenderInstance(
                position: SIMD3<Float>(v.position.x, v.ventY + 0.3, v.position.y),
                size: v.craterRadius * 0.7,
                kind: 1,
                heat: heat))
        }
        return out
    }

    // MARK: - Private

    private func spawnBlob(vent: MTTerrainWorld.MTVolcanoVent,
                           heightScale: Float) {
        // Launch from the vent with upward + outward velocity.
        let ang = rng.nextFloat() * 6.28318
        let outSpeed = 4 + rng.nextFloat() * 12
        let upSpeed = 22 + rng.nextFloat() * 22
        let ox = cos(ang) * rng.nextFloat() * vent.craterRadius * 0.4
        let oz = sin(ang) * rng.nextFloat() * vent.craterRadius * 0.4
        let life: Float = 4 + rng.nextFloat() * 2.5
        particles.append(MTLavaParticle(
            position: SIMD3<Float>(vent.position.x + ox, vent.ventY + 2, vent.position.y + oz),
            velocity: SIMD3<Float>(cos(ang) * outSpeed, upSpeed, sin(ang) * outSpeed),
            life: life, maxLife: life,
            size: 1.2 + rng.nextFloat() * 2.2))
    }

    private func landBlob(_ p: MTLavaParticle, groundY: Float) {
        guard deposits.count < Self.maxDeposits else { return }
        // v1.3.0-refine: deposits persist 30-60s, cooling from glowing
        // yellow-white to black. Lethal while hot (heat > 0.3).
        let life: Float = 30 + rng.nextFloat() * 30
        deposits.append(MTLavaDeposit(
            position: SIMD3<Float>(p.position.x, groundY + 0.35, p.position.z),
            radius: 2.0 + rng.nextFloat() * 1.8,
            life: life, maxLife: life))
    }
}
