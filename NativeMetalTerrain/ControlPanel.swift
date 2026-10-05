import SwiftUI

/// Sun angle sliders. Uses local @State and a direct callback to the renderer
/// so dragging does NOT trigger a full ContentView re-render (which caused
/// the 30fps dip). Only this tiny view re-renders on drag.
struct SunControls: View {
    @State private var azimuth: Float
    @State private var elevation: Float
    var onChange: (Float, Float) -> Void

    init(azimuth: Float, elevation: Float, onChange: @escaping (Float, Float) -> Void) {
        _azimuth = State(initialValue: azimuth)
        _elevation = State(initialValue: elevation)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sun direction: \(Int(azimuth))°")
                .font(.headline)
            Slider(value: $azimuth, in: 0...360, step: 1)
                .tint(.orange)
                .onChange(of: azimuth) { onChange(azimuth, elevation) }
            Text("Sun height: \(Int(elevation))°")
                .font(.headline)
            Slider(value: $elevation, in: 5...90, step: 1)
                .tint(.orange)
                .onChange(of: elevation) { onChange(azimuth, elevation) }
        }
    }
}

/// Bottom/side control panel for the terrain demo.
/// Organized into collapsible sections. Large type, high contrast.
struct ControlPanel: View {
    @Binding var seedText: String
    @Binding var preset: BiomePreset
    @Binding var structuresEnabled: Bool
    @Binding var wireframe: Bool
    @Binding var showsWater: Bool
    @Binding var fogEnabled: Bool
    @Binding var viewDistance: Int
    @Binding var cameraMode: CameraMode
    @Binding var playerHeight: Float
    var onSunChange: (Float, Float) -> Void
    @Binding var shaderEffectsEnabled: Bool
    var usesMetal4: Bool
    var fps: Double
    @Binding var dragMode: DragMode
    var onRegenerate: () -> Void
    var onCloneWorld: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TERRAIN CONTROLS")
                .font(.title2)
                .bold()

            // World: seed + regenerate + clone (always visible)
            DisclosureGroup("World") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Seed")
                            .font(.headline)
                        TextField("1337", text: $seedText)
                            .font(.body)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                            .foregroundColor(.black)
                    }
                    HStack(spacing: 10) {
                        Button(action: onRegenerate) {
                            Text("Regenerate")
                                .font(.headline)
                                .bold()
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        Button(action: onCloneWorld) {
                            Text("Clone")
                                .font(.headline)
                                .bold()
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Biome")
                            .font(.headline)
                        Picker("Biome", selection: $preset) {
                            ForEach(BiomePreset.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.top, 4)
            }
            .font(.headline)

            // Environment: water, fog, structures, wireframe, sun
            DisclosureGroup("Environment") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Water", isOn: $showsWater)
                    Toggle("Fog", isOn: $fogEnabled)
                    Toggle("Structures", isOn: $structuresEnabled)
                    Toggle("Wireframe", isOn: $wireframe)
                    Toggle("Shader Effects", isOn: $shaderEffectsEnabled)
                    SunControls(azimuth: 45, elevation: 50, onChange: onSunChange)
                }
                .font(.headline)
                .padding(.top, 4)
            }
            .font(.headline)

            // View: camera mode, render distance, player height
            DisclosureGroup("View") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Camera", selection: $cameraMode) {
                        ForEach(CameraMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    if cameraMode == .walk {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Player height: \(Int(playerHeight))")
                                .font(.headline)
                            Slider(value: $playerHeight, in: 2...60, step: 1)
                                .tint(.blue)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Render distance: \(viewDistance)")
                            .font(.headline)
                        Slider(value: Binding(
                            get: { Double(viewDistance) },
                            set: { viewDistance = Int($0) }
                        ), in: 2...10, step: 1)
                        .tint(.blue)
                    }
                    #if targetEnvironment(macCatalyst)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mouse drag")
                            .font(.headline)
                        Picker("Mouse drag", selection: $dragMode) {
                            ForEach(DragMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    #endif
                }
                .padding(.top, 4)
            }
            .font(.headline)

            // FPS readout
            Text("\(Int(fps)) FPS")
                .font(.headline)
                .bold()
                .monospacedDigit()
            Text(usesMetal4 ? "Metal 4" : "Metal 3")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color.black.opacity(0.78))
        .foregroundColor(.white)
        .cornerRadius(16)
    }
}
