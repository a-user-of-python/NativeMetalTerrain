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
    /// v1.0.0: command UI mode. When false, shows command bar. When true
    /// (via /devtools), shows the classic button panels.
    @State private var devtoolsMode = false
    /// Command bar state.
    @State private var commandExpanded = false
    @State private var commandText = ""
    @State private var outputMessage: String? = nil
    @State private var outputIsError = false
    /// Timer to auto-dismiss output message.
    @State private var outputDismissWorkItem: DispatchWorkItem? = nil

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

                // v1.0.0: command bar mode (default). Devtools mode shows classic UI.
                if !devtoolsMode {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            CommandBar(
                                isExpanded: $commandExpanded,
                                commandText: $commandText,
                                outputMessage: $outputMessage,
                                outputIsError: $outputIsError,
                                onSubmit: { cmd in executeCommand(cmd) },
                                onSelectCommand: { cmd in
                                    // Put command name in bar with trailing space
                                    commandText = cmd.name + " "
                                }
                            )
                        }
                        .padding()
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
            // If the command changed the world, bump rebuild token
            // (commands that set world.config already trigger via configVersion,
            // but seed changes need explicit rebuild)
            if cmd.name == "seed" {
                rebuildToken += 1
            }
        case .error(let msg):
            showOutput(msg, isError: true)
        }
        commandText = ""
    }

    /// Show output message briefly. Tap to dismiss, or it clears on next command.
    /// (Auto-dismiss via timer doesn't work in a struct; manual dismiss is reliable.)
    private func showOutput(_ msg: String, isError: Bool) {
        outputMessage = msg
        outputIsError = isError
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
