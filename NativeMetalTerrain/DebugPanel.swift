import SwiftUI

/// Compact debug overlay, separate from the main control panel.
/// Large type, high contrast (bad-vision friendly).
struct DebugPanel: View {
    @Binding var carActive: Bool
    @Binding var simulatorMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEBUG")
                .font(.title3)
                .bold()
            Button(action: { carActive.toggle() }) {
                Text(carActive ? "Despawn Car" : "Spawn Car")
                    .font(.title3)
                    .bold()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
            .background(carActive ? Color.red : Color.green)
            .foregroundColor(.white)
            .cornerRadius(14)
            if carActive {
                Text("Joystick drives + steers")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.85))
            }
            Button(action: { simulatorMode.toggle() }) {
                Text(simulatorMode ? "Simulator: ON" : "Simulator: OFF")
                    .font(.title3)
                    .bold()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
            .background(simulatorMode ? Color.orange : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(14)
            Text(simulatorMode ? "Low-res mode" : "Full quality")
                .font(.headline)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(12)
        .background(Color.black.opacity(0.78))
        .foregroundColor(.white)
        .cornerRadius(16)
    }
}
