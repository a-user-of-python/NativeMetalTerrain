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
    // v1.0.11: water + sun + skybox + detail (all optional for backward compat)
    var waveSpeed: Float? = nil
    var waveAmplitude: Float? = nil
    var waterOpacity: Float? = nil
    var waterDeepR: Float? = nil
    var waterDeepG: Float? = nil
    var waterDeepB: Float? = nil
    var waterShallowR: Float? = nil
    var waterShallowG: Float? = nil
    var waterShallowB: Float? = nil
    var sunAzimuth: Float? = nil
    var sunElevation: Float? = nil
    var skyboxEnabled: Bool? = nil
    var detailAmount: Float? = nil
    // v1.0.12: time of day
    var timeOfDay: Float? = nil
    var timeOfDayEnabled: Bool? = nil
    var timeOfDaySpeed: Float? = nil
    // v1.0.13: sky + per-structure weights
    var cloudAmount: Float? = nil
    var starsEnabled: Bool? = nil
    var structureKindWeights: [String: Float]? = nil

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

/// RGB color picker with three large sliders and a live preview swatch.
struct SettingColorRGB: View {
    var label: String
    var color: Binding<SIMD3<Float>>

    private func channel(_ i: Int) -> Binding<Double> {
        Binding(
            get: { Double(i == 0 ? color.wrappedValue.x : i == 1 ? color.wrappedValue.y : color.wrappedValue.z) },
            set: {
                var c = color.wrappedValue
                let v = Float($0)
                if i == 0 { c.x = v } else if i == 1 { c.y = v } else { c.z = v }
                color.wrappedValue = c
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.title3).bold().foregroundColor(.white)
                Spacer()
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: Double(color.wrappedValue.x),
                                green: Double(color.wrappedValue.y),
                                blue: Double(color.wrappedValue.z)))
                    .frame(width: 60, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4), lineWidth: 1))
            }
            SettingSlider(label: "R", value: channel(0), range: 0...1, step: 0.01)
            SettingSlider(label: "G", value: channel(1), range: 0...1, step: 0.01)
            SettingSlider(label: "B", value: channel(2), range: 0...1, step: 0.01)
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
            Text(label).font(.title3).bold().foregroundColor(.white)        }
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
    // Sun position (renderer, not config)
    @Binding var sunAzimuth: Float
    @Binding var sunElevation: Float
    // Skybox and detail (renderer)
    @Binding var skyboxEnabled: Bool
    @Binding var detailAmount: Float
    // Water controls (renderer, live-update)
    @Binding var waveSpeed: Float
    @Binding var waveAmplitude: Float
    @Binding var waterOpacity: Float
    @Binding var waterDeepColor: SIMD3<Float>
    @Binding var waterShallowColor: SIMD3<Float>
    // Time of day (renderer)
    @Binding var timeOfDay: Float
    @Binding var timeOfDayEnabled: Bool
    @Binding var timeOfDaySpeed: Float
    // Sky (renderer)
    @Binding var cloudAmount: Float
    @Binding var starsEnabled: Bool
    // Structure weights (config dict)
    @Binding var structureKindWeights: [String: Float]

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
                SettingSlider(label: "Chunk Size", value: fltD($config.chunkWorldSize), range: 50...1000, step: 10, format: "%.0f")
                SettingSlider(label: "Chunk Resolution", value: intD($config.chunkResolution), range: 32...250, step: 1, format: "%.0f")
                SettingSlider(label: "Sea Level", value: fltD($config.seaLevel), range: 0...1, step: 0.01)
                SettingSlider(label: "Height Scale", value: fltD($config.heightScale), range: 10...600, step: 5, format: "%.0f")
                SettingSlider(label: "Continent Scale", value: fltD($config.continentScale), range: 0.2...3, step: 0.05)
                SettingSlider(label: "River Scale", value: fltD($config.riverScale), range: 0.2...3, step: 0.05)
                SettingSlider(label: "Mountain Sharpness", value: fltD($config.mountainSharpness), range: 0.3...1.5, step: 0.01)
            }

            Section(header: hdr("Terrain Noise")) {
                SettingSlider(label: "Octaves", value: intD($config.noise.octaves), range: 1...8, step: 1, format: "%.0f")
                SettingSlider(label: "Frequency", value: $config.noise.baseFrequency, range: 0.001...0.02, step: 0.001, format: "%.4f")
                SettingSlider(label: "Amplitude", value: $config.noise.amplitude, range: 0.1...3, step: 0.05)
                SettingSlider(label: "Lacunarity", value: $config.noise.lacunarity, range: 1...2.5, step: 0.01)
                SettingSlider(label: "Gain", value: $config.noise.gain, range: 0.1...1, step: 0.01)
                SettingSlider(label: "Warp Strength", value: $config.noise.warpStrength, range: 0...1, step: 0.01)
                SettingSlider(label: "Warp Frequency", value: $config.noise.warpFrequency, range: 0.001...0.05, step: 0.001, format: "%.4f")
                SettingToggle(label: "Ridged", value: $config.noise.ridged)
            }

            Section(header: hdr("Structure Noise")) {
                SettingSlider(label: "Octaves", value: intD($config.structureNoise.octaves), range: 1...8, step: 1, format: "%.0f")
                SettingSlider(label: "Frequency", value: $config.structureNoise.baseFrequency, range: 0.001...0.02, step: 0.001, format: "%.4f")
                SettingSlider(label: "Amplitude", value: $config.structureNoise.amplitude, range: 0.1...3, step: 0.05)
                SettingSlider(label: "Lacunarity", value: $config.structureNoise.lacunarity, range: 1...2.5, step: 0.01)
                SettingSlider(label: "Gain", value: $config.structureNoise.gain, range: 0.1...1, step: 0.01)
                SettingSlider(label: "Warp Strength", value: $config.structureNoise.warpStrength, range: 0...1, step: 0.01)
                SettingSlider(label: "Warp Frequency", value: $config.structureNoise.warpFrequency, range: 0.001...0.05, step: 0.001, format: "%.4f")
                SettingToggle(label: "Ridged", value: $config.structureNoise.ridged)
                SettingSlider(label: "Density", value: fltD($config.structureDensity), range: 0...1, step: 0.01)
                SettingToggle(label: "Structures Enabled", value: $config.structuresEnabled)
            }

            Section(header: hdr("Lighting")) {
                SettingSlider(label: "Ambient Light", value: fltD($config.ambientIntensity), range: 0...1, step: 0.01)
                SettingSlider(label: "Sun Intensity", value: fltD($config.sunIntensity), range: 0...2, step: 0.05)
                SettingSlider(label: "Sun Azimuth", value: fltD($sunAzimuth), range: 0...360, step: 1, format: "%.0f°")
                SettingSlider(label: "Sun Elevation", value: fltD($sunElevation), range: -10...90, step: 1, format: "%.0f°")
                SettingSlider(label: "Fog Density", value: fltD($config.fogDensity), range: 0...0.1, step: 0.001, format: "%.4f")
            }

            Section(header: hdr("Renderer")) {
                SettingToggle(label: "Wireframe", value: $wireframe)
                SettingToggle(label: "Water", value: $showsWater)
                SettingToggle(label: "Fog", value: $fogEnabled)
                SettingToggle(label: "Shader Effects", value: $shaderEffectsEnabled)
                SettingToggle(label: "Skybox", value: $skyboxEnabled)
                SettingSlider(label: "Detail Amount", value: fltD($detailAmount), range: 0...1, step: 0.01)
            }

            Section(header: hdr("Water")) {
                SettingSlider(label: "Wave Speed", value: fltD($waveSpeed), range: 0...3, step: 0.05)
                SettingSlider(label: "Wave Height", value: fltD($waveAmplitude), range: 0...2, step: 0.05)
                SettingSlider(label: "Opacity", value: fltD($waterOpacity), range: 0...1, step: 0.01)
                SettingColorRGB(label: "Deep Color", color: $waterDeepColor)
                SettingColorRGB(label: "Shallow Color", color: $waterShallowColor)
            }

            Section(header: hdr("Time of Day")) {
                SettingToggle(label: "Animate Time", value: $timeOfDayEnabled)
                SettingSlider(label: "Time", value: fltD($timeOfDay), range: 0...24, step: 0.1, format: "%.1fh")
                SettingSlider(label: "Speed", value: fltD($timeOfDaySpeed), range: 0...60, step: 0.5, format: "%.1f")
            }

            Section(header: hdr("Sky")) {
                SettingSlider(label: "Clouds", value: fltD($cloudAmount), range: 0...1, step: 0.01)
                SettingToggle(label: "Stars", value: $starsEnabled)
            }

            Section(header: hdr("Structures")) {
                ForEach(["tree", "house", "tower", "boulder", "well", "windmill", "dungeon"], id: \.self) { kind in
                    SettingSlider(
                        label: kind.capitalized,
                        value: Binding(
                            get: { Double(structureKindWeights[kind] ?? 1.0) },
                            set: { structureKindWeights[kind] = Float($0) }
                        ),
                        range: 0...5, step: 0.1
                    )
                }
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
