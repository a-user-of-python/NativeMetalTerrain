import SwiftUI

/// On-screen virtual joystick for walk mode.
/// Drag from the center: up = forward, down = back, left/right = strafe.
/// Writes -1...1 into `input` (x = strafe, y = forward).
struct JoystickView: View {
    @Binding var input: SIMD2<Float>
    @State private var knobOffset = CGSize.zero

    private let radius: CGFloat = 60
    private let knobRadius: CGFloat = 26

    var body: some View {
        ZStack {
            // Base
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: radius * 2, height: radius * 2)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.7), lineWidth: 3)
                )
            // Knob
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .offset(knobOffset)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    var offset = value.translation
                    let dist = sqrt(offset.width * offset.width + offset.height * offset.height)
                    let maxDist = radius - knobRadius
                    if dist > maxDist {
                        offset.width *= maxDist / dist
                        offset.height *= maxDist / dist
                    }
                    knobOffset = CGSize(width: offset.width, height: offset.height)
                    // Up on screen = forward (+y input). Drag up = negative height.
                    input = SIMD2<Float>(
                        Float(offset.width / maxDist),
                        Float(-offset.height / maxDist)
                    )
                }
                .onEnded { _ in
                    knobOffset = .zero
                    input = SIMD2<Float>(0, 0)
                }
        )
    }
}
