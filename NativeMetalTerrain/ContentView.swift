import SwiftUI
import MetalTerrain

/// Root view: full-screen terrain with an overlay control panel.
/// Portrait -> panel docks at the bottom. Landscape -> panel docks on the right.
struct ContentView: View {
    /// Preset selected from the main menu (nil = default).
    var initialPreset: BiomePreset? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var seedText = "1337"
    @State private var seed: UInt64 = 1337
    @State private var rebuildToken = 0
    /// v1.3.0: lava death — big "YOU DIED" banner + volcano-safe respawn.
    @State private var showDiedBanner = false
    @State private var avoidVolcanoes = false
    @State private var lastRegenerateTime: Double = 0
    @State private var preset: BiomePreset = .default
    @State private var structuresEnabled = true
    @State private var wireframe = false
    @State private var showsWater = true
    @State private var fogEnabled = true
    /// v1.0.0: persistent config modified by commands. When set, rebuildWorld
    /// uses this instead of the default base config, so command changes survive.
    @State private var commandConfig: MTTerrainConfig? = nil
    @State private var viewDistance = 6
    @State private var cameraMode: CameraMode = .walk
    @State private var playerHeight: Float = 2
    @State private var moveInput = SIMD2<Float>(0, 0)
    @State private var fps: Double = 0
    // Renderer ref for direct sun updates (bypasses SwiftUI re-render).
    @State private var terrainRenderer: MTTerrainRenderer?
    /// v1.0.14: holds renderer-only settings from a loaded saved world until
    /// the fresh renderer is created (applied in onRendererReady).
    @State private var pendingSavedRenderer: SavedWorld?
    /// The rebuildToken value the pending settings belong to. Guards against
    /// a race where the initial pre-load rebuild's onRendererReady fires after
    /// the load path ran (its async block must not consume the settings).
    @State private var pendingRendererToken: Int?
    /// v1.1.1: renderer-only settings held in @State so sliders update the UI
    /// (mutating a class property doesn't trigger SwiftUI re-render) and
    /// survive rebuilds (applied to each new renderer in onRendererReady).
    @State private var sunAzimuthState: Float = 45
    @State private var sunElevationState: Float = 50
    @State private var waterDeepColorState = SIMD3<Float>(0.01, 0.22, 0.35)
    @State private var waterShallowColorState = SIMD3<Float>(0.15, 0.55, 0.65)
    @State private var waveSpeedState: Float = 1.0
    @State private var waveAmplitudeState: Float = 1.0
    @State private var waterOpacityState: Float = 0.82
    @State private var skyboxEnabledState = true
    @State private var detailAmountState: Float = 1.0
    @State private var timeOfDayState: Float = 12
    @State private var timeOfDayEnabledState = false
    @State private var timeOfDaySpeedState: Float = 1.0
    @State private var cloudAmountState: Float = 0.4
    @State private var starsEnabledState = true
    /// Polls renderer.currentFPS 2x/sec (avoids render-loop @State writes).
    private let fpsTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var shaderEffectsEnabled = true
    @State private var usesMetal4 = false
    /// v1.0.1: stats overlay (RAM/CPU/GPU) toggleable via `stats` command.
    @State private var showStats = false
    @State private var ramMB: Double = 0
    @State private var cpuPercent: Double = 0
    @State private var gpuMB: Double = 0
    /// v1.2.1: stats overlay toggles (synced from Settings).
    @AppStorage("showCPU") private var showCPU = false
    @AppStorage("showGPU") private var showGPU = false
    @AppStorage("showMemory") private var showMemory = false
    @AppStorage("showFPSGraph") private var showFPSGraph = false
    @State private var panelVisible = true
    @State private var dragMode: DragMode = .orbit
    /// Debug car (separate debug panel, app-only).
    @State private var carActive = false
    /// Simulator mode: auto-enabled in Xcode Simulator, toggleable in Debug.
    @State private var simulatorMode = MTTerrainConfig.isSimulator
    /// v1.2.0: uncapped FPS (synced from Settings via AppStorage).
    @AppStorage("uncappedFPS") private var uncappedFPS = false
    /// v1.0.0: command UI mode. When false, shows command bar. When true
    /// (via /devtools), shows the classic button panels.
    /// v1.0.4: command bar replaced by control shelf (sliders).
    @State private var devtoolsMode = false
    @State private var showShelf = false
    @StateObject private var savedWorlds = SavedWorldsStore()
    @State private var saveName = ""
    @State private var showSaveDialog = false
    /// v1.0.4: control shelf (replaces command bar).
    @State private var shelfConfig: MTTerrainConfig = .auto
    @State private var shelfInitialized = false
    /// Command bar state (deprecated in v1.0.4, kept for compatibility).
    @State private var commandExpanded = false
    @State private var commandText = ""
    @State private var outputMessage: String? = nil
    @State private var outputIsError = false

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
                    commandConfig: $commandConfig,
                    metalPreference: metalPreferenceBinding,
                    dragMode: $dragMode,
                    cameraMode: $cameraMode,
                    playerHeight: $playerHeight,
                    moveInput: $moveInput,
                    carActive: $carActive,
                    simulatorMode: $simulatorMode,
                    uncappedFPS: $uncappedFPS,
                    onRendererReady: { renderer in
                        // Capture synchronously: this closure was created during
                        // the body evaluation whose rebuildToken value triggered
                        // this rebuild, so tokenAtBuild identifies this renderer.
                        let tokenAtBuild = rebuildToken
                        // Dispatch async: setting @State during updateUIView
                        // triggers "modifying state during view update".
                        DispatchQueue.main.async {
                            terrainRenderer = renderer
                            usesMetal4 = renderer.usesMetal4
                            // v1.0.14: apply renderer-only settings from a loaded
                            // saved world (config fields were already set on the
                            // MTTerrainConfig before the rebuild). Only the
                            // renderer built for the load's token consumes them —
                            // an earlier pre-load rebuild must not steal them.
                            if let saved = pendingSavedRenderer,
                               let pendingToken = pendingRendererToken,
                               tokenAtBuild == pendingToken {
                                pendingSavedRenderer = nil
                                pendingRendererToken = nil
                                // Time-of-day first: setting it while disabled
                                // just stores the clock value.
                                renderer.timeOfDay = saved.timeOfDay ?? 12
                                renderer.timeOfDaySpeed = saved.timeOfDaySpeed ?? 1.0
                                // Manual sun position (overridden below if
                                // time animation is enabled).
                                renderer.sunAzimuth = saved.sunAzimuth ?? 45
                                renderer.sunElevation = saved.sunElevation ?? 50
                                // Enable last: triggers applyTimeOfDay() which
                                // recomputes sun position from the clock.
                                renderer.timeOfDayEnabled = saved.timeOfDayEnabled ?? false
                                if saved.skyboxEnabled ?? true {
                                    renderer.enableSkybox()
                                } else {
                                    renderer.skybox = nil
                                }
                                renderer.detailAmount = saved.detailAmount ?? 1.0
                                renderer.cloudAmount = saved.cloudAmount ?? 0.4
                                renderer.starsEnabled = saved.starsEnabled ?? true
                                // v1.1.1: sync @State with loaded values
                                sunAzimuthState = saved.sunAzimuth ?? 45
                                sunElevationState = saved.sunElevation ?? 50
                                timeOfDayState = saved.timeOfDay ?? 12
                                timeOfDaySpeedState = saved.timeOfDaySpeed ?? 1.0
                                timeOfDayEnabledState = saved.timeOfDayEnabled ?? false
                                skyboxEnabledState = saved.skyboxEnabled ?? true
                                detailAmountState = saved.detailAmount ?? 1.0
                                cloudAmountState = saved.cloudAmount ?? 0.4
                                starsEnabledState = saved.starsEnabled ?? true
                                waveSpeedState = saved.waveSpeed ?? 1.0
                                waveAmplitudeState = saved.waveAmplitude ?? 1.0
                                waterOpacityState = saved.waterOpacity ?? 0.82
                                waterDeepColorState = SIMD3<Float>(
                                    saved.waterDeepR ?? 0.01,
                                    saved.waterDeepG ?? 0.22,
                                    saved.waterDeepB ?? 0.35)
                                waterShallowColorState = SIMD3<Float>(
                                    saved.waterShallowR ?? 0.15,
                                    saved.waterShallowG ?? 0.55,
                                    saved.waterShallowB ?? 0.65)
                            }
                            // v1.1.1: apply @State values to every new renderer
                            // (survives rebuilds; fixes Done reverting to defaults).
                            renderer.sunAzimuth = sunAzimuthState
                            renderer.sunElevation = sunElevationState
                            renderer.waterDeepColor = waterDeepColorState
                            renderer.waterShallowColor = waterShallowColorState
                            renderer.waveSpeed = waveSpeedState
                            renderer.waveAmplitude = waveAmplitudeState
                            renderer.waterOpacity = waterOpacityState
                            renderer.detailAmount = detailAmountState
                            renderer.cloudAmount = cloudAmountState
                            renderer.starsEnabled = starsEnabledState
                            // Time-of-day: set clock/speed first, then enabled
                            // last (its didSet recomputes sun position).
                            renderer.timeOfDay = timeOfDayState
                            renderer.timeOfDaySpeed = timeOfDaySpeedState
                            renderer.timeOfDayEnabled = timeOfDayEnabledState
                            if skyboxEnabledState {
                                renderer.enableSkybox()
                            } else {
                                renderer.skybox = nil
                            }
                        }
                    },
                    avoidVolcanoesOnSpawn: avoidVolcanoes,
                    onPlayerDeath: { handlePlayerDeath() }
                )
                .ignoresSafeArea()
                .onAppear {
                    // Apply preset from main menu
                    if let p = initialPreset {
                        preset = p
                    }
                    // Check for pending saved world to load
                    if let data = UserDefaults.standard.data(forKey: "pendingSavedWorld"),
                       let saved = try? JSONDecoder().decode(SavedWorld.self, from: data) {
                        // Clear the pending flag
                        UserDefaults.standard.removeObject(forKey: "pendingSavedWorld")
                        UserDefaults.standard.removeObject(forKey: "pendingPreset")
                        UserDefaults.standard.removeObject(forKey: "pendingSeed")
                        // Apply saved values
                        seed = saved.seed
                        seedText = String(saved.seed)
                        preset = saved.preset
                        viewDistance = saved.viewDistance
                        // Build config from saved values
                        var cfg = MTTerrainConfig()
                        cfg.chunkWorldSize = saved.chunkWorldSize
                        cfg.chunkResolution = saved.chunkResolution
                        cfg.seaLevel = saved.seaLevel
                        cfg.heightScale = saved.heightScale
                        cfg.noise.octaves = saved.octaves
                        cfg.noise.baseFrequency = saved.frequency
                        cfg.noise.amplitude = saved.amplitude
                        cfg.noise.lacunarity = saved.lacunarity
                        cfg.noise.gain = saved.gain
                        cfg.noise.warpStrength = saved.warpStrength
                        cfg.noise.warpFrequency = saved.warpFrequency
                        cfg.noise.ridged = saved.ridged
                        cfg.structureNoise.octaves = saved.structOctaves
                        cfg.structureNoise.baseFrequency = saved.structFrequency
                        cfg.structureNoise.amplitude = saved.structAmplitude
                        cfg.structureNoise.lacunarity = saved.structLacunarity
                        cfg.structureNoise.gain = saved.structGain
                        cfg.structureNoise.warpStrength = saved.structWarpStrength
                        cfg.structureNoise.warpFrequency = saved.structWarpFrequency
                        cfg.structureNoise.ridged = saved.structRidged
                        cfg.structureDensity = saved.structureDensity
                        cfg.structuresEnabled = saved.structuresEnabled
                        cfg.fogDensity = saved.fogDensity
                        cfg.ambientIntensity = saved.ambientIntensity
                        cfg.sunIntensity = saved.sunIntensity
                        cfg.continentScale = saved.continentScale
                        cfg.riverScale = saved.riverScale
                        cfg.mountainSharpness = saved.mountainSharpness
                        // v1.0.11+: water + per-structure weights are config
                        // fields — the new renderer picks them up at init.
                        // Missing keys (old saves) fall back to defaults.
                        cfg.structureKindWeights = saved.structureKindWeights ?? [:]
                        cfg.waveSpeed = saved.waveSpeed ?? 1.0
                        cfg.waveAmplitude = saved.waveAmplitude ?? 1.0
                        cfg.waterOpacity = saved.waterOpacity ?? 0.82
                        cfg.waterDeepColor = SIMD3<Float>(
                            saved.waterDeepR ?? 0.01,
                            saved.waterDeepG ?? 0.22,
                            saved.waterDeepB ?? 0.35)
                        cfg.waterShallowColor = SIMD3<Float>(
                            saved.waterShallowR ?? 0.15,
                            saved.waterShallowG ?? 0.55,
                            saved.waterShallowB ?? 0.65)
                        commandConfig = cfg
                        shelfConfig = cfg
                        shelfInitialized = true
                        // Renderer-only settings (sun, skybox, time-of-day,
                        // clouds, stars, detail) are applied in onRendererReady
                        // once the fresh renderer exists. Tag them with the new
                        // token so a stale pre-load rebuild can't consume them.
                        rebuildToken += 1
                        pendingSavedRenderer = saved
                        pendingRendererToken = rebuildToken
                    }
                }
                .onReceive(fpsTimer) { _ in
                    // Poll from timer (not render loop) to avoid
                    // "modifying state during view update".
                    if let r = terrainRenderer { fps = r.currentFPS }
                    // v1.2.1: stats polled when any overlay is enabled.
                    if showStats || showCPU || showGPU || showMemory || showFPSGraph {
                        ramMB = Self.appMemoryMB()
                        cpuPercent = Self.appCPUPercent()
                        if let r = terrainRenderer {
                            gpuMB = r.gpuAllocatedMB
                        }
                    }
                }

                // v1.0.0: command bar mode (default). Devtools mode shows classic UI.
                // (Menu button removed in v1.0.9 — use the navigation back button.)

                // v1.0.4: control shelf toggle (replaces command bar)
                if !devtoolsMode {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button(action: {
                                // Initialize shelf config from current world
                                if let world = terrainRenderer?.world, !shelfInitialized {
                                    shelfConfig = world.config
                                    shelfInitialized = true
                                }
                                showShelf = true
                            }) {
                                Text("🎛 Controls")
                                    .font(.largeTitle)
                                    .bold()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 16)
                                    .background(Color.green.opacity(0.85))
                                    .cornerRadius(16)
                            }
                        }
                        .padding()
                    }
                    .sheet(isPresented: $showShelf) {
                        NavigationStack {
                            ControlShelf(
                                config: $shelfConfig,
                                seedText: $seedText,
                                onSeedApply: {
                                    if let v = UInt64(seedText.trimmingCharacters(in: .whitespaces)) {
                                        seed = v
                                        rebuildToken += 1
                                    }
                                },
                                onRandomSeed: {
                                    let v = UInt64.random(in: 1...999999)
                                    seed = v
                                    seedText = String(v)
                                    rebuildToken += 1
                                },
                                onSaveWorld: { showSaveDialog = true },
                                wireframe: $wireframe,
                                showsWater: $showsWater,
                                fogEnabled: $fogEnabled,
                                shaderEffectsEnabled: $shaderEffectsEnabled,
                                viewDistance: $viewDistance,
                                sunAzimuth: Binding(
                                    get: { sunAzimuthState },
                                    set: { sunAzimuthState = $0; terrainRenderer?.sunAzimuth = $0 }
                                ),
                                sunElevation: Binding(
                                    get: { sunElevationState },
                                    set: { sunElevationState = $0; terrainRenderer?.sunElevation = $0 }
                                ),
                                skyboxEnabled: Binding(
                                    get: { skyboxEnabledState },
                                    set: { newValue in
                                        skyboxEnabledState = newValue
                                        if newValue {
                                            terrainRenderer?.enableSkybox()
                                        } else {
                                            terrainRenderer?.skybox = nil
                                        }
                                    }
                                ),
                                detailAmount: Binding(
                                    get: { detailAmountState },
                                    set: { detailAmountState = $0; terrainRenderer?.detailAmount = $0 }
                                ),
                                waveSpeed: Binding(
                                    get: { waveSpeedState },
                                    set: { waveSpeedState = $0; terrainRenderer?.waveSpeed = $0 }
                                ),
                                waveAmplitude: Binding(
                                    get: { waveAmplitudeState },
                                    set: { waveAmplitudeState = $0; terrainRenderer?.waveAmplitude = $0 }
                                ),
                                waterOpacity: Binding(
                                    get: { waterOpacityState },
                                    set: { waterOpacityState = $0; terrainRenderer?.waterOpacity = $0 }
                                ),
                                waterDeepColor: Binding(
                                    get: { waterDeepColorState },
                                    set: { waterDeepColorState = $0; terrainRenderer?.waterDeepColor = $0 }
                                ),
                                waterShallowColor: Binding(
                                    get: { waterShallowColorState },
                                    set: { waterShallowColorState = $0; terrainRenderer?.waterShallowColor = $0 }
                                ),
                                timeOfDay: Binding(
                                    get: { timeOfDayState },
                                    set: { timeOfDayState = $0; terrainRenderer?.timeOfDay = $0 }
                                ),
                                timeOfDayEnabled: Binding(
                                    get: { timeOfDayEnabledState },
                                    set: { timeOfDayEnabledState = $0; terrainRenderer?.timeOfDayEnabled = $0 }
                                ),
                                timeOfDaySpeed: Binding(
                                    get: { timeOfDaySpeedState },
                                    set: { timeOfDaySpeedState = $0; terrainRenderer?.timeOfDaySpeed = $0 }
                                ),
                                cloudAmount: Binding(
                                    get: { cloudAmountState },
                                    set: { cloudAmountState = $0; terrainRenderer?.cloudAmount = $0 }
                                ),
                                starsEnabled: Binding(
                                    get: { starsEnabledState },
                                    set: { starsEnabledState = $0; terrainRenderer?.starsEnabled = $0 }
                                ),
                                structureKindWeights: Binding(
                                    get: { shelfConfig.structureKindWeights },
                                    set: {
                                        shelfConfig.structureKindWeights = $0
                                        // Structure weights require rebuild (they affect placement)
                                    }
                                )
                            )
                            .navigationTitle("Controls")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        // Push config to world and rebuild
                                        commandConfig = shelfConfig
                                        shelfInitialized = false  // Re-init next open
                                        rebuildToken += 1
                                        showShelf = false
                                    }
                                    .font(.title2).bold()
                                }
                            }
                        }
                    }
                    .alert("Save World", isPresented: $showSaveDialog) {
                        TextField("Name", text: $saveName)
                        Button("Save") {
                            saveCurrentWorld(name: saveName.isEmpty ? "World \(savedWorlds.worlds.count + 1)" : saveName)
                            saveName = ""
                        }
                        Button("Cancel", role: .cancel) { saveName = "" }
                    }
                }

                // v1.2.1: stats overlay with graphs (Settings toggles).
                // Legacy `stats` command still works via showStats.
                if showStats || showCPU || showGPU || showMemory || showFPSGraph {
                    StatsOverlay(
                        cpuPercent: cpuPercent,
                        gpuMB: gpuMB,
                        ramMB: ramMB,
                        fps: fps
                    )
                }

                // v1.3.0: lava death banner — huge type, high contrast.
                if showDiedBanner {
                    VStack {
                        Spacer()
                        Text("YOU DIED")
                            .font(.system(size: 72, weight: .black))
                            .foregroundColor(.red)
                            .shadow(color: .black, radius: 8)
                        Text("The lava got you — new world, safe spawn")
                            .font(.title)
                            .bold()
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 6)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.45))
                    .allowsHitTesting(false)
                }

                // Classic UI (devtools mode via /devtools command)
                if devtoolsMode {
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
                } // end devtoolsMode

                // Joystick (bottom-left): always visible
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

    /// Execute a command string. Shows output briefly.
    private func executeCommand(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Clear previous output
        outputMessage = nil

        // Special: /devtools toggles the classic UI
        if trimmed.lowercased() == "/devtools" {
            devtoolsMode.toggle()
            showOutput(devtoolsMode ? "devtools enabled" : "devtools disabled", isError: false)
            commandText = ""
            commandExpanded = false
            return
        }

        // Special: reset restores factory defaults (seed 1337, default config)
        if trimmed.lowercased() == "reset" {
            commandConfig = nil
            seed = 1337
            seedText = "1337"
            preset = .default
            rebuildToken += 1
            showOutput("reset to defaults", isError: false)
            commandText = ""
            commandExpanded = false
            return
        }

        // Special: stats toggles the RAM/CPU/GPU overlay
        if trimmed.lowercased().hasPrefix("stats") {
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2 {
                switch parts[1].lowercased() {
                case "on":
                    showStats = true
                    showOutput("stats on", isError: false)
                case "off":
                    showStats = false
                    showOutput("stats off", isError: false)
                default:
                    showOutput("syntax error: usage: stats <on|off>", isError: true)
                }
            } else {
                showOutput("syntax error: usage: stats <on|off>", isError: true)
            }
            commandText = ""
            commandExpanded = false
            return
        }

        // Parse: first word is command name, rest are args
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let cmdName = parts.first else { return }
        let args = parts.dropFirst().map(String.init)

        guard let cmd = CommandRegistry.find(String(cmdName)) else {
            showOutput("syntax error: unknown command '\(cmdName)'", isError: true)
            return
        }

        // Capture current values for the context (struct-safe, no weak needed)
        let renderer = terrainRenderer
        let ctx = CommandContext(
            getWorld: { renderer?.world },
            getRenderer: { renderer },
            onWorldRebuild: {
                // Config changes bump configVersion which the renderer detects.
                // For seed changes, we need to trigger via the renderer.
                // The world.config setter already handles most cases.
            }
        )

        let result = cmd.handler(args, ctx)
        switch result {
        case .success(let msg):
            showOutput(msg, isError: false)
            // Commands that modify world terrain/noise config need a full
            // world rebuild to take effect. Renderer-only commands (colors,
            // wireframe, sun, etc.) apply immediately without rebuild.
            //
            // CRITICAL: The rebuild creates a new world from scratch, so we
            // must persist the modified config/seed in State BEFORE bumping
            // the token, otherwise the changes are lost.
            let worldModifying: Set<String> = [
                "seed", "chunksize", "chunkresolution", "sealevel",
                "heightscale", "mountainmax", "octaves", "frequency",
                "amplitude", "lacunarity", "gain", "warpstrength",
                "warpfrequency", "ridged", "structures", "structuredensity",
                "structoctaves", "structfrequency", "structamplitude",
                "structlacunarity", "structgain", "structwarpstrength",
                "structwarpfrequency", "structridged"
            ]
            if worldModifying.contains(cmd.name) {
                // Persist the modified config so rebuildWorld uses it
                if let world = ctx.getWorld() {
                    commandConfig = world.config
                }
                // Persist seed change in State (rebuildWorld uses parent.seed)
                if cmd.name == "seed", let world = ctx.getWorld() {
                    seed = world.seed
                    seedText = String(world.seed)
                }
                rebuildToken += 1
            }
        case .error(let msg):
            showOutput(msg, isError: true)
        }
        commandText = ""
        // v1.0.1: collapse back to the command button after running
        commandExpanded = false
    }

    /// Show output message briefly. Tap to dismiss, or it clears on next command.
    /// (Auto-dismiss via timer doesn't work in a struct; manual dismiss is reliable.)
    private func showOutput(_ msg: String, isError: Bool) {
        outputMessage = msg
        outputIsError = isError
    }

    /// v1.3.0: lava death — new random seed, respawn away from volcanoes,
    /// big banner (large type for visibility).
    private func handlePlayerDeath() {
        showDiedBanner = true
        let newSeed = UInt64.random(in: 1...UInt64.max)
        seed = newSeed
        seedText = String(newSeed)
        avoidVolcanoes = true
        rebuildToken += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            showDiedBanner = false
            avoidVolcanoes = false
        }
    }

    /// Save the current world (seed + preset + config) to the store.
    private func saveCurrentWorld(name: String) {
        let cfg = shelfInitialized ? shelfConfig : (terrainRenderer?.world.config ?? .auto)
        let r = terrainRenderer
        let deepColor = r?.waterDeepColor ?? cfg.waterDeepColor
        let shallowColor = r?.waterShallowColor ?? cfg.waterShallowColor
        let world = SavedWorld(
            name: name,
            seed: seed,
            presetRaw: preset.rawValue,
            chunkWorldSize: cfg.chunkWorldSize,
            chunkResolution: cfg.chunkResolution,
            seaLevel: cfg.seaLevel,
            heightScale: cfg.heightScale,
            viewDistance: viewDistance,
            octaves: cfg.noise.octaves,
            frequency: cfg.noise.baseFrequency,
            amplitude: cfg.noise.amplitude,
            lacunarity: cfg.noise.lacunarity,
            gain: cfg.noise.gain,
            warpStrength: cfg.noise.warpStrength,
            warpFrequency: cfg.noise.warpFrequency,
            ridged: cfg.noise.ridged,
            structOctaves: cfg.structureNoise.octaves,
            structFrequency: cfg.structureNoise.baseFrequency,
            structAmplitude: cfg.structureNoise.amplitude,
            structLacunarity: cfg.structureNoise.lacunarity,
            structGain: cfg.structureNoise.gain,
            structWarpStrength: cfg.structureNoise.warpStrength,
            structWarpFrequency: cfg.structureNoise.warpFrequency,
            structRidged: cfg.structureNoise.ridged,
            structureDensity: cfg.structureDensity,
            structuresEnabled: cfg.structuresEnabled,
            fogDensity: cfg.fogDensity,
            ambientIntensity: cfg.ambientIntensity,
            sunIntensity: cfg.sunIntensity,
            continentScale: cfg.continentScale,
            riverScale: cfg.riverScale,
            mountainSharpness: cfg.mountainSharpness,
            // v1.0.11+: renderer is the live source; fall back to config.
            waveSpeed: r?.waveSpeed ?? cfg.waveSpeed,
            waveAmplitude: r?.waveAmplitude ?? cfg.waveAmplitude,
            waterOpacity: r?.waterOpacity ?? cfg.waterOpacity,
            waterDeepR: deepColor.x,
            waterDeepG: deepColor.y,
            waterDeepB: deepColor.z,
            waterShallowR: shallowColor.x,
            waterShallowG: shallowColor.y,
            waterShallowB: shallowColor.z,
            sunAzimuth: r?.sunAzimuth ?? 45,
            sunElevation: r?.sunElevation ?? 50,
            skyboxEnabled: r.map { $0.skybox != nil } ?? true,
            detailAmount: r?.detailAmount ?? 1.0,
            // v1.0.12+
            timeOfDay: r?.timeOfDay ?? 12,
            timeOfDayEnabled: r?.timeOfDayEnabled ?? false,
            timeOfDaySpeed: r?.timeOfDaySpeed ?? 1.0,
            // v1.0.13+
            cloudAmount: r?.cloudAmount ?? 0.4,
            starsEnabled: r?.starsEnabled ?? true,
            structureKindWeights: cfg.structureKindWeights
        )
        savedWorlds.save(world)
    }

    /// Reads the Metal preference from UserDefaults (set in Settings).
    private var metalPreferenceBinding: Binding<MetalPreference> {
        Binding(
            get: {
                let raw = UserDefaults.standard.string(forKey: "metalPreference") ?? "Auto"
                return MetalPreference(rawValue: raw) ?? .auto
            },
            set: { _ in }  // Read-only here; Settings view writes it
        )
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

    /// App memory usage in MB (via mach task info).
    static func appMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_000_000
    }

    /// App CPU usage as percentage (via thread info).
    static func appCPUPercent() -> Double {
        var threads: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS,
              let threadList = threads else { return 0 }
        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_act_t>.size))
        return total
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

