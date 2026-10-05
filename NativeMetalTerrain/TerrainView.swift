import SwiftUI
import MetalKit
import MetalTerrain

// MARK: - Biome presets

/// Biome presets offered by the demo's segmented picker.
enum BiomePreset: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case desert = "Desert"
    case alien = "Alien"
    case forest = "Forest"
    case custom = "Custom"

    var id: String { rawValue }
}

// MARK: - Camera mode

/// Orbit = classic 3/4 aerial view. Walk = first-person on the terrain.
enum CameraMode: String, CaseIterable, Identifiable {
    case orbit = "Orbit"
    case walk = "Walk"

    var id: String { rawValue }
}

// MARK: - Drag mode (Mac Catalyst)

/// On Mac there's no two-finger touch: the user picks what mouse-drag does.
/// Trackpad pinch still zooms and two-finger trackpad scroll still pans.
enum DragMode: String, CaseIterable, Identifiable {
    case orbit = "Orbit"
    case pan = "Pan"

    var id: String { rawValue }
}

// MARK: - TerrainView

#if targetEnvironment(macCatalyst)
/// MTKView subclass so Mac key commands have a UIResponder to land on.
/// Forwards to the Coordinator (which owns the camera state).
private final class TerrainMTKView: MTKView {
    weak var keyTarget: TerrainView.Coordinator?

    override var canBecomeFirstResponder: Bool { true }

    @objc private func keyPanUp() { keyTarget?.keyPanUp() }
    @objc private func keyPanDown() { keyTarget?.keyPanDown() }
    @objc private func keyPanLeft() { keyTarget?.keyPanLeft() }
    @objc private func keyPanRight() { keyTarget?.keyPanRight() }
    @objc private func keyZoomIn() { keyTarget?.keyZoomIn() }
    @objc private func keyZoomOut() { keyTarget?.keyZoomOut() }
    @objc private func keyResetView() { keyTarget?.keyResetView() }
}
#endif

