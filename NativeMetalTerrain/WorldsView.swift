import SwiftUI

/// Preset worlds list + saved worlds.
struct WorldsView: View {
    var onSelect: (BiomePreset) -> Void
    var onLoadSaved: (SavedWorld) -> Void
    @StateObject private var store = SavedWorldsStore()

    var body: some View {
        List {
            Section(header: Text("Presets").font(.title2).bold().foregroundColor(.green)) {
                ForEach(BiomePreset.allCases) { preset in
                    Button(action: { onSelect(preset) }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preset.rawValue)
                                .font(.largeTitle).bold().foregroundColor(.white)
                            Text(presetDescription(preset))
                                .font(.title3).foregroundColor(.gray)
                        }
                        .padding(.vertical, 12)
                    }
                    .listRowBackground(Color(white: 0.12))
                }
            }

            Section(header: Text("Saved Worlds").font(.title2).bold().foregroundColor(.green)) {
                if store.worlds.isEmpty {
                    Text("No saved worlds yet.\nUse 💾 Save World in Controls.")
                        .font(.title3).foregroundColor(.gray)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.worlds) { world in
                        HStack {
                            Button(action: { onLoadSaved(world) }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(world.name)
                                        .font(.title2).bold().foregroundColor(.white)
                                    Text("Seed \(world.seed) • \(world.preset.rawValue)")
                                        .font(.body).foregroundColor(.gray)
                                }
                                .padding(.vertical, 8)
                            }
                            Spacer()
                            Button(action: { store.delete(world) }) {
                                Image(systemName: "trash")
                                    .font(.title2).foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color(white: 0.12))
                }
            }
        }
        .navigationTitle("Worlds")
        .preferredColorScheme(.dark)
        .onAppear { store.load() }
    }

    private func presetDescription(_ preset: BiomePreset) -> String {
        switch preset {
        case .default: return "Balanced terrain with mountains, plains, and oceans"
        case .desert: return "Arid dunes and canyons"
        case .alien: return "Exotic otherworldly landscape"
        case .forest: return "Dense woodland with rolling hills"
        case .custom: return "High peaks custom biome"
        }
    }
}
