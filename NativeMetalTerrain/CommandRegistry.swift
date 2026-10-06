import Foundation

/// Result of executing a command.
enum CommandResult {
    case success(String)  // Message to display, e.g., "renderdistance set to 3"
    case error(String)    // Error message, e.g., "syntax error"
}

/// Context passed to command handlers: gives access to world and renderer.
struct CommandContext {
    var getWorld: () -> MTTerrainWorld?
    var getRenderer: () -> MTTerrainRenderer?
    var onWorldRebuild: () -> Void  // Called when config changes need rebuild
}

/// A single terrain command.
struct TerrainCommand {
    let name: String
    let description: String
    let usage: String  // e.g., "renderdistance <1-10>"
    let handler: ([String], CommandContext) -> CommandResult
}

/// Registry of all available commands.
struct CommandRegistry {
    static func allCommands() -> [TerrainCommand] {
        return [
            // MARK: - Terrain
            TerrainCommand(
                name: "renderdistance",
                description: "Sets how many chunks are visible around the camera",
                usage: "renderdistance <1-10>"
            ) { args, ctx in
                guard args.count == 1, let v = Int(args[0]), (1...10).contains(v) else {
                    return .error("syntax error: usage: renderdistance <1-10>")
                }
                ctx.getRenderer()?.viewDistance = v
                return .success("renderdistance set to \(v)")
            },
            TerrainCommand(
                name: "chunksize",
                description: "Sets the world size of each chunk (e.g., 1500 = 1500x1500)",
                usage: "chunksize <size>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]), v >= 1 else {
                    return .error("syntax error: usage: chunksize <size>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.chunkWorldSize = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("chunksize set to \(v)")
            },
            TerrainCommand(
                name: "chunkresolution",
                description: "Vertices per chunk side (higher = more detail, slower)",
                usage: "chunkresolution <16-250>"
            ) { args, ctx in
                guard args.count == 1, let v = Int(args[0]), (16...250).contains(v) else {
                    return .error("syntax error: usage: chunkresolution <16-250>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.chunkResolution = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("chunkresolution set to \(v)")
            },
            TerrainCommand(
                name: "sealevel",
                description: "Normalized sea level (0.0-1.0)",
                usage: "sealevel <0.0-1.0>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]), (0...1).contains(v) else {
                    return .error("syntax error: usage: sealevel <0.0-1.0>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.seaLevel = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("sealevel set to \(v)")
            },
            TerrainCommand(
                name: "heightscale",
                description: "World units at height=1 (terrain vertical scale)",
                usage: "heightscale <1-2000>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]), v >= 1 else {
                    return .error("syntax error: usage: heightscale <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.heightScale = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("heightscale set to \(v)")
            },
            TerrainCommand(
                name: "mountainmax",
                description: "Sets max mountain height (via heightscale)",
                usage: "mountainmax <height>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]), v >= 1 else {
                    return .error("syntax error: usage: mountainmax <height>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.heightScale = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("mountainmax set to \(v)")
            },

            // MARK: - Noise
            TerrainCommand(
                name: "seed",
                description: "World seed (regenerates terrain)",
                usage: "seed <number>"
            ) { args, ctx in
                guard args.count == 1, let v = UInt64(args[0]) else {
                    return .error("syntax error: usage: seed <number>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                world.seed = v
                ctx.onWorldRebuild()
                return .success("seed set to \(v)")
            },
            TerrainCommand(
                name: "octaves",
                description: "Noise octaves (1-12, more = more detail)",
                usage: "octaves <1-12>"
            ) { args, ctx in
                guard args.count == 1, let v = Int(args[0]), (1...12).contains(v) else {
                    return .error("syntax error: usage: octaves <1-12>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.octaves = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("octaves set to \(v)")
            },
            TerrainCommand(
                name: "frequency",
                description: "Base noise frequency (smaller = larger features)",
                usage: "frequency <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: frequency <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.baseFrequency = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("frequency set to \(v)")
            },
            TerrainCommand(
                name: "amplitude",
                description: "Noise amplitude",
                usage: "amplitude <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]) else {
                    return .error("syntax error: usage: amplitude <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.amplitude = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("amplitude set to \(v)")
            },
            TerrainCommand(
                name: "lacunarity",
                description: "Frequency multiplier per octave",
                usage: "lacunarity <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: lacunarity <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.lacunarity = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("lacunarity set to \(v)")
            },
            TerrainCommand(
                name: "gain",
                description: "Amplitude multiplier per octave",
                usage: "gain <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]) else {
                    return .error("syntax error: usage: gain <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.gain = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("gain set to \(v)")
            },
            TerrainCommand(
                name: "warpstrength",
                description: "Domain warp strength (0 = off)",
                usage: "warpstrength <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v >= 0 else {
                    return .error("syntax error: usage: warpstrength <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.warpStrength = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("warpstrength set to \(v)")
            },
            TerrainCommand(
                name: "warpfrequency",
                description: "Domain warp frequency",
                usage: "warpfrequency <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: warpfrequency <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.warpFrequency = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("warpfrequency set to \(v)")
            },
            TerrainCommand(
                name: "ridged",
                description: "Ridged noise mode (mountain-like)",
                usage: "ridged <on|off>"
            ) { args, ctx in
                guard args.count == 1 else {
                    return .error("syntax error: usage: ridged <on|off>")
                }
                let v: Bool
                if args[0].lowercased() == "on" { v = true }
                else if args[0].lowercased() == "off" { v = false }
                else { return .error("syntax error: usage: ridged <on|off>") }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.noise.ridged = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("ridged set to \(v ? "on" : "off")")
            },

            // MARK: - Renderer
            TerrainCommand(
                name: "wireframe",
                description: "Toggle wireframe overlay",
                usage: "wireframe <on|off>"
            ) { args, ctx in
                guard args.count == 1 else {
                    return .error("syntax error: usage: wireframe <on|off>")
                }
                let v = args[0].lowercased() == "on"
                ctx.getRenderer()?.wireframe = v
                return .success("wireframe set to \(v ? "on" : "off")")
            },
            TerrainCommand(
                name: "water",
                description: "Toggle water rendering",
                usage: "water <on|off>"
            ) { args, ctx in
                guard args.count == 1 else {
                    return .error("syntax error: usage: water <on|off>")
                }
                let v = args[0].lowercased() == "on"
                ctx.getRenderer()?.showsWater = v
                return .success("water set to \(v ? "on" : "off")")
            },
            TerrainCommand(
                name: "fog",
                description: "Toggle fog",
                usage: "fog <on|off>"
            ) { args, ctx in
                guard args.count == 1 else {
                    return .error("syntax error: usage: fog <on|off>")
                }
                let v = args[0].lowercased() == "on"
                ctx.getRenderer()?.fogEnabled = v
                return .success("fog set to \(v ? "on" : "off")")
            },
            TerrainCommand(
                name: "fogdensity",
                description: "Fog density",
                usage: "fogdensity <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]), v >= 0 else {
                    return .error("syntax error: usage: fogdensity <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.fogDensity = v
                world.config = cfg
                return .success("fogdensity set to \(v)")
            },
            TerrainCommand(
                name: "sunazimuth",
                description: "Sun azimuth angle (degrees)",
                usage: "sunazimuth <0-360>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]) else {
                    return .error("syntax error: usage: sunazimuth <0-360>")
                }
                ctx.getRenderer()?.sunAzimuth = v
                return .success("sunazimuth set to \(v)")
            },
            TerrainCommand(
                name: "sunelevation",
                description: "Sun elevation angle (degrees)",
                usage: "sunelevation <0-90>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]) else {
                    return .error("syntax error: usage: sunelevation <0-90>")
                }
                ctx.getRenderer()?.sunElevation = v
                return .success("sunelevation set to \(v)")
            },
            TerrainCommand(
                name: "shadereffects",
                description: "Toggle shader effects",
                usage: "shadereffects <on|off>"
            ) { args, ctx in
                guard args.count == 1 else {
                    return .error("syntax error: usage: shadereffects <on|off>")
                }
                let v = args[0].lowercased() == "on"
                ctx.getRenderer()?.shaderEffectsEnabled = v
                return .success("shadereffects set to \(v ? "on" : "off")")
            },
            TerrainCommand(
                name: "detailamount",
                description: "Procedural 3D detail amount (0.0-1.0)",
                usage: "detailamount <0.0-1.0>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]), (0...1).contains(v) else {
                    return .error("syntax error: usage: detailamount <0.0-1.0>")
                }
                ctx.getRenderer()?.detailAmount = v
                return .success("detailamount set to \(v)")
            },

            // MARK: - Structures
            TerrainCommand(
                name: "structures",
                description: "Toggle structures",
                usage: "structures <on|off>"
            ) { args, ctx in
                guard args.count == 1 else {
                    return .error("syntax error: usage: structures <on|off>")
                }
                let v = args[0].lowercased() == "on"
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structuresEnabled = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structures set to \(v ? "on" : "off")")
            },
            TerrainCommand(
                name: "structuredensity",
                description: "Structure density (0.0-1.0)",
                usage: "structuredensity <0.0-1.0>"
            ) { args, ctx in
                guard args.count == 1, let v = Float(args[0]), (0...1).contains(v) else {
                    return .error("syntax error: usage: structuredensity <0.0-1.0>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureDensity = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structuredensity set to \(v)")
            },

            // MARK: - Structure Noise (controls where structures spawn)
            TerrainCommand(
                name: "structoctaves",
                description: "Structure noise octaves (1-12)",
                usage: "structoctaves <1-12>"
            ) { args, ctx in
                guard args.count == 1, let v = Int(args[0]), (1...12).contains(v) else {
                    return .error("syntax error: usage: structoctaves <1-12>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.octaves = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structoctaves set to \(v)")
            },
            TerrainCommand(
                name: "structfrequency",
                description: "Structure noise base frequency",
                usage: "structfrequency <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: structfrequency <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.baseFrequency = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structfrequency set to \(v)")
            },
            TerrainCommand(
                name: "structamplitude",
                description: "Structure noise amplitude",
                usage: "structamplitude <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: structamplitude <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.amplitude = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structamplitude set to \(v)")
            },
            TerrainCommand(
                name: "structlacunarity",
                description: "Structure noise lacunarity",
                usage: "structlacunarity <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: structlacunarity <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.lacunarity = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structlacunarity set to \(v)")
            },
            TerrainCommand(
                name: "structgain",
                description: "Structure noise gain",
                usage: "structgain <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: structgain <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.gain = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structgain set to \(v)")
            },
            TerrainCommand(
                name: "structwarpstrength",
                description: "Structure noise warp strength (0 = off)",
                usage: "structwarpstrength <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v >= 0 else {
                    return .error("syntax error: usage: structwarpstrength <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.warpStrength = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structwarpstrength set to \(v)")
            },
            TerrainCommand(
                name: "structwarpfrequency",
                description: "Structure noise warp frequency",
                usage: "structwarpfrequency <value>"
            ) { args, ctx in
                guard args.count == 1, let v = Double(args[0]), v > 0 else {
                    return .error("syntax error: usage: structwarpfrequency <value>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.warpFrequency = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structwarpfrequency set to \(v)")
            },
            TerrainCommand(
                name: "structridged",
                description: "Structure noise ridged mode (on/off)",
                usage: "structridged <on|off>"
            ) { args, ctx in
                guard args.count == 1 else {
                    return .error("syntax error: usage: structridged <on|off>")
                }
                let v: Bool
                switch args[0].lowercased() {
                case "on": v = true
                case "off": v = false
                default: return .error("syntax error: usage: structridged <on|off>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.structureNoise.ridged = v
                world.config = cfg
                ctx.onWorldRebuild()
                return .success("structridged set to \(v ? "on" : "off")")
            },

            // MARK: - Colors
            TerrainCommand(
                name: "watercolor",
                description: "Water color (r g b, 0.0-1.0 each)",
                usage: "watercolor <r> <g> <b>"
            ) { args, ctx in
                guard args.count == 3,
                      let r = Float(args[0]), let g = Float(args[1]), let b = Float(args[2]),
                      (0...1).contains(r), (0...1).contains(g), (0...1).contains(b) else {
                    return .error("syntax error: usage: watercolor <r> <g> <b>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.waterColor = SIMD3<Float>(r, g, b)
                world.config = cfg
                return .success("watercolor set to (\(r), \(g), \(b))")
            },
            TerrainCommand(
                name: "fogcolor",
                description: "Fog color (r g b, 0.0-1.0 each)",
                usage: "fogcolor <r> <g> <b>"
            ) { args, ctx in
                guard args.count == 3,
                      let r = Float(args[0]), let g = Float(args[1]), let b = Float(args[2]),
                      (0...1).contains(r), (0...1).contains(g), (0...1).contains(b) else {
                    return .error("syntax error: usage: fogcolor <r> <g> <b>")
                }
                guard let world = ctx.getWorld() else { return .error("no world") }
                var cfg = world.config
                cfg.fogColor = SIMD3<Float>(r, g, b)
                world.config = cfg
                return .success("fogcolor set to (\(r), \(g), \(b))")
            },

            // MARK: - Devtools
            TerrainCommand(
                name: "/devtools",
                description: "Toggle the developer UI (current button panels)",
                usage: "/devtools"
            ) { args, ctx in
                // Handled specially by ContentView; this is a placeholder.
                // The actual toggle is done via the onDevtools callback.
                return .success("devtools toggled")
            },
        ]
    }

    /// Find a command by name (case-insensitive).
    static func find(_ name: String) -> TerrainCommand? {
        let lower = name.lowercased()
        return allCommands().first { $0.name.lowercased() == lower }
    }

    /// Search commands by prefix (for autocomplete).
    static func search(_ prefix: String) -> [TerrainCommand] {
        let lower = prefix.lowercased()
        if lower.isEmpty { return allCommands() }
        return allCommands().filter { $0.name.lowercased().hasPrefix(lower) }
    }
}
