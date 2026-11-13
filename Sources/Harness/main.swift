import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers

struct Options {
    var snapshot: String?
    var time: Double = 20
    var width = 2880
    var height = 1800
    var scale: Float = 2
    // fixed by default so successive snapshots show the same view
    var seed: UInt64 = 1

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--snapshot": snapshot = it.next()
            case "--time": time = it.next().flatMap(Double.init) ?? time
            case "--scale": scale = it.next().flatMap(Float.init) ?? scale
            case "--seed": seed = it.next().flatMap { UInt64($0) } ?? seed
            case "--size":
                let parts = (it.next() ?? "").split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { (width, height) = (parts[0], parts[1]) }
            default: break
            }
        }
    }
}

func writeSnapshot(_ options: Options, to path: String) throws {
    guard let context = MetalContext.shared else { throw SetupError("metal unavailable") }
    let renderer = Renderer(context: context, seed: options.seed)
    renderer.resize(width: options.width, height: options.height, pixelScale: options.scale)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: Tuning.colourFormat, width: options.width, height: options.height, mipmapped: false)
    descriptor.usage = [.renderTarget]
    descriptor.storageMode = .shared
    guard let target = context.device.makeTexture(descriptor: descriptor) else { throw SetupError("snapshot setup failed") }

    // the last frames are rendered so the nebula's temporal history has converged
    let step = 1.0 / Double(Tuning.frameRate)
    let frames = Int(options.time / step)
    let warmup = min(frames, 60)
    for _ in 0..<(frames - warmup) { renderer.advance(by: step) }
    var last: MTLCommandBuffer?
    for _ in 0..<warmup {
        renderer.advance(by: step)
        guard let buffer = context.queue.makeCommandBuffer() else { throw SetupError("snapshot setup failed") }
        renderer.encode(into: buffer, target: target)
        buffer.commit()
        last = buffer
    }
    last?.waitUntilCompleted()
    let bytesPerRow = options.width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * options.height)
    target.getBytes(&pixels, bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, options.width, options.height), mipmapLevel: 0)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: options.width, height: options.height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else {
        throw SetupError("png encoding failed")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw SetupError("png write failed") }
    reportGPUTime(renderer: renderer, context: context, target: target)
}

func reportGPUTime(renderer: Renderer, context: MetalContext, target: MTLTexture) {
    let frames = 60
    var total = 0.0
    for _ in 0..<frames {
        guard let buffer = context.queue.makeCommandBuffer() else { return }
        renderer.advance(by: 1.0 / Double(Tuning.frameRate))
        renderer.encode(into: buffer, target: target)
        buffer.commit()
        buffer.waitUntilCompleted()
        total += buffer.gpuEndTime - buffer.gpuStartTime
    }
    print(String(format: "gpu time: %.2f ms/frame (%dx%d)", total / Double(frames) * 1000, target.width, target.height))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Nebula"
        guard let view = NebulaView(frame: frame, isPreview: false) else { NSApp.terminate(nil); return }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        view.startAnimation()
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
if let path = options.snapshot {
    do {
        try writeSnapshot(options, to: path)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Nebula", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
app.mainMenu = NSMenu()
app.mainMenu?.addItem(appMenuItem)
app.setActivationPolicy(.regular)
app.run()
