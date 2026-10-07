import SwiftUI

/// v1.2.1: Performance stats overlay with live graphs.
/// Shows CPU, GPU, Memory, Wattage, and FPS with history graphs.
struct StatsOverlay: View {
    @AppStorage("showCPU") private var showCPU = false
    @AppStorage("showGPU") private var showGPU = false
    @AppStorage("showMemory") private var showMemory = false
    @AppStorage("showWattage") private var showWattage = false
    @AppStorage("showFPSGraph") private var showFPSGraph = false

    let cpuPercent: Double
    let gpuMB: Double
    let ramMB: Double
    let wattage: Double
    let fps: Double

    // History for graphs (last 60 samples = 30 seconds at 2Hz)
    @State private var cpuHistory: [Double] = []
    @State private var gpuHistory: [Double] = []
    @State private var ramHistory: [Double] = []
    @State private var wattHistory: [Double] = []
    @State private var fpsHistory: [Double] = []

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    if showCPU {
                        StatRow(label: "CPU", value: String(format: "%.0f%%", cpuPercent),
                                history: cpuHistory, color: .green, max: 100)
                    }
                    if showGPU {
                        StatRow(label: "GPU", value: String(format: "%.0f MB", gpuMB),
                                history: gpuHistory, color: .blue, max: 4000)
                    }
                    if showMemory {
                        StatRow(label: "RAM", value: String(format: "%.0f MB", ramMB),
                                history: ramHistory, color: .orange, max: 4000)
                    }
                    if showWattage {
                        StatRow(label: "PWR", value: String(format: "%.1fW", wattage),
                                history: wattHistory, color: .red, max: 20)
                    }
                    if showFPSGraph {
                        StatRow(label: "FPS", value: String(format: "%.0f", fps),
                                history: fpsHistory, color: .purple, max: 120)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                Spacer()
            }
            .padding(.top, 50)
            .padding(.leading, 12)
            Spacer()
        }
        .onChange(of: cpuPercent) { _ in updateHistory() }
    }

    private func updateHistory() {
        cpuHistory.append(cpuPercent)
        gpuHistory.append(gpuMB)
        ramHistory.append(ramMB)
        wattHistory.append(wattage)
        fpsHistory.append(fps)
        let maxCount = 60
        if cpuHistory.count > maxCount {
            cpuHistory.removeFirst()
            gpuHistory.removeFirst()
            ramHistory.removeFirst()
            wattHistory.removeFirst()
            fpsHistory.removeFirst()
        }
    }
}

/// Single stat row with label, value, and mini graph.
struct StatRow: View {
    let label: String
    let value: String
    let history: [Double]
    let color: Color
    let max: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.headline)
                    .foregroundColor(color)
                Spacer()
                Text(value)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            // Mini graph
            GeometryReader { geo in
                Path { path in
                    guard history.count > 1 else { return }
                    let w = geo.size.width
                    let h = geo.size.height
                    let stepX = w / CGFloat(max(history.count - 1, 1))
                    for (i, val) in history.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = h - (CGFloat(min(val, max)) / CGFloat(max)) * h
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 2)
            }
            .frame(height: 30)
        }
        .frame(width: 200)
    }
}