/// SwiftUI wrapper around an MTKView that renders a MetalTerrain world.
struct TerrainView: UIViewRepresentable {
    @Binding var seed: UInt64
    /// Bump to force a full world + renderer rebuild (Regenerate button).
    @Binding var rebuildToken: Int
    @Binding var preset: BiomePreset
    @Binding var structuresEnabled: Bool
    @Binding var wireframe: Bool
    @Binding var showsWater: Bool
    @Binding var fogEnabled: Bool
    @Binding var viewDistance: Int
    @Binding var shaderEffectsEnabled: Bool
    /// Mac Catalyst: what mouse-drag does (touch devices always orbit).
    @Binding var dragMode: DragMode
    /// Orbit vs first-person walk.
    @Binding var cameraMode: CameraMode
    /// Eye height above terrain in walk mode (player size).
    @Binding var playerHeight: Float
    /// Joystick input: x = strafe, y = forward (-1...1 each).
    /// When the debug car is active, x = steering, y = throttle.
    @Binding var moveInput: SIMD2<Float>
    /// Debug car active (spawned + follow camera).
    @Binding var carActive: Bool
    /// Called once the Metal renderer exists, so ContentView can push
    /// sun updates directly without a SwiftUI re-render.
    var onRendererReady: ((MTTerrainRenderer) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        #if targetEnvironment(macCatalyst)
        let view = TerrainMTKView()
        #else
        let view = MTKView()
        #endif
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.04, green: 0.06, blue: 0.11, alpha: 1.0)
        context.coordinator.attach(to: view, parent: self)
        #if targetEnvironment(macCatalyst)
        (view as? TerrainMTKView)?.keyTarget = context.coordinator
        #endif
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.sync(with: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate {
        // Camera: orbit around `target` (spherical). Survives world rebuilds.
        // Starts at a 3/4 aerial view.
        var yaw: Float = -0.6
        var pitch: Float = 0.62
        var distance: Float = 550
        var target = SIMD3<Float>(0, 0, 0)
        // Walk mode: player position on the XZ plane. Y follows terrain.
        var playerPos = SIMD2<Float>(0, 0)
        var walkYaw: Float = 0
        var walkPitch: Float = -0.1

        // Debug car state (app-only).
        var carSpawned = false
        var carPos = SIMD2<Float>(0, 0)   // XZ position
        var carHeading: Float = 0         // yaw; forward = (sin, cos) in XZ
        var carSpeed: Float = 0           // world units/sec (+ forward)
        var carSteer: Float = 0           // smoothed -1...1
        var carWheelSpin: Float = 0       // radians, about the wheel axle
        var followCamPos = SIMD3<Float>(0, 0, 0)
        var followCamInit = false
        private var carRenderer: CarRenderer?

        private var parent = TerrainView(
            seed: .constant(1337), rebuildToken: .constant(0),
            preset: .constant(.default), structuresEnabled: .constant(true),
            wireframe: .constant(false), showsWater: .constant(true),
            fogEnabled: .constant(true), viewDistance: .constant(6),
            shaderEffectsEnabled: .constant(false),
            dragMode: .constant(.orbit),
            cameraMode: .constant(.walk), playerHeight: .constant(2),
            moveInput: .constant(SIMD2<Float>(0, 0)),
            carActive: .constant(false)
        )
        private var device: MTLDevice?
        private var world: MTTerrainWorld?
        private var renderer: MTTerrainRenderer?

        private var lastSeed: UInt64?
        private var lastToken: Int?
        private var lastPreset: BiomePreset?
        private var lastStructuresEnabled: Bool?
        private var lastViewDistance: Int?

        private var fpsEMA: Double = 60
        private var lastFrameTime: CFTimeInterval = 0
        private var lastFPSPush: CFTimeInterval = 0

        // MARK: Setup

        func attach(to view: MTKView, parent: TerrainView) {
            self.parent = parent
            self.device = view.device

            let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            view.addGestureRecognizer(orbit)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)

            let reset = UITapGestureRecognizer(target: self, action: #selector(handleReset(_:)))
            reset.numberOfTapsRequired = 2
            view.addGestureRecognizer(reset)

            #if targetEnvironment(macCatalyst)
            // Mac keyboard controls: arrows pan, +/- zoom, 0 resets.
            // (Trackpad pinch/scroll already work via the recognizers above.)
            view.addKeyCommand(UIKeyCommand(input: UIKeyCommand.inputUpArrow,
                                            modifierFlags: [],
                                            action: #selector(keyPanUp)))
            view.addKeyCommand(UIKeyCommand(input: UIKeyCommand.inputDownArrow,
                                            modifierFlags: [],
                                            action: #selector(keyPanDown)))
            view.addKeyCommand(UIKeyCommand(input: UIKeyCommand.inputLeftArrow,
                                            modifierFlags: [],
                                            action: #selector(keyPanLeft)))
            view.addKeyCommand(UIKeyCommand(input: UIKeyCommand.inputRightArrow,
                                            modifierFlags: [],
                                            action: #selector(keyPanRight)))
            view.addKeyCommand(UIKeyCommand(input: "+", modifierFlags: [],
                                            action: #selector(keyZoomIn)))
            view.addKeyCommand(UIKeyCommand(input: "-", modifierFlags: [],
                                            action: #selector(keyZoomOut)))
            view.addKeyCommand(UIKeyCommand(input: "0", modifierFlags: [],
                                            action: #selector(keyResetView)))
            // Key commands need first responder.
            DispatchQueue.main.async { view.becomeFirstResponder() }
            #endif
        }

        /// Applies SwiftUI state to the Metal objects. Rebuilds the world only
        /// when the seed, rebuild token, or biome preset changed.
        func sync(with parent: TerrainView) {
            self.parent = parent
            if lastSeed != parent.seed || lastToken != parent.rebuildToken || lastPreset != parent.preset {
                rebuildWorld(seed: parent.seed, preset: parent.preset)
                lastSeed = parent.seed
                lastToken = parent.rebuildToken
                lastPreset = parent.preset
            }
            renderer?.wireframe = parent.wireframe
            renderer?.showsWater = parent.showsWater
            renderer?.fogEnabled = parent.fogEnabled
            renderer?.shaderEffectsEnabled = parent.shaderEffectsEnabled
            if lastViewDistance != parent.viewDistance {
                lastViewDistance = parent.viewDistance
                renderer?.viewDistance = parent.viewDistance
            }
            // Only write when changed: the setter bumps configVersion, which
            // makes the renderer invalidate all chunk caches. Writing the same
            // value every sync() (2x/sec via the FPS label) caused a perpetual
            // rebuild storm — the terrain never stabilized.
            if lastStructuresEnabled != parent.structuresEnabled {
                lastStructuresEnabled = parent.structuresEnabled
                world?.structuresEnabled = parent.structuresEnabled
            }
            // Debug car spawn / despawn.
            if carSpawned != parent.carActive {
                carSpawned = parent.carActive
                if carSpawned {
                    spawnCar()
                }
            }
        }

        // MARK: World construction

        private func rebuildWorld(seed: UInt64, preset: BiomePreset) {
            guard let device else { return }

            // ─────────────────────────────────────────────────────────
            // This is the whole integration:
            // ─────────────────────────────────────────────────────────
            let world: MTTerrainWorld
            switch preset {
            case .default:
                world = MTTerrainWorld(seed: seed, config: .default)
            case .desert:
                var config = MTTerrainConfig.default
                config.biomes = Self.desertBiomes
                world = MTTerrainWorld(seed: seed, config: config)
            case .alien:
                var config = MTTerrainConfig.default
                config.biomes = Self.alienBiomes
                world = MTTerrainWorld(seed: seed, config: config)
            case .forest:
                var config = MTTerrainConfig.default
                config.biomes = Self.forestBiomes
                // Dense woodland: boost structure density for a lived-in feel.
                config.structureDensity = 0.65
                config.structuresEnabled = true
                world = MTTerrainWorld(seed: seed, config: config)
            case .custom:
                world = MTTerrainWorld(seed: seed, config: .default)
                // Custom biome: takes precedence over the built-ins in 0.80–1.0,
                // replacing the default mountain/snowyPeak bands up there.
                world.setBiome(MTBiome(
                    name: "highPeaks",
                    minHeight: 0.80, maxHeight: 1.0,
                    groundColor: SIMD3<Float>(0.80, 0.78, 0.85),
                    slopeColor: SIMD3<Float>(0.30, 0.28, 0.34)
                ))
            }
            self.world = world
            let renderer = MTTerrainRenderer(device: device, world: world)
            renderer.wireframe = parent.wireframe
            renderer.showsWater = parent.showsWater
            self.renderer = renderer
            // Find safe spawn: search outward for land above sea level.
            playerPos = findSafeSpawn(in: world)
            parent.onRendererReady?(renderer)
            // ─────────────────────────────────────────────────────────
        }

        // MARK: - Debug car (app-only)

        /// Searches a spiral for land above sea level (not water, not steep).
        private func findSafeSpawn(in world: MTTerrainWorld) -> SIMD2<Float> {
            let seaLevel = world.config.seaLevel
            // Try (0,0) first, then spiral outward.
            for radius: Double in [0, 100, 200, 400, 800, 1600] {
                for angle in stride(from: 0.0, to: 6.28, by: 0.5) {
                    let x = radius * cos(angle)
                    let z = radius * sin(angle)
                    let h = world.heightAt(x: x, z: z)
                    // Land, above beach, below mountain (flat-ish).
                    if h > seaLevel + 0.05 && h < 0.70 {
                        return SIMD2<Float>(Float(x), Float(z))
                    }
                }
            }
            return SIMD2<Float>(0, 0)  // fallback
        }

        /// Spawns the car at the player's feet (walk) or the camera target
        /// (orbit), nudged onto nearby land if the spot is water.
        private func spawnCar() {
            guard let world, let device else { return }
            if carRenderer == nil {
                carRenderer = CarRenderer(device: device)
            }
            var spot = parent.cameraMode == .walk
                ? playerPos
                : SIMD2<Float>(target.x, target.z)
            let seaLevel = world.config.seaLevel
            if world.heightAt(x: Double(spot.x), z: Double(spot.y)) < seaLevel {
                outer: for radius: Float in [20, 60, 120, 250] {
                    for angle in stride(from: Float(0), to: Float(6.28), by: Float(0.5)) {
                        let c = SIMD2<Float>(spot.x + radius * cos(angle),
                                             spot.y + radius * sin(angle))
                        if world.heightAt(x: Double(c.x), z: Double(c.y)) >= seaLevel {
                            spot = c
                            break outer
                        }
                    }
                }
            }
            carPos = spot
            carHeading = parent.cameraMode == .walk ? walkYaw : 0
            carSpeed = 0
            carSteer = 0
            carWheelSpin = 0
            followCamInit = false
        }

        /// World-space Y of the terrain at an XZ point.
        private func groundY(at p: SIMD2<Float>) -> Float {
            guard let world else { return 0 }
            return world.worldY(forHeight: world.heightAt(x: Double(p.x), z: Double(p.y)))
        }

        /// Terrain normal at the car, from central differences of the
        /// heightfield. This is what tilts the car onto slopes.
        private func terrainNormal(at p: SIMD2<Float>) -> SIMD3<Float> {
            let e: Float = 2.0
            let hx = groundY(at: SIMD2<Float>(p.x + e, p.y)) - groundY(at: SIMD2<Float>(p.x - e, p.y))
            let hz = groundY(at: SIMD2<Float>(p.x, p.y + e)) - groundY(at: SIMD2<Float>(p.x, p.y - e))
            return normalize(SIMD3<Float>(-hx / (2 * e), 1, -hz / (2 * e)))
        }

        /// Car world transform: origin at the terrain surface under the car
        /// center, up-axis aligned to the terrain normal (NOT locked
        /// vertical), forward from the heading projected onto the slope.
        private func carModelMatrix() -> simd_float4x4 {
            let n = terrainNormal(at: carPos)
            let fwd0 = SIMD3<Float>(sin(carHeading), 0, cos(carHeading))
            var fwd = fwd0 - n * dot(fwd0, n)
            if length_squared(fwd) < 1e-6 {
                // Heading straight up a cliff face: fall back to world +Z.
                fwd = SIMD3<Float>(0, 0, 1) - n * n.z
            }
            fwd = normalize(fwd)
            let right = normalize(cross(n, fwd))
            let fwd2 = cross(right, n)  // re-orthogonalized
            let pos = SIMD3<Float>(carPos.x, groundY(at: carPos), carPos.y)
            var m = matrix_identity_float4x4
            m.columns.0 = SIMD4<Float>(right, 0)
            m.columns.1 = SIMD4<Float>(n, 0)
            m.columns.2 = SIMD4<Float>(fwd2, 0)
            m.columns.3 = SIMD4<Float>(pos, 1)
            return m
        }

        /// Arcade car physics: joystick Y = throttle/brake, X = steering.
        /// Tuned for feel: smooth acceleration, responsive but stable steering.
        private func updateCar(dt: Float) {
            guard let world else { return }
            let input = parent.moveInput
            let dt = min(max(dt, 0), 0.1)

            // Steering smoothing (no twitch).
            carSteer += (input.x - carSteer) * min(1, dt * 10)

            // Throttle / brake / reverse. Softer acceleration for control.
            let accel: Float = 32
            if input.y > 0.05 {
                // Smooth acceleration curve: stronger at low speed.
                let speedFactor = 1.0 - min(abs(carSpeed) / 60.0, 0.7)
                carSpeed += input.y * accel * speedFactor * dt
            } else if input.y < -0.05 {
                if carSpeed > 1 {
                    carSpeed += input.y * accel * 2.0 * dt  // braking
                } else {
                    carSpeed += input.y * accel * 0.5 * dt  // reverse (slower)
                }
            }
            // Drag + rolling resistance.
            carSpeed -= carSpeed * 0.9 * dt
            carSpeed -= (carSpeed >= 0 ? 1 : -1) * 4 * dt
            if abs(carSpeed) < 0.3 && abs(input.y) < 0.05 { carSpeed = 0 }
            carSpeed = min(50, max(-18, carSpeed))

            // Steering: responsive at low speed, stable at high speed.
            // Note: negated because the chase camera mirrors the steering
            // (joystick left must turn the car left on screen).
            if abs(carSpeed) > 0.5 {
                let wheelBase: Float = 5.4
                // Reduce steering at high speed to prevent spinouts.
                let speedDamp = 1.0 / (1.0 + abs(carSpeed) * 0.02)
                carHeading -= carSteer * CarRenderer.maxSteerAngle
                    * (carSpeed / wheelBase) * speedDamp * dt
            }

            // Integrate; block water like walk mode (with axis slide).
            let fwd = SIMD2<Float>(sin(carHeading), cos(carHeading))
            let seaLevel = world.config.seaLevel
            let tryPos = carPos + fwd * carSpeed * dt
            if world.heightAt(x: Double(tryPos.x), z: Double(tryPos.y)) >= seaLevel {
                carPos = tryPos
            } else {
                carSpeed *= 0.4
                let tryX = SIMD2<Float>(carPos.x + fwd.x * carSpeed * dt, carPos.y)
                if world.heightAt(x: Double(tryX.x), z: Double(tryX.y)) >= seaLevel {
                    carPos = tryX
                } else {
                    let tryZ = SIMD2<Float>(carPos.x, carPos.y + fwd.y * carSpeed * dt)
                    if world.heightAt(x: Double(tryZ.x), z: Double(tryZ.y)) >= seaLevel {
                        carPos = tryZ
                    }
                }
            }

            // Wheel spin (radius 1.0).
            carWheelSpin += carSpeed * dt
        }

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Aspect is recomputed every frame in draw(in:).
        }

        func draw(in view: MTKView) {
            guard let renderer else { return }

            // Frame-time EMA -> FPS label (pushed to SwiftUI at most 2x/sec).
            let now = CACurrentMediaTime()
            // Capture dt BEFORE lastFrameTime is updated below (walk mode needs it).
            let frameDt = lastFrameTime > 0 ? Float(now - lastFrameTime) : 0
            if lastFrameTime > 0 {
                let dt = now - lastFrameTime
                if dt > 0 {
                    fpsEMA = fpsEMA * 0.92 + (1.0 / dt) * 0.08
                }
                if now - lastFPSPush > 0.5 {
                    lastFPSPush = now
                    // Store on renderer; ContentView polls via timer (avoids
                    // "modifying state during view update" from the render loop).
                    renderer.currentFPS = fpsEMA
                }
            }
            lastFrameTime = now

            let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))

            let camPosition: SIMD3<Float>
            let camTarget: SIMD3<Float>
            if carSpawned {
                // Debug car: joystick drives + steers; camera follows behind.
                updateCar(dt: frameDt)
                let carM = carModelMatrix()
                let fwd3 = SIMD3<Float>(carM.columns.2.x, carM.columns.2.y, carM.columns.2.z)
                let up3 = SIMD3<Float>(carM.columns.1.x, carM.columns.1.y, carM.columns.1.z)
                let carPos3 = SIMD3<Float>(carM.columns.3.x, carM.columns.3.y, carM.columns.3.z)
                let desired = carPos3 - fwd3 * 26 + up3 * 11
                if !followCamInit {
                    followCamPos = desired
                    followCamInit = true
                }
                let k = 1 - exp(-4.5 * min(max(frameDt, 0), 0.1))
                followCamPos = mix(followCamPos, desired, t: k)
                camPosition = followCamPos
                camTarget = carPos3 + fwd3 * 8 + up3 * 3
                // Keep the chunk streamer centered on the car.
                target = carPos3
            } else if parent.cameraMode == .walk, let world {
                // Walk mode: first-person. Joystick moves the player on XZ;
                // Y follows the terrain height + eye height (player size).
                let input = parent.moveInput
                let speed: Float = 45  // world units/sec at full tilt
                let dt = min(frameDt, 0.1)
                let forward = SIMD2<Float>(sin(walkYaw), cos(walkYaw))
                let right = SIMD2<Float>(-forward.y, forward.x)
                let delta = (forward * input.y + right * input.x) * speed * dt
                // Water blocking: don't walk into the ocean.
                let tryPos = playerPos + delta
                let tryHeight = world.heightAt(x: Double(tryPos.x), z: Double(tryPos.y))
                if tryHeight >= world.config.seaLevel {
                    playerPos = tryPos
                }
                // If blocked, try sliding along each axis separately.
                else {
                    let tryX = SIMD2<Float>(playerPos.x + delta.x, playerPos.y)
                    let hx = world.heightAt(x: Double(tryX.x), z: Double(tryX.y))
                    if hx >= world.config.seaLevel { playerPos = tryX }
                    else {
                        let tryZ = SIMD2<Float>(playerPos.x, playerPos.y + delta.y)
                        let hz = world.heightAt(x: Double(tryZ.x), z: Double(tryZ.y))
                        if hz >= world.config.seaLevel { playerPos = tryZ }
                    }
                }
                let groundY = world.worldY(forHeight: world.heightAt(x: Double(playerPos.x), z: Double(playerPos.y)))
                let eyeY = groundY + max(2, parent.playerHeight)
                camPosition = SIMD3<Float>(playerPos.x, eyeY, playerPos.y)
                let cp = cos(walkPitch)
                let lookDir = SIMD3<Float>(sin(walkYaw) * cp, sin(walkPitch), cos(walkYaw) * cp)
                camTarget = camPosition + lookDir * 10
                // Keep the chunk streamer centered on the player.
                target = SIMD3<Float>(playerPos.x, 0, playerPos.y)
            } else {
                // Orbit mode: joystick moves the target (camera follows).
                let input = parent.moveInput
                if input.x != 0 || input.y != 0 {
                    let speed: Float = 120  // world units/sec
                    let dt = min(frameDt, 0.1)
                    // Forward = away from camera (camera looks toward target).
                    let forward = SIMD2<Float>(-sin(yaw), -cos(yaw))
                    let right = SIMD2<Float>(-forward.y, forward.x)
                    let delta = (forward * input.y + right * input.x) * speed * dt
                    target.x += delta.x
                    target.z += delta.y
                    // Keep target above terrain.
                    if let world {
                        let gy = world.worldY(forHeight: world.heightAt(x: Double(target.x), z: Double(target.z)))
                        target.y = gy + 10
                    }
                }
                let cp = cos(pitch)
                camPosition = target + SIMD3<Float>(sin(yaw) * cp, sin(pitch), cos(yaw) * cp) * distance
                camTarget = target
            }

            renderer.setCamera(position: camPosition, target: camTarget,
                               fovDegrees: 55, aspect: aspect,
                               near: 1, far: 4000)
            renderer.update(cameraTarget: SIMD2<Float>(target.x, target.z))

            var carOverlay: ((MTLRenderCommandEncoder) -> Void)?
            if carSpawned {
                let viewProj = carPerspective(fovDegrees: 55, aspect: aspect,
                                              near: 1, far: 4000)
                    * carLookAt(eye: camPosition, target: camTarget)
                let carM = carModelMatrix()
                carOverlay = { [weak self] encoder in
                    guard let self else { return }
                    self.carRenderer?.draw(encoder: encoder,
                                           viewProj: viewProj,
                                           cameraPos: camPosition,
                                           sunAzimuth: renderer.sunAzimuth,
                                           sunElevation: renderer.sunElevation,
                                           carModel: carM,
                                           wheelSpin: self.carWheelSpin,
                                           steer: self.carSteer,
                                           reflectionTex: nil)
                }
            }
            renderer.draw(in: view, overlay: carOverlay)
        }

        // MARK: - Car camera math (mirrors the library's mtPerspective/mtLookAt)

        private func carLookAt(eye: SIMD3<Float>, target: SIMD3<Float>,
                               up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> simd_float4x4 {
            let z = normalize(eye - target)
            let x = normalize(cross(up, z))
            let y = cross(z, x)
            var m = matrix_identity_float4x4
            m.columns.0 = SIMD4<Float>(x.x, y.x, z.x, 0)
            m.columns.1 = SIMD4<Float>(x.y, y.y, z.y, 0)
            m.columns.2 = SIMD4<Float>(x.z, y.z, z.z, 0)
            m.columns.3 = SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
            return m
        }

        private func carPerspective(fovDegrees: Float, aspect: Float,
                                    near: Float, far: Float) -> simd_float4x4 {
            let f: Float = 1.0 / tan(fovDegrees * .pi / 360.0)
            var m = matrix_identity_float4x4
            m.columns.0 = SIMD4<Float>(f / aspect, 0, 0, 0)
            m.columns.1 = SIMD4<Float>(0, f, 0, 0)
            m.columns.2 = SIMD4<Float>(0, 0, far / (near - far), -1)
            m.columns.3 = SIMD4<Float>(0, 0, (far * near) / (near - far), 0)
            return m
        }

        // MARK: - Gestures

        /// Single-finger drag: orbit (yaw / pitch) — or pan when the Mac
        /// drag-mode picker is set to Pan. Mouse drag on Catalyst fires this
        /// recognizer, so it doubles as the Mac orbit control.
        @objc private func handleOrbit(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            #if targetEnvironment(macCatalyst)
            if parent.dragMode == .pan {
                handlePan(g)
                return
            }
            #endif
            let t = g.translation(in: v)
            if parent.cameraMode == .walk {
                // Walk mode: drag to look around (yaw + pitch).
                walkYaw -= Float(t.x * 0.005)
                walkPitch = min(1.2, max(-1.2, walkPitch - Float(t.y * 0.005)))
            } else {
                yaw -= Float(t.x * 0.0055)
                pitch = min(1.35, max(0.08, pitch - Float(t.y * 0.0055)))
            }
            g.setTranslation(.zero, in: v)
        }

        /// Two-finger drag: pan the orbit target across the ground.
        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            let s: Float = distance * 0.0016
            let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let fwd = SIMD3<Float>(sin(yaw), 0, cos(yaw))
            target += (-Float(t.x) * right + Float(t.y) * fwd) * s
            g.setTranslation(.zero, in: v)
        }

        /// Pinch: zoom (camera distance).
        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            distance = min(1200, max(40, distance / Float(g.scale)))
            g.scale = 1
        }

        /// Double-tap: reset to the opening 3/4 aerial view.
        @objc private func handleReset(_ g: UITapGestureRecognizer) {
            yaw = -0.6
            pitch = 0.62
            distance = 340
            target = SIMD3<Float>(0, 0, 0)
        }

        #if targetEnvironment(macCatalyst)
        // MARK: - Mac keyboard controls
        // (Called by TerrainMTKView, which owns the UIResponder slot.)

        func panTarget(dx: Float, dy: Float) {
            let s: Float = distance * 0.08
            let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let fwd = SIMD3<Float>(sin(yaw), 0, cos(yaw))
            target += (dx * right + dy * fwd) * s
        }

        func keyPanUp() { panTarget(dx: 0, dy: 1) }
        func keyPanDown() { panTarget(dx: 0, dy: -1) }
        func keyPanLeft() { panTarget(dx: -1, dy: 0) }
        func keyPanRight() { panTarget(dx: 1, dy: 0) }
        func keyZoomIn() { distance = max(40, distance * 0.9) }
        func keyZoomOut() { distance = min(1200, distance * 1.1) }
        func keyResetView() {
            yaw = -0.6
            pitch = 0.62
            distance = 340
            target = SIMD3<Float>(0, 0, 0)
        }
        #endif
    }
}

// MARK: - Demo biome sets

extension TerrainView.Coordinator {
    /// Sun-baked desert: water, sand, dunes, mesa rock, pale peaks.
    static let desertBiomes: [MTBiome] = [
        MTBiome(name: "deepWater", minHeight: 0.00, maxHeight: 0.36,
                groundColor: SIMD3<Float>(0.04, 0.12, 0.30)),
        MTBiome(name: "shallowWater", minHeight: 0.36, maxHeight: 0.44,
                groundColor: SIMD3<Float>(0.08, 0.28, 0.50)),
        MTBiome(name: "sand", minHeight: 0.44, maxHeight: 0.60,
                groundColor: SIMD3<Float>(0.84, 0.68, 0.42)),
        MTBiome(name: "dunes", minHeight: 0.60, maxHeight: 0.76,
                groundColor: SIMD3<Float>(0.76, 0.57, 0.33)),
        MTBiome(name: "mesaRock", minHeight: 0.76, maxHeight: 0.88,
                groundColor: SIMD3<Float>(0.58, 0.38, 0.24),
                slopeColor: SIMD3<Float>(0.42, 0.27, 0.17)),
        MTBiome(name: "palePeak", minHeight: 0.88, maxHeight: 1.00,
                groundColor: SIMD3<Float>(0.90, 0.84, 0.70)),
    ]

    /// Alien world: dark seas, fungal plains, glowing crystal fields.
    static let alienBiomes: [MTBiome] = [
        MTBiome(name: "voidOcean", minHeight: 0.00, maxHeight: 0.38,
                groundColor: SIMD3<Float>(0.03, 0.02, 0.12)),
        MTBiome(name: "acidSea", minHeight: 0.38, maxHeight: 0.45,
                groundColor: SIMD3<Float>(0.10, 0.50, 0.30)),
        MTBiome(name: "fungusField", minHeight: 0.45, maxHeight: 0.60,
                groundColor: SIMD3<Float>(0.38, 0.14, 0.55)),
        MTBiome(name: "crystal", minHeight: 0.60, maxHeight: 0.76,
                groundColor: SIMD3<Float>(0.16, 0.62, 0.72),
                emitsLight: true),
        MTBiome(name: "voidRock", minHeight: 0.76, maxHeight: 0.88,
                groundColor: SIMD3<Float>(0.22, 0.07, 0.32),
                slopeColor: SIMD3<Float>(0.10, 0.03, 0.16)),
        MTBiome(name: "starCap", minHeight: 0.88, maxHeight: 1.00,
                groundColor: SIMD3<Float>(0.92, 0.96, 1.00),
                emitsLight: true),
    ]

    /// Dense forest: lakes, mossy shores, deep woods, pine highlands.
    /// Structures are boosted for a lived-in woodland feel.
    static let forestBiomes: [MTBiome] = [
        MTBiome(name: "lake", minHeight: 0.00, maxHeight: 0.40,
                groundColor: SIMD3<Float>(0.05, 0.25, 0.45)),
        MTBiome(name: "shore", minHeight: 0.40, maxHeight: 0.46,
                groundColor: SIMD3<Float>(0.55, 0.50, 0.35)),
        MTBiome(name: "meadow", minHeight: 0.46, maxHeight: 0.55,
                groundColor: SIMD3<Float>(0.30, 0.58, 0.22)),
        MTBiome(name: "deepWoods", minHeight: 0.55, maxHeight: 0.70,
                groundColor: SIMD3<Float>(0.10, 0.35, 0.10)),
        MTBiome(name: "pineHighland", minHeight: 0.70, maxHeight: 0.85,
                groundColor: SIMD3<Float>(0.16, 0.30, 0.16),
                slopeColor: SIMD3<Float>(0.35, 0.32, 0.28)),
        MTBiome(name: "mistyPeak", minHeight: 0.85, maxHeight: 1.00,
                groundColor: SIMD3<Float>(0.75, 0.78, 0.80)),
    ]
}
