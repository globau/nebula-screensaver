import Metal
import simd

// per-view state: camera, render targets and frame encoding
//
// passes: nebula raymarch at point resolution -> temporal resolve against reprojected history
// -> bloom down and up chain -> final lens effects and tonemap into the drawable
final class Renderer {
    private struct Targets {
        let nebula: MTLTexture
        let depth: MTLTexture
        let history: [MTLTexture]
        let bloom: [MTLTexture]
    }

    private struct View {
        let basis: CameraBasis
        let position: SIMD3<Double>
        let tanX: Double
        let tanY: Double
    }

    private let context: MetalContext
    private var camera: Camera
    private var targets: Targets?
    private var previous: View?
    private var size = (width: 0, height: 0)
    private var pixelScale: Float = 1
    private var frame: UInt32 = 0
    private let pocketCentre: SIMD3<Double>

    init(context: MetalContext, seed: UInt64) {
        self.context = context
        camera = Camera(seed: seed)
        pocketCentre = camera.worldPosition - camera.basis.forward * Tuning.pocketOffset
    }

    func resize(width: Int, height: Int, pixelScale: Float) {
        guard width > 0, height > 0, (width, height) != size || pixelScale != self.pixelScale else { return }
        size = (width, height)
        self.pixelScale = pixelScale
        previous = nil
        targets = nil
        func scaled(_ divisor: Float) -> (Int, Int) {
            (max(1, Int(Float(width) / (divisor * pixelScale))), max(1, Int(Float(height) / (divisor * pixelScale))))
        }
        let (nw, nh) = scaled(Tuning.nebulaPointDivisor)
        let (hw, hh) = scaled(Tuning.historyPointDivisor)
        guard let nebula = makeTarget(nw, nh), let depth = makeTarget(nw, nh, format: Tuning.depthFormat),
              let historyA = makeTarget(hw, hh), let historyB = makeTarget(hw, hh) else { return }
        var bloom: [MTLTexture] = []
        var (w, h) = (hw, hh)
        while bloom.count < Tuning.bloomLevels && (w > 1 || h > 1) {
            (w, h) = (max(1, w / 2), max(1, h / 2))
            guard let level = makeTarget(w, h) else { break }
            bloom.append(level)
        }
        guard !bloom.isEmpty else { return }
        targets = Targets(nebula: nebula, depth: depth, history: [historyA, historyB], bloom: bloom)
    }

    func advance(by dt: Double) {
        camera.advance(by: dt)
    }

    func encode(into commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        guard let targets else { return }
        let view = currentView()
        var uniforms = makeUniforms(targets, view: view)
        let length = MemoryLayout<Uniforms>.stride
        let resolved = targets.history[Int(frame % 2)]
        let lastResolved = targets.history[Int((frame + 1) % 2)]
        previous = view
        frame &+= 1

        let nebulaPass = MTLRenderPassDescriptor()
        for (i, texture) in [targets.nebula, targets.depth].enumerated() {
            nebulaPass.colorAttachments[i].texture = texture
            nebulaPass.colorAttachments[i].loadAction = .dontCare
            nebulaPass.colorAttachments[i].storeAction = .store
        }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: nebulaPass) {
            encoder.setRenderPipelineState(context.nebulaPipeline)
            encoder.setFragmentBytes(&uniforms, length: length, index: 0)
            encoder.setFragmentTexture(context.noise, index: 0)
            encoder.setFragmentTexture(context.sheet, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        render(commandBuffer, into: resolved) { encoder in
            encoder.setRenderPipelineState(context.resolvePipeline)
            encoder.setFragmentBytes(&uniforms, length: length, index: 0)
            encoder.setFragmentTexture(targets.nebula, index: 0)
            encoder.setFragmentTexture(targets.depth, index: 1)
            encoder.setFragmentTexture(lastResolved, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        for (i, level) in targets.bloom.enumerated() {
            let source = i == 0 ? resolved : targets.bloom[i - 1]
            bloomStep(commandBuffer, pipeline: context.bloomDownPipeline, from: source, to: level,
                      karis: i == 0, load: false)
        }
        for i in stride(from: targets.bloom.count - 2, through: 0, by: -1) {
            bloomStep(commandBuffer, pipeline: context.bloomUpPipeline, from: targets.bloom[i + 1],
                      to: targets.bloom[i], karis: false, load: true)
        }

        render(commandBuffer, into: target) { encoder in
            encoder.setRenderPipelineState(context.finalPipeline)
            encoder.setFragmentBytes(&uniforms, length: length, index: 0)
            encoder.setFragmentTexture(resolved, index: 0)
            encoder.setFragmentTexture(targets.bloom[0], index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    private func bloomStep(_ commandBuffer: MTLCommandBuffer, pipeline: MTLRenderPipelineState,
                           from source: MTLTexture, to target: MTLTexture, karis: Bool, load: Bool) {
        var step = BloomStep(
            texel: SIMD4(1 / Float(target.width), 1 / Float(target.height),
                         1 / Float(source.width), 1 / Float(source.height)),
            options: SIMD4(karis ? 1 : 0, 0, 0, 0))
        render(commandBuffer, into: target, load: load) { encoder in
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&step, length: MemoryLayout<BloomStep>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    private func render(_ commandBuffer: MTLCommandBuffer, into texture: MTLTexture, load: Bool = false,
                        _ body: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = load ? .load : .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        body(encoder)
        encoder.endEncoding()
    }

    private func makeTarget(_ width: Int, _ height: Int, format: MTLPixelFormat = Tuning.hdrFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return context.device.makeTexture(descriptor: descriptor)
    }

    private func currentView() -> View {
        let tanY = tan(Tuning.verticalFov / 2)
        return View(basis: camera.basis, position: camera.worldPosition,
                    tanX: tanY * Double(size.width) / Double(size.height), tanY: tanY)
    }

    private func makeUniforms(_ targets: Targets, view: View) -> Uniforms {
        func pack(_ v: SIMD3<Double>, _ w: Double) -> SIMD4<Float> { SIMD4(SIMD3<Float>(v), Float(w)) }
        let last = previous ?? view
        return Uniforms(
            camera: pack(camera.position, camera.time),
            right: pack(view.basis.right, view.tanX),
            up: pack(view.basis.up, view.tanY),
            forward: pack(view.basis.forward, 0),
            viewport: SIMD4(Float(size.width), Float(size.height),
                            Float(targets.nebula.width), Float(targets.nebula.height)),
            params: SIMD4(pixelScale, Float(frame % 1024), Float(targets.bloom.count), 0),
            post: SIMD4(Tuning.exposure, Tuning.bloomStrength, Tuning.chromaticAberration, Tuning.grain),
            previousRight: pack(last.basis.right, last.tanX),
            previousUp: pack(last.basis.up, last.tanY),
            previousForward: pack(last.basis.forward, previous == nil ? 0 : 1),
            motion: pack(view.position - last.position, Double(Tuning.temporalBlend)),
            jitter: SIMD4(Self.halton(Int(frame % 16) + 1, 2) - 0.5, Self.halton(Int(frame % 16) + 1, 3) - 0.5,
                          Float(targets.history[0].width), Float(targets.history[0].height)),
            pocket: pack(view.position - pocketCentre, Tuning.pocketRadius))
    }

    private static func halton(_ index: Int, _ base: Int) -> Float {
        var (i, f, r): (Int, Float, Float) = (index, 1, 0)
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }
}
