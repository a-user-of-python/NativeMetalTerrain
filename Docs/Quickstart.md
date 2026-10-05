# MetalTerrain Quickstart

Get a live 3D terrain rendering in about five minutes. This guide assumes an
existing iOS app target in Xcode 16+ and a view where you can put an `MTKView`.

---

## 1. Add the package (1 minute)

MetalTerrain is a plain Swift package — no dependencies.

**In Xcode:**

1. File → Add Package Dependencies…
2. Enter the repository URL (or use **Add Local…** and point at this folder while developing).
3. Add `MetalTerrain` to your app target.

**In `Package.swift`** (if your app is itself a package):

```swift
dependencies: [
    .package(url: "<repository-url>", from: "1.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["MetalTerrain"]),
]
```

No extra setup, no plist keys, no capabilities to enable.

---

## 2. Ten lines to your first terrain (2 minutes)

Put an `MTKView` in your view hierarchy (Storyboard, SwiftUI via
`UIViewRepresentable`, or programmatically) and give its delegate/coordinator
access to a renderer you create once:

```swift
import MetalTerrain
import MetalKit

final class TerrainScene {
    let device: MTLDevice
    let world: MTTerrainWorld
    let renderer: MTTerrainRenderer

    init(view: MTKView) {
        device = MTLCreateSystemDefaultDevice()!
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float

        world = MTTerrainWorld(seed: 1337)
        renderer = MTTerrainRenderer(device: device, world: world)

        renderer.setCamera(position: [0, 220, 320], target: [0, 0, 0],
                           fovDegrees: 60, aspect: Float(view.bounds.width / view.bounds.height),
                           near: 0.1, far: 6000)
    }

    func frame(view: MTKView) {
        renderer.update(cameraTarget: SIMD2(0, 0))  // streams chunks around this point
        renderer.draw(in: view)
    }
}
```

Wire `frame(view:)` into `MTKViewDelegate.draw(in:)`. That's it — you now have
an endless seeded world with mountains, beaches, oceans, forests, and scattered
structures.

**SwiftUI note:** wrap `MTKView` in a `UIViewRepresentable`, create one
`TerrainScene` in the coordinator, and call `frame(view:)` from the delegate.
The demo app (`Demo/TerrainDemo`) is a complete working example — read it first
if anything here feels unclear.

---

## 3. Camera setup (1 minute)

`setCamera(position:target:fovDegrees:aspect:near:far:)` is the only camera API:

| Parameter | What it does | Starting value |
|---|---|---|
| `position` | Where the camera sits (world units) | `[0, 220, 320]` — high and back |
| `target` | What it looks at | `[0, 0, 0]` — the world origin |
| `fovDegrees` | Field of view | `60` — natural perspective |
| `aspect` | Width ÷ height of the view | From `view.bounds` |
| `near` | Nearest visible distance | `0.1` |
| `far` | Farthest visible distance | `6000` — must exceed your view distance |

Three rules that save you debugging time:

1. **Update `aspect` on rotation/resize.** Call `setCamera` again with the new
   bounds ratio, or your terrain will stretch.
2. **`far` must cover the visible world.** With the default config, chunks reach
   `viewDistance (6) × chunkWorldSize (128) ≈ 768` units from the target, plus
   fog fades beyond that — `6000` is generous and safe.
3. **Keep the camera above the terrain.** `world.heightAt(x:z:)` gives the
   normalized height at any point; `world.worldY(forHeight:)` converts it to
   world units so you can clamp your camera: `camera.y = max(camera.y, groundY + 5)`.

`update(cameraTarget:)` streams chunks around the camera target each frame —
pass the point your camera is looking at (as XZ) and the world pages itself in.

---

## 4. Common first tweaks (1 minute)

Once it renders, these are the changes everyone makes first:

```swift
// A different world: just change the seed
world = MTTerrainWorld(seed: 424242)

// More (or fewer) chunks visible — bigger number, farther horizon
var config = MTTerrainConfig.default
config.viewDistance = 8
world.config = config

// Turn off structures for a clean landscape study
world.structuresEnabled = false

// Debug the mesh itself
renderer.wireframe = true

// Hide the water plane
renderer.showsWater = false

// Islands everywhere: raise the sea level
var islandConfig = MTTerrainConfig.default
islandConfig.seaLevel = 0.58
world.config = islandConfig
```

Next steps:

- **Make your own biomes** — [BiomeAuthoring.md](BiomeAuthoring.md): deserts, lava fields, alien worlds, higher mountains.
- **Reshape the planet** — [NoiseTuning.md](NoiseTuning.md): archipelagos, jagged peaks, rolling hills, canyonlands.
- **Keep it at 60 fps** — [PerformanceGuide.md](PerformanceGuide.md): chunk budgets, per-device settings, memory math.
- **Full API details** — [APIReference.md](APIReference.md).

## Troubleshooting

- **Black screen:** check `view.device` is set, `colorPixelFormat` is `.bgra8Unorm`, and `far` is large enough. Try `renderer.wireframe = true` to see if geometry exists.
- **Everything is water (or nothing is):** your `seaLevel` is probably wrong for the noise config — defaults are tuned to each other. See [NoiseTuning.md](NoiseTuning.md).
- **Stretched image after rotation:** you didn't update `aspect` in `setCamera`. Re-call it on bounds change.
- **Low frame rate:** see [PerformanceGuide.md](PerformanceGuide.md) — start with a smaller `viewDistance`.
