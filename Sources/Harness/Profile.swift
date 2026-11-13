import Foundation
import Metal

func runProfile(_ options: Options, directory: URL) throws {
    guard options.width > 0, options.height > 0, options.scale.isFinite, options.scale > 0,
          options.time.isFinite, options.warmup.isFinite, options.duration.isFinite,
          options.warmup >= 0, options.time >= options.warmup, options.duration > 0 else {
        throw SetupError("profile requires positive size, scale and duration, and time >= warmup >= 0")
    }
    guard let context = MetalContext.shared else { throw SetupError("metal unavailable") }
    let renderer = Renderer(context: context, seed: options.seed)
    renderer.resize(width: options.width, height: options.height, pixelScale: options.scale)
    guard renderer.hasRenderTargets else { throw SetupError("profile render target allocation failed") }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: Tuning.colourFormat, width: options.width, height: options.height, mipmapped: false)
    descriptor.usage = .renderTarget
    descriptor.storageMode = .private
    guard let target = context.device.makeTexture(descriptor: descriptor) else {
        throw SetupError("profile target allocation failed")
    }

    let step = 1 / Double(Tuning.frameRate)
    let startFrame = Int((options.time / step).rounded())
    let warmupFrames = min(startFrame, Int((options.warmup / step).rounded()))
    for _ in 0..<(startFrame - warmupFrames) { renderer.advance(by: step) }

    func frame() throws -> Double {
        try autoreleasepool {
            guard let buffer = context.queue.makeCommandBuffer() else {
                throw SetupError("profile command buffer allocation failed")
            }
            renderer.advance(by: step)
            renderer.encode(into: buffer, target: target)
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status == .completed else {
                throw SetupError("profile gpu command failed: \(String(describing: buffer.error))")
            }
            return buffer.gpuEndTime - buffer.gpuStartTime
        }
    }

    func pace(until deadline: Double) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    func renderFrames(_ count: Int) throws -> (elapsed: Double, gpuTime: Double) {
        let started = ProcessInfo.processInfo.systemUptime
        var deadline = started
        var gpuTime = 0.0
        for _ in 0..<count {
            deadline += step
            gpuTime += try frame()
            pace(until: deadline)
            deadline = max(deadline, ProcessInfo.processInfo.systemUptime - step)
        }
        return (ProcessInfo.processInfo.systemUptime - started, gpuTime)
    }
    _ = try renderFrames(warmupFrames)
    let settings = """
    mode: offscreen, private target, one frame in flight
    size: \(options.width)x\(options.height)
    scale: \(options.scale)
    seed: \(options.seed)
    frame rate: \(Tuning.frameRate)
    flight start: \(Double(startFrame) * step) s
    flight duration: \(options.duration) s
    warmup: \(Double(warmupFrames) * step) s

    """
    try settings.write(to: directory.appendingPathComponent("renderer.txt"), atomically: true, encoding: .utf8)
    try Data().write(to: directory.appendingPathComponent("ready"))
    let timeout = ProcessInfo.processInfo.systemUptime + 60
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("start").path) {
        guard ProcessInfo.processInfo.systemUptime < timeout else { throw SetupError("profile start timed out") }
        Thread.sleep(forTimeInterval: 0.01)
    }

    let frames = max(1, Int((options.duration / step).rounded()))
    let measured = try renderFrames(frames)
    let fps = Double(frames) / measured.elapsed
    let result = String(format: "frames: %d\nwall time: %.3f s\nachieved frame rate: %.2f\ngpu time: %.3f ms/frame\n",
                        frames, measured.elapsed, fps, measured.gpuTime / Double(frames) * 1000)
    try result.write(to: directory.appendingPathComponent("rendering.txt"), atomically: true, encoding: .utf8)
    guard fps >= Double(Tuning.frameRate) * 0.98 else {
        throw SetupError("profile could not sustain the requested frame rate; see rendering.txt")
    }
}
