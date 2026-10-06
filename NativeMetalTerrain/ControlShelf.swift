import SwiftUI
import MetalTerrain

/// A saved world: seed + preset + key config values.
struct SavedWorld: Codable, Identifiable {
    var id = UUID()
    var name: String
    var seed: UInt64
    var presetRaw: String
    // Terrain
    var chunkWorldSize: Float
    var chunkResolution: Int
    var seaLevel: Float
    var heightScale: Float
    var viewDistance: Int
    // Noise
    var octaves: Int
    var frequency: Double
    var amplitude: Double
    var lacunarity: Double
    var gain: Double
    var warpStrength: Double
    var warpFrequency: Double
    var ridged: Bool
    // Structure noise
    var structOctaves: Int
    var structFrequency: Double
    var structAmplitude: Double
    var structLacunarity: Double
    var structGain: Double
    var structWarpStrength: Double
    var structWarpFrequency: Double
    var structRidged: Bool
    var structureDensity: Float
    var structuresEnabled: Bool
    // Renderer
    var fogDensity: Float
    // v1.0.5: new settings
    var ambientIntensity: Float
    var sunIntensity: Float
    var continentScale: Float
    var riverScale: Float
    var mountainSharpness: Float

    var preset: BiomePreset {
        BiomePreset(rawValue: presetRaw) ?? .default
    }
}

/// Manages saved worlds in UserDefaults.
class SavedWorldsStore: ObservableObject {
    @Published var worlds: [SavedWorld] = []
    private let key = "savedWorlds"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedWorld].self, from: data) else {
            worlds = []
            return
        }
        worlds = decoded
    }

    func save(_ world: SavedWorld) {
        worlds.append(world)
        persist()
    }

    func delete(_ world: SavedWorld) {
        worlds.removeAll { $0.id == world.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(worlds) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// A labeled slider with numeric readout.
struct SettingSlider: View {
    var label: String
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.title3).bold().foregroundColor(.white)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.title3).foregroundColor(.green)
                    .frame(minWidth: 80, alignment: .trailing)
            }
            Slider(value: value, in: range, step: step).accentColor(.green)
        }
        .padding(.vertical, 6)
    }
}

/// A labeled toggle.
struct SettingToggle: View {
    var label: String
    var value: Binding<Bool>

    var body: some View {
        Toggle(isOn: value) {
            Text(label).font(.title3).bold().foregroundColor(.white)
        }
        .toggleStyle(SwitchToggleStyle(tint: .green))
        .padding(.vertical, 6)
    }
}

/// Pop-out control shelf with sliders for all library values.
/// Binds directly to a live MTTerrainConfig; parent syncs it to the world.
struct ControlShelf: View {
    @Binding var config: MTTerrainConfig
    @Binding var seedText: String
    var onSeedApply: () -> Void
    var onRandomSeed: () -> Void
    var onSaveWorld: () -> Void
    // Renderer toggles (not in config)
    @Binding var wireframe: Bool
    @Binding var showsWater: Bool
    @Binding var fogEnabled: Bool
    @Binding var shaderEffectsEnabled: Bool
    @Binding var viewDistance: Int

