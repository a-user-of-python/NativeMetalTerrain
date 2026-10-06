import SwiftUI

/// App-wide settings (persisted via @AppStorage).
enum MetalPreference: String, CaseIterable {
    case auto = "Auto"
    case metal3 = "Metal 3"
    case metal4 = "Metal 4"
}

/// Main menu: Play / Worlds / Settings.
struct MainMenu: View {
    @AppStorage("metalPreference") private var metalPreferenceRaw = MetalPreference.auto.rawValue
    @AppStorage("lastPreset") private var lastPresetRaw = BiomePreset.default.rawValue

    @State private var showWorlds = false
    @State private var showSettings = false
    @State private var activePreset: BiomePreset? = nil
    @State private var showGame = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Text("NativeMetalTerrain")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.white)

                Text("Procedural 3D Terrain")
                    .font(.title2)
                    .foregroundColor(.gray)

                Spacer()

                // Play — jumps into the last used world
                Button(action: {
                    activePreset = BiomePreset(rawValue: lastPresetRaw) ?? .default
                    showGame = true
                }) {
                    menuButtonLabel("▶ Play", color: .green)
                }

                // Worlds — preset worlds list
                Button(action: { showWorlds = true }) {
                    menuButtonLabel("🌍 Worlds", color: .blue)
                }

                // Settings
                Button(action: { showSettings = true }) {
                    menuButtonLabel("⚙ Settings", color: .orange)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationDestination(isPresented: $showWorlds) {
                WorldsView(
                    onSelect: { preset in
                        lastPresetRaw = preset.rawValue
                        activePreset = preset
                        showGame = true
                    },
                    onLoadSaved: { saved in
                        // Load saved world: store it for ContentView to pick up
                        UserDefaults.standard.set(saved.presetRaw, forKey: "pendingPreset")
                        UserDefaults.standard.set(saved.seed, forKey: "pendingSeed")
                        // Encode the saved config values
                        if let data = try? JSONEncoder().encode(saved) {
                            UserDefaults.standard.set(data, forKey: "pendingSavedWorld")
                        }
                        lastPresetRaw = saved.presetRaw
                        activePreset = saved.preset
                        showGame = true
                    }
                )
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(isPresented: $showGame) {
                if let preset = activePreset {
                    ContentView(initialPreset: preset)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func menuButtonLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.largeTitle)
            .bold()
            .foregroundColor(.white)
            .frame(maxWidth: 300)
            .padding(.vertical, 20)
            .background(color.opacity(0.8))
            .cornerRadius(16)
    }
}
