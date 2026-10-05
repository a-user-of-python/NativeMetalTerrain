import SwiftUI
import MetalTerrain

/// Root view: full-screen terrain with an overlay control panel.
/// Portrait -> panel docks at the bottom. Landscape -> panel docks on the right.
struct ContentView: View {
    @State private var seedText = "1337"
    @State private var seed: UInt64 = 1337
    @State private var rebuildToken = 0
    @State private var lastRegenerateTime: Double = 0
    @State private var preset: BiomePreset = .default
    @State private var structuresEnabled = true
    @State private var wireframe = false
    @State private var showsWater = true
    @State private var fogEnabled = true
    @State private var viewDistance = 6
    @State private var cameraMode: CameraMode = .walk
    @State private var playerHeight: Float = 2
    @State private var moveInput = SIMD2<Float>(0, 0)
    @State private var fps: Double = 0
    // Renderer ref for direct sun updates (bypasses SwiftUI re-render).
    @State private var terrainRenderer: MTTerrainRenderer?
    /// Polls renderer.currentFPS 2x/sec (avoids render-loop @State writes).
    private let fpsTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var shaderEffectsEnabled = true
    @State private var usesMetal4 = false
    @State private var panelVisible = true
    @State private var dragMode: DragMode = .orbit
    /// Debug car (separate debug panel, app-only).
    @State private var carActive = false
    /// Simulator mode: auto-enabled in Xcode Simulator, toggleable in Debug.
    @State private var simulatorMode = MTTerrainConfig.isSimulator

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                TerrainView(
                    seed: $seed,
                    rebuildToken: $rebuildToken,
                    preset: $preset,
                    structuresEnabled: $structuresEnabled,
                    wireframe: $wireframe,
                    showsWater: $showsWater,
                    fogEnabled: $fogEnabled,
                    viewDistance: $viewDistance,
                    shaderEffectsEnabled: $shaderEffectsEnabled,
                    dragMode: $dragMode,
                    cameraMode: $cameraMode,
                    playerHeight: $playerHeight,
                    moveInput: $moveInput,
                    carActive: $carActive,
                    simulatorMode: $simulatorMode,
                    onRendererReady: { renderer in
                        // Dispatch async: setting @State during updateUIView
                        // triggers "modifying state during view update".
                        DispatchQueue.main.async {
                            terrainRenderer = renderer
                            usesMetal4 = renderer.usesMetal4
                        }
                    }
                )
                .ignoresSafeArea()
                .onReceive(fpsTimer) { _ in
                    // Poll from timer (not render loop) to avoid
                    // "modifying state during view update".
                    if let r = terrainRenderer { fps = r.currentFPS }
                }

                // Show/hide button (top-right, always reachable)
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { panelVisible.toggle() }) {
                            Text(panelVisible ? "Hide Controls" : "Show Controls")
                                .font(.title3)
                                .bold()
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                        }
                        .background(Color.black.opacity(0.78))
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .padding()
                    Spacer()
                }

                // Control panel
                if panelVisible {
                    if isLandscape {
                        HStack {
                            Spacer()
                            ScrollView {
                                panel
                                    .frame(width: 280)
                            }
                            .frame(maxHeight: geo.size.height * 0.85)
                            .padding(.vertical, 8)
                        }
                        .padding(.trailing, 8)
                    } else {
                        VStack {
                            Spacer()
                            panel
                        }
                        .padding(8)
                    }
                }

                // Debug panel (top-left, separate from control panel)
                VStack {
                    HStack {
                        DebugPanel(carActive: $carActive, simulatorMode: $simulatorMode)
                            .frame(width: 230)
                            .padding(.leading, 12)
                            .padding(.top, 12)
                        Spacer()
                    }
                    Spacer()
                }

                // Joystick (bottom-left): walk mode moves the player,
                // orbit mode moves the camera target, car mode drives.
                VStack {
                    Spacer()
                    HStack {
                        JoystickView(input: $moveInput)
                            .frame(width: 140, height: 140)
                            .padding(.leading, 24)
                            .padding(.bottom, 24)
                            Spacer()
                        }
                }
            }
        }
    }

    private var panel: some View {
        ControlPanel(
            seedText: $seedText,
            preset: $preset,
            structuresEnabled: $structuresEnabled,
            wireframe: $wireframe,
            showsWater: $showsWater,
            fogEnabled: $fogEnabled,
            viewDistance: $viewDistance,
            cameraMode: $cameraMode,
            playerHeight: $playerHeight,
            onSunChange: { az, el in
                // Direct to renderer: no SwiftUI re-render, no frame dip.
                terrainRenderer?.sunAzimuth = az
                terrainRenderer?.sunElevation = el
            },
            shaderEffectsEnabled: $shaderEffectsEnabled,
            usesMetal4: usesMetal4,
            fps: fps,
            dragMode: $dragMode,
            onRegenerate: regenerate,
            onCloneWorld: cloneWorld
        )
    }

    /// Copies the current seed into the seed field so the user can tweak
    /// and regenerate a variation, or re-enter it later to revisit.
    private func cloneWorld() {
        seedText = String(seed)
    }

    /// Applies the seed field (or a random seed when it is blank/invalid)
    /// and forces a full world rebuild. Debounced: ignores rapid clicks
    /// (prevents crash from queuing 500+ chunk builds).
    private func regenerate() {
        let now = Date().timeIntervalSince1970
        guard now - lastRegenerateTime > 1.5 else { return }
        lastRegenerateTime = now
        let trimmed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = UInt64(trimmed), !trimmed.isEmpty {
            seed = value
        } else {
            let value = UInt64.random(in: 1 ... 999_999)
            seed = value
            seedText = String(value)
        }
        rebuildToken += 1
    }
}
