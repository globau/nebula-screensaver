import simd

// mirrors of the structs in Shaders.metal; all members are float4 so the layouts match exactly

struct Uniforms {
    var camera: SIMD4<Float>          // xyz wrapped position, w time
    var right: SIMD4<Float>           // xyz basis, w tan(half fov x)
    var up: SIMD4<Float>              // xyz basis, w tan(half fov y)
    var forward: SIMD4<Float>         // xyz basis, w unused
    var viewport: SIMD4<Float>        // target width, height, nebula width, height
    var params: SIMD4<Float>          // pixel scale, frame index, bloom levels, unused
    var post: SIMD4<Float>            // exposure, bloom strength, chromatic aberration, grain
    var previousRight: SIMD4<Float>   // last frame's basis, w tan(half fov x)
    var previousUp: SIMD4<Float>      // w tan(half fov y)
    var previousForward: SIMD4<Float> // w 1 if the nebula history is valid
    var motion: SIMD4<Float>          // xyz camera displacement since last frame, w weight of the new frame
    var jitter: SIMD4<Float>          // xy nebula ray offset in nebula pixels, zw history width, height
    var pocket: SIMD4<Float>          // xyz camera offset from the pocket centre (unwrapped), w radius
}

struct BloomStep {
    var texel: SIMD4<Float>   // xy inverse target size, zw inverse source size
    var options: SIMD4<Float> // x 1 to apply the karis average
}
