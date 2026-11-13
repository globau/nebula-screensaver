import Metal

enum Tuning {
    static let speed: Double = 5
    // the motion is slow enough that 30 fps reads smoothly at half the gpu power of 60
    static let frameRate: Float = 30
    static let verticalFov: Double = 60 * .pi / 180
    // the nebula is raymarched at a coarser resolution with jittered rays and accumulated into
    // a finer history
    static let nebulaPointDivisor: Float = 2
    static let historyPointDivisor: Float = 1
    static let noiseSize = 128
    static let colourFormat = MTLPixelFormat.bgra8Unorm
    static let hdrFormat = MTLPixelFormat.rgba16Float
    static let depthFormat = MTLPixelFormat.r32Float

    // weight of each new nebula frame against the reprojected history, scaled per history pixel
    // by how close the frame's jittered sample landed
    static let temporalBlend: Float = 0.12

    static let exposure: Float = 1.2
    static let bloomStrength: Float = 0.04
    static let bloomLevels = 6
    static let chromaticAberration: Float = 0.006
    static let grain: Float = 0.015

    // the flight starts inside an empty pocket, its centre this far behind the start, and flies
    // out through its ragged, glowing wall into the nebula
    static let pocketRadius: Double = 290
    static let pocketOffset: Double = 50
    // the camera crosses the pocket fast, easing down to cruising speed as it reaches the nebula;
    // the extra speed starts at speed * introBoost and fades out over introDuration seconds
    static let introBoost: Double = 5
    static let introDuration: Double = 15

    // the camera position wraps at this period; every noise tile the shader uses is a whole
    // fraction of it so the wrap is seamless
    static let worldPeriod: Double = 800

    static var shaderMacros: [String: NSObject] {
        ["WORLD_PERIOD": NSNumber(value: worldPeriod)]
    }
}
