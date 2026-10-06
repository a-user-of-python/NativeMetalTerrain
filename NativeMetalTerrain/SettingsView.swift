import SwiftUI

/// App settings.
struct SettingsView: View {
    @AppStorage("metalPreference") private var metalPreferenceRaw = MetalPreference.auto.rawValue

    var metalPreference: Binding<MetalPreference> {
        Binding(
            get: { MetalPreference(rawValue: metalPreferenceRaw) ?? .auto },
            set: { metalPreferenceRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section(header: Text("Graphics").font(.title2)) {
                Picker("Metal Version", selection: metalPreference) {
                    ForEach(MetalPreference.allCases, id: \.self) { pref in
                        Text(pref.rawValue).tag(pref).font(.title2)
                    }
                }
                .pickerStyle(.segmented)

                Text(metalDescription)
                    .font(.body)
                    .foregroundColor(.gray)
            }

            Section(header: Text("About").font(.title2)) {
                Text("NativeMetalTerrain")
                    .font(.title3)
                Text("Procedural 3D terrain on Metal")
                    .font(.body)
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("Settings")
        .preferredColorScheme(.dark)
    }

    private var metalDescription: String {
        switch MetalPreference(rawValue: metalPreferenceRaw) ?? .auto {
        case .auto:
            return "Automatically uses Metal 4 on supported devices, Metal 3 otherwise."
        case .metal3:
            return "Forces Metal 3 even on devices that support Metal 4."
        case .metal4:
            return "Forces Metal 4. Falls back to Metal 3 if unavailable."
        }
    }
}
