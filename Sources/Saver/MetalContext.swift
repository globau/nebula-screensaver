import Foundation
import Metal

struct SetupError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

// gpu state shared by every view; legacyScreenSaver creates one view per screen
final class MetalContext {
    static let shared: MetalContext? = {
        do {
            return try MetalContext()
        } catch {
            NSLog("nebula: metal setup failed: \(error)")
            return nil
        }
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let nebulaPipeline: MTLRenderPipelineState
    let resolvePipeline: MTLRenderPipelineState
    let bloomDownPipeline: MTLRenderPipelineState
    let bloomUpPipeline: MTLRenderPipelineState
    let finalPipeline: MTLRenderPipelineState
    let noise: MTLTexture
    let sheet: MTLTexture

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SetupError("no metal device")
        }
        self.device = device
        self.queue = queue

        let library = try Self.compileShaders(device: device)
        func pipeline(_ fragment: String, _ formats: MTLPixelFormat...,
                      additive: Bool = false) throws -> MTLRenderPipelineState {
            guard let v = library.makeFunction(name: "fullscreenVertex"),
                  let f = library.makeFunction(name: fragment) else {
                throw SetupError("missing function \(fragment)")
            }
            return try Self.makePipeline(device: device, vertex: v, fragment: f, formats: formats, additive: additive)
        }

        let hdr = Tuning.hdrFormat
        nebulaPipeline = try pipeline("nebulaFragment", hdr, Tuning.depthFormat)
        resolvePipeline = try pipeline("resolveFragment", hdr)
        bloomDownPipeline = try pipeline("bloomDownsample", hdr)
        bloomUpPipeline = try pipeline("bloomUpsample", hdr, additive: true)
        finalPipeline = try pipeline("finalFragment", Tuning.colourFormat)

        guard let kernel = library.makeFunction(name: "generateNoise") else { throw SetupError("missing noise kernel") }
        (noise, sheet) = try Self.makeNoise(device: device, queue: queue, kernel: kernel)
    }

    // compiled at runtime from source because the offline metal toolchain is not installed
    private static func compileShaders(device: MTLDevice) throws -> MTLLibrary {
        guard let url = Bundle(for: MetalContext.self).url(forResource: "Shaders", withExtension: "metal") else {
            throw SetupError("Shaders.metal missing from bundle")
        }
        let options = MTLCompileOptions()
        options.preprocessorMacros = Tuning.shaderMacros
        return try device.makeLibrary(source: try String(contentsOf: url, encoding: .utf8), options: options)
    }

    private static func makePipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction,
                                     formats: [MTLPixelFormat], additive: Bool) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        for (i, format) in formats.enumerated() {
            descriptor.colorAttachments[i].pixelFormat = format
        }
        let attachment = descriptor.colorAttachments[0]!
        if additive {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // tileable fbm fields baked once: two scalar fields in an rg texture, and a field with its
    // gradient in an rgba texture for the sheets
    private static func makeNoise(device: MTLDevice, queue: MTLCommandQueue,
                                  kernel: MTLFunction) throws -> (MTLTexture, MTLTexture) {
        func volume(_ format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = format
            descriptor.width = Tuning.noiseSize
            descriptor.height = Tuning.noiseSize
            descriptor.depth = Tuning.noiseSize
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        let pipeline = try device.makeComputePipelineState(function: kernel)
        guard let noise = volume(.rg16Float), let sheet = volume(.rgba16Float),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw SetupError("noise generation setup failed")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(noise, index: 0)
        encoder.setTexture(sheet, index: 1)
        let size = MTLSize(width: Tuning.noiseSize, height: Tuning.noiseSize, depth: Tuning.noiseSize)
        encoder.dispatchThreads(size, threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return (noise, sheet)
    }
}