    var body: some View {
        List {
            Section(header: hdr("Seed")) {
                HStack {
                    TextField("Seed", text: $seedText)
                        .font(.title2).keyboardType(.numberPad)
                        .foregroundColor(.white)
                        .padding(8).background(Color(white: 0.2)).cornerRadius(8)
                    Button("Apply") { onSeedApply() }
                        .font(.title3).bold()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.blue).foregroundColor(.white).cornerRadius(10)
                    Button("🎲") { onRandomSeed() }.font(.largeTitle)
                }
                Button(action: onSaveWorld) {
                    HStack {
                        Spacer()
                        Text("💾 Save World").font(.title2).bold().foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(Color.green.opacity(0.8)).cornerRadius(12)
                }
            }

            Section(header: hdr("Terrain")) {
                SettingSlider(label: "View Distance", value: intD($viewDistance), range: 1...10, step: 1, format: "%.0f")
                SettingSlider(label: "Chunk Size", value: fltD($config.chunkWorldSize), range: 50...2000, step: 10, format: "%.0f")
                SettingSlider(label: "Chunk Resolution", value: intD($config.chunkResolution), range: 32...250, step: 1, format: "%.0f")
                SettingSlider(label: "Sea Level", value: fltD($config.seaLevel), range: 0...1, step: 0.01)
                SettingSlider(label: "Height Scale", value: fltD($config.heightScale), range: 10...1000, step: 5, format: "%.0f")
                SettingSlider(label: "Continent Scale", value: fltD($config.continentScale), range: 0.2...3, step: 0.05)
                SettingSlider(label: "River Scale", value: fltD($config.riverScale), range: 0.2...3, step: 0.05)
                SettingSlider(label: "Mountain Sharpness", value: fltD($config.mountainSharpness), range: 0.3...1.5, step: 0.01)
            }

            Section(header: hdr("Terrain Noise")) {
                SettingSlider(label: "Octaves", value: intD($config.noise.octaves), range: 1...12, step: 1, format: "%.0f")
                SettingSlider(label: "Frequency", value: $config.noise.baseFrequency, range: 0.001...0.05, step: 0.001, format: "%.4f")
                SettingSlider(label: "Amplitude", value: $config.noise.amplitude, range: 0.1...3, step: 0.05)
                SettingSlider(label: "Lacunarity", value: $config.noise.lacunarity, range: 1...4, step: 0.01)
                SettingSlider(label: "Gain", value: $config.noise.gain, range: 0.1...1, step: 0.01)
                SettingSlider(label: "Warp Strength", value: $config.noise.warpStrength, range: 0...1, step: 0.01)
                SettingSlider(label: "Warp Frequency", value: $config.noise.warpFrequency, range: 0.001...0.1, step: 0.001, format: "%.4f")
                SettingToggle(label: "Ridged", value: $config.noise.ridged)
            }

            Section(header: hdr("Structure Noise")) {
                SettingSlider(label: "Octaves", value: intD($config.structureNoise.octaves), range: 1...12, step: 1, format: "%.0f")
                SettingSlider(label: "Frequency", value: $config.structureNoise.baseFrequency, range: 0.001...0.05, step: 0.001, format: "%.4f")
                SettingSlider(label: "Amplitude", value: $config.structureNoise.amplitude, range: 0.1...3, step: 0.05)
                SettingSlider(label: "Lacunarity", value: $config.structureNoise.lacunarity, range: 1...4, step: 0.01)
                SettingSlider(label: "Gain", value: $config.structureNoise.gain, range: 0.1...1, step: 0.01)
                SettingSlider(label: "Warp Strength", value: $config.structureNoise.warpStrength, range: 0...1, step: 0.01)
                SettingSlider(label: "Warp Frequency", value: $config.structureNoise.warpFrequency, range: 0.001...0.1, step: 0.001, format: "%.4f")
                SettingToggle(label: "Ridged", value: $config.structureNoise.ridged)
                SettingSlider(label: "Density", value: fltD($config.structureDensity), range: 0...1, step: 0.01)
                SettingToggle(label: "Structures Enabled", value: $config.structuresEnabled)
            }

            Section(header: hdr("Lighting")) {
                SettingSlider(label: "Ambient Light", value: fltD($config.ambientIntensity), range: 0...1, step: 0.01)
                SettingSlider(label: "Sun Intensity", value: fltD($config.sunIntensity), range: 0...2, step: 0.05)
                SettingSlider(label: "Fog Density", value: fltD($config.fogDensity), range: 0...0.1, step: 0.001, format: "%.4f")
            }

            Section(header: hdr("Renderer")) {
                SettingToggle(label: "Wireframe", value: $wireframe)
                SettingToggle(label: "Water", value: $showsWater)
                SettingToggle(label: "Fog", value: $fogEnabled)
                SettingToggle(label: "Shader Effects", value: $shaderEffectsEnabled)
            }
        }
        .listStyle(.insetGrouped)
        .preferredColorScheme(.dark)
    }

    private func hdr(_ t: String) -> some View {
        Text(t).font(.title2).bold().foregroundColor(.green)
    }
    private func intD(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0.rounded()) })
    }
    private func fltD(_ b: Binding<Float>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Float($0) })
    }
}
