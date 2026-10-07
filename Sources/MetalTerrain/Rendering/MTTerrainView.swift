import MetalKit

/// A ready-to-use MTKView that renders a MetalTerrain world.
///
/// This is the library's answer to "the app shouldn't do Metal work":
/// drop an `MTTerrainView` into your view hierarchy, assign a world, and
/// drive the camera. Device setup, pixel formats, the render loop, FPS
/// tracking, and chunk streaming are all handled internally.
///
/// ```swift
/// let terrainView = MTTerrainView(frame: view.bounds)
/// terrainView.world = MTTerrainWorld(seed: 1234, config: .default)
/// view.addSubview(terrainView)
///
/// // Per frame (e.g. from a display link or MTKView delegate):
/// terrainView.setCamera(position: eye, target: lookAt,
///                       fovDegrees: 55, aspect: aspect, near: 1, far: 4000)
/// ```
///
/// For full control, use `MTTerrainRenderer` directly with your own MTKView.
public final class MTTerrainView: MTKView {

    /// The world being rendered. Assigning a new world rebuilds the renderer.
    public var world: MTTerrainWorld? {
        didSet {
            guard let device = self.device, let world else {
                renderer = nil
                return
            }
            let r = MTTerrainRenderer(device: device, world: world)
            // Carry over display settings from the previous renderer.
            if let old = renderer {
                r.wireframe = old.wireframe
                r.showsWater = old.showsWater
                r.fogEnabled = old.fogEnabled
                r.shaderEffectsEnabled = old.shaderEffectsEnabled
                r.sunAzimuth = old.sunAzimuth
                r.sunElevation = old.sunElevation
            }
            renderer = r
        }
    }

    /// The renderer. Nil until `world` is assigned.
    public private(set) var renderer: MTTerrainRenderer?

    /// Last measured FPS (exponential moving average).
    public private(set) var fps: Double = 60

    /// Called every frame after rendering. Use it to update the camera,
    /// move the player, or sync UI. Runs on the main thread.
    public var onFrame: ((MTTerrainView, TimeInterval) -> Void)?

    private var lastFrameTime: CFTimeInterval = 0

    // MARK: - Init

    public override init(frame: CGRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: dev)
        commonInit()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = self.device ?? MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        precondition(device != nil, "MTTerrainView: no Metal device available")
        delegate = self
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0.04, green: 0.06, blue: 0.11, alpha: 1.0)
    }

    /// v1.2.0: when true, removes the 60fps cap (renders as fast as possible).
    /// On ProMotion displays this can reach 120fps.
    public var uncappedFPS: Bool = false {
        didSet {
            preferredFramesPerSecond = uncappedFPS ? 0 : 60
        }
    }

    // MARK: - Camera

    /// Sets the camera. Call every frame (or from `onFrame`) before draw.
    public func setCamera(position: SIMD3<Float>, target: SIMD3<Float>,
                          fovDegrees: Float = 55, aspect: Float,
                          near: Float = 1, far: Float = 4000) {
        renderer?.setCamera(position: position, target: target,
                            fovDegrees: fovDegrees, aspect: aspect,
                            near: near, far: far)
        renderer?.update(cameraTarget: SIMD2<Float>(target.x, target.z))
    }

    // MARK: - Display settings (forwarded to the renderer)

    public var wireframe: Bool {
        get { renderer?.wireframe ?? false }
        set { renderer?.wireframe = newValue }
    }

    public var showsWater: Bool {
        get { renderer?.showsWater ?? true }
        set { renderer?.showsWater = newValue }
    }

    public var fogEnabled: Bool {
        get { renderer?.fogEnabled ?? true }
        set { renderer?.fogEnabled = newValue }
    }

    public var shaderEffectsEnabled: Bool {
        get { renderer?.shaderEffectsEnabled ?? false }
        set { renderer?.shaderEffectsEnabled = newValue }
    }

    public var sunAzimuth: Float {
        get { renderer?.sunAzimuth ?? 45 }
        set { renderer?.sunAzimuth = newValue }
    }

    public var sunElevation: Float {
        get { renderer?.sunElevation ?? 50 }
        set { renderer?.sunElevation = newValue }
    }

    public var viewDistance: Int {
        get { renderer?.viewDistance ?? 6 }
        set { renderer?.viewDistance = newValue }
    }

    /// The skybox (sky + visible sun). Nil until `world` is assigned.
    public var skybox: MTSkybox? { renderer?.skybox }

    /// True when the Metal 4 pipeline is active (false = Metal 3 fallback).
    public var usesMetal4: Bool { renderer?.usesMetal4 ?? false }

    #if M3_FEATURES
    /// Master switch for the mesh-shading path (M3+/A17 Pro+ only).
    public var meshShadingEnabled: Bool {
        get { renderer?.meshShadingEnabled ?? false }
        set { renderer?.meshShadingEnabled = newValue }
    }
    /// True when hardware ray tracing is active this frame.
    public var rayTracingActive: Bool {
        renderer?.rayTracing?.topLevelStructure != nil
    }
    #endif
}

// MARK: - MTKViewDelegate

extension MTTerrainView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Aspect is read from drawableSize every frame in draw(in:).
    }

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt: TimeInterval
        if lastFrameTime > 0 {
            dt = now - lastFrameTime
            if dt > 0 { fps = fps * 0.92 + (1.0 / dt) * 0.08 }
        } else {
            dt = 0
        }
        lastFrameTime = now

        onFrame?(self, dt)
        renderer?.draw(in: view)
        renderer?.currentFPS = fps
    }
}
