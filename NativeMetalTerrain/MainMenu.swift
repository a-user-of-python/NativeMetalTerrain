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
    @State private var playPreset: BiomePreset? = nil

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
                    playPreset = BiomePreset(rawValue: lastPresetRaw) ?? .default
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
                WorldsView(onSelect: { preset in
                    lastPresetRaw = preset.rawValue
                    playPreset = preset
                })
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .fullScreenCover(item: $playPreset) { preset in
                ContentView(initialPreset: preset)
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
