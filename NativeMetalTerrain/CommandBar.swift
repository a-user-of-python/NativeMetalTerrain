import SwiftUI
import MetalTerrain

/// Command bar UI for v1.0.0.
/// A single command button expands into a field with autocomplete.
struct CommandBar: View {
    @Binding var isExpanded: Bool
    @Binding var commandText: String
    @Binding var outputMessage: String?
    @Binding var outputIsError: Bool
    var onSubmit: (String) -> Void
    var onSelectCommand: (TerrainCommand) -> Void

    @State private var selectedCommand: TerrainCommand?

    var filteredCommands: [TerrainCommand] {
        // If text is empty or just "/", show all. Otherwise filter by prefix.
        // Skip the "/" for devtools when matching.
        let query = commandText.hasPrefix("/") ? String(commandText.dropFirst()) : commandText
        let parts = query.split(separator: " ", maxSplits: 1)
        let namePart = String(parts.first ?? "")
        return CommandRegistry.search(namePart)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Output message (appears briefly after command)
            if let msg = outputMessage {
                Text(msg)
                    .font(.headline)
                    .foregroundColor(outputIsError ? .red : .green)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.bottom, 8)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    // Command list (scrollable)
                    if !filteredCommands.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(filteredCommands, id: \.name) { cmd in
                                    Button(action: {
                                        onSelectCommand(cmd)
                                        selectedCommand = cmd
                                    }) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(cmd.name)
                                                .font(.title3)
                                                .bold()
                                                .foregroundColor(.white)
                                            Text(cmd.description)
                                                .font(.headline)
                                                .foregroundColor(.white.opacity(0.7))
                                            Text(cmd.usage)
                                                .font(.subheadline)
                                                .foregroundColor(.blue.opacity(0.9))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.white.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 300)
                        .background(Color.black.opacity(0.9))
                        .cornerRadius(12)
                        .padding(.bottom, 8)
                    }

                    // Input field
                    HStack {
                        TextField("Type a command...", text: $commandText, onCommit: {
                            onSubmit(commandText)
                        })
                        .font(.title2)
                        .padding(12)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(10)
                        .foregroundColor(.white)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                        Button(action: {
                            onSubmit(commandText)
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.9))
                    .cornerRadius(12)

                    // Selected command help
                    if let cmd = selectedCommand {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cmd.name)
                                .font(.headline)
                                .bold()
                            Text(cmd.description)
                                .font(.subheadline)
                            Text("Usage: \(cmd.usage)")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(8)
                        .padding(.top, 8)
                    }
                }
                .padding()
            } else {
                // Collapsed: just the command button
                Button(action: {
                    withAnimation { isExpanded = true }
                }) {
                    Image(systemName: "command")
                        .font(.largeTitle)
                        .foregroundColor(.white)
                        .padding(16)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
                .padding()
            }
        }
    }
}
