import SwiftUI

/// Preset worlds list.
struct WorldsView: View {
    var onSelect: (BiomePreset) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(BiomePreset.allCases) { preset in
            Button(action: {
                onSelect(preset)
                dismiss()
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(preset.rawValue)
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.white)
                    Text(presetDescription(preset))
                        .font(.title3)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 12)
            }
            .listRowBackground(Color(white: 0.12))
        }
        .navigationTitle("Worlds")
        .preferredColorScheme(.dark)
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
