import AppKit
import QuartzCore
import ScreenSaver

@objc(NebulaView)
final class NebulaView: ScreenSaverView {
    private var renderer: Renderer?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var stopObserver: NSObjectProtocol?

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        link?.invalidate()
        if let stopObserver {
            DistributedNotificationCenter.default().removeObserver(stopObserver)
        }
    }

    private func setUp() {
        animationTimeInterval = 1
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        if let context = MetalContext.shared, let metalLayer {
            metalLayer.device = context.device
            metalLayer.pixelFormat = Tuning.colourFormat
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = true
            metalLayer.maximumDrawableCount = 3
            metalLayer.backgroundColor = NSColor.black.cgColor
            // each launch and each screen gets its own flight
            renderer = Renderer(context: context, seed: UInt64.random(in: .min ... .max))
        }

        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopAnimation()
        }
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    override func startAnimation() {
        super.startAnimation()
        guard link == nil, renderer != nil else { return }
        updateDrawableSize()
        lastTimestamp = nil
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Tuning.frameRate, maximum: Tuning.frameRate, preferred: Tuning.frameRate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func stopAnimation() {
        super.stopAnimation()
        link?.invalidate()
        link = nil
    }

    override func animateOneFrame() {}

    override func draw(_ rect: NSRect) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer, let renderer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: width, height: height)
        renderer.resize(width: width, height: height, pixelScale: Float(scale))
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let renderer, let metalLayer, let context = MetalContext.shared else { return }
        let now = link.targetTimestamp
        renderer.advance(by: lastTimestamp.map { min(max(now - $0, 0), 0.1) } ?? 1.0 / Double(Tuning.frameRate))
        lastTimestamp = now

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = context.queue.makeCommandBuffer() else { return }
        renderer.encode(into: commandBuffer, target: drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
