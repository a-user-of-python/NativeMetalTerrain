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
    /// Polls renderer.currentFPS 2x/sec (avoids render-loop @State writes).
    private let fpsTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var shaderEffectsEnabled = true
    @State private var usesMetal4 = false
    /// v1.0.1: stats overlay (RAM/CPU/GPU) toggleable via `stats` command.
    @State private var showStats = false
    @State private var ramMB: Double = 0
    @State private var cpuPercent: Double = 0
    @State private var gpuMB: Double = 0
    @State private var panelVisible = true
    @State private var dragMode: DragMode = .orbit
    /// Debug car (separate debug panel, app-only).
    @State private var carActive = false
    /// Simulator mode: auto-enabled in Xcode Simulator, toggleable in Debug.
    @State private var simulatorMode = MTTerrainConfig.isSimulator
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
                            // Apply Metal version preference from settings
                            let pref = UserDefaults.standard.string(forKey: "metalPreference") ?? "Auto"
                            switch pref {
                            case "Metal 3":
                                renderer.metalVersionOverride = .metal3
                            case "Metal 4":
                                renderer.metalVersionOverride = .metal4
                            default:
                                renderer.metalVersionOverride = nil
                            }
                            // Rebuild pipelines with the override
                            rebuildToken += 1
                        }
                    }
                )
                .ignoresSafeArea()
                .onAppear {
                    // Apply preset from main menu
                    if let p = initialPreset {
                        preset = p
                    }
                }
                .onReceive(fpsTimer) { _ in
                    // Poll from timer (not render loop) to avoid
                    // "modifying state during view update".
                    if let r = terrainRenderer { fps = r.currentFPS }
                    if showStats {
                        ramMB = Self.appMemoryMB()
                        cpuPercent = Self.appCPUPercent()
                        if let r = terrainRenderer {
                            gpuMB = r.gpuAllocatedMB
                        }
                    }
                }

                // v1.0.0: command bar mode (default). Devtools mode shows classic UI.
                // Menu button (top-left, back to main menu)
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Text("☰ Menu")
                                .font(.title2)
                                .bold()
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(10)
                        }
                        .padding(.top, 50)
                        .padding(.leading, 12)
                        Spacer()
                    }
                    Spacer()
                }

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
                                viewDistance: $viewDistance
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

                // v1.0.1: stats overlay (RAM/CPU/GPU) toggleable via `stats` command
                if showStats {
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(format: "RAM %.0f MB", ramMB))
                                Text(String(format: "CPU %.0f%%", cpuPercent))
                                Text(String(format: "GPU %.0f MB", gpuMB))
                                Text(String(format: "FPS %.0f", fps))
                            }
                            .font(.headline)
                            .foregroundColor(.green)
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

    /// Save the current world (seed + preset + config) to the store.
    private func saveCurrentWorld(name: String) {
        let cfg = shelfInitialized ? shelfConfig : (terrainRenderer?.world.config ?? .auto)
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
            fogDensity: cfg.fogDensity
        )
        savedWorlds.save(world)
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