/// v1.2.1: Performance stats overlay with live graphs.
/// Shows CPU, GPU, Memory, Wattage, and FPS with history graphs.
struct StatsOverlay: View {
    @AppStorage("showCPU") private var showCPU = false
    @AppStorage("showGPU") private var showGPU = false
    @AppStorage("showMemory") private var showMemory = false
    @AppStorage("showFPSGraph") private var showFPSGraph = false

    let cpuPercent: Double
    let gpuMB: Double
    let ramMB: Double
    let fps: Double

    // History for graphs (last 60 samples = 30 seconds at 2Hz)
    @State private var cpuHistory: [Double] = []
    @State private var gpuHistory: [Double] = []
    @State private var ramHistory: [Double] = []
    @State private var fpsHistory: [Double] = []

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    if showCPU {
                        StatRow(label: "CPU", value: String(format: "%.0f%%", cpuPercent),
                                history: cpuHistory, color: .green, max: 100)
                    }
                    if showGPU {
                        StatRow(label: "GPU", value: String(format: "%.0f MB", gpuMB),
                                history: gpuHistory, color: .blue, max: 4000)
                    }
                    if showMemory {
                        StatRow(label: "RAM", value: String(format: "%.0f MB", ramMB),
                                history: ramHistory, color: .orange, max: 4000)
                    }
                    if showFPSGraph {
                        StatRow(label: "FPS", value: String(format: "%.0f", fps),
                                history: fpsHistory, color: .purple, max: 120)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                Spacer()
            }
            .padding(.top, 50)
            .padding(.leading, 12)
            Spacer()
        }
        .onChange(of: cpuPercent) { _ in updateHistory() }
    }

    private func updateHistory() {
        cpuHistory.append(cpuPercent)
        gpuHistory.append(gpuMB)
        ramHistory.append(ramMB)
        fpsHistory.append(fps)
        let maxCount = 60
        if cpuHistory.count > maxCount {
            cpuHistory.removeFirst()
            gpuHistory.removeFirst()
            ramHistory.removeFirst()
            fpsHistory.removeFirst()
        }
    }
}

/// Single stat row with label, value, and mini graph.
struct StatRow: View {
    let label: String
    let value: String
    let history: [Double]
    let color: Color
    let max: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.headline)
                    .foregroundColor(color)
                Spacer()
                Text(value)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            // Mini graph
            GeometryReader { geo in
                Path { path in
                    guard history.count > 1 else { return }
                    let w = geo.size.width
                    let h = geo.size.height
                    let stepX = w / CGFloat(Swift.max(history.count - 1, 1))
                    for (i, val) in history.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = h - (CGFloat(min(val, max)) / CGFloat(max)) * h
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 2)
            }
            .frame(height: 30)
        }
        .frame(width: 200)
    }
}
