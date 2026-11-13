#include <metal_stdlib>
using namespace metal;

// WORLD_PERIOD is injected from Tuning.shaderMacros
#if !defined(WORLD_PERIOD)
#error "shader macros missing"
#endif

// mirrors of GPUTypes.swift

struct Uniforms {
    float4 camera;          // xyz wrapped position, w time
    float4 right;           // xyz basis, w tan(half fov x)
    float4 up;              // xyz basis, w tan(half fov y)
    float4 forward;         // xyz basis, w unused
    float4 viewport;        // target width, height, nebula width, height
    float4 params;          // pixel scale, frame index, bloom levels, unused
    float4 post;            // exposure, bloom strength, chromatic aberration, grain
    float4 previousRight;   // last frame's basis, w tan(half fov x)
    float4 previousUp;      // w tan(half fov y)
    float4 previousForward; // w 1 if the nebula history is valid
    float4 motion;          // xyz camera displacement since last frame, w weight of the new frame
    float4 jitter;          // xy nebula ray offset in nebula pixels, zw history width, height
    float4 pocket;          // xyz camera offset from the pocket centre (unwrapped), w radius
};

struct BloomStep {
    float4 texel;   // xy inverse target size, zw inverse source size
    float4 options; // x 1 to apply the karis average
};

constexpr sampler noiseSampler(filter::linear, address::repeat);
constexpr sampler screenSampler(filter::linear, address::clamp_to_edge);

// ---- shared helpers ----

static float ign(float2 p) {
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

static uint hashU(uint3 p, uint seed) {
    uint h = (p.x * 0x8da6b343u) ^ (p.y * 0xd8163841u) ^ (p.z * 0xcb1ab31fu) ^ (seed * 0x9e3779b9u);
    h ^= h >> 15; h *= 0x2c1b3c6du;
    h ^= h >> 12; h *= 0x297a2d39u;
    h ^= h >> 15;
    return h;
}

static float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// ---- noise volume, baked once at start-up ----

static float3 gradient(uint3 p, uint seed) {
    uint h = hashU(p, seed);
    float3 g = float3(float(h & 0x3ffu), float((h >> 10) & 0x3ffu), float((h >> 20) & 0x3ffu)) / 511.5 - 1.0;
    return normalize(g + 1e-4);
}

static float periodicPerlin(float3 x, uint period, uint seed) {
    float3 i = floor(x);
    float3 f = x - i;
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    uint3 a = uint3(i) % period;
    uint3 b = (a + 1) % period;
    float v000 = dot(gradient(uint3(a.x, a.y, a.z), seed), f - float3(0, 0, 0));
    float v100 = dot(gradient(uint3(b.x, a.y, a.z), seed), f - float3(1, 0, 0));
    float v010 = dot(gradient(uint3(a.x, b.y, a.z), seed), f - float3(0, 1, 0));
    float v110 = dot(gradient(uint3(b.x, b.y, a.z), seed), f - float3(1, 1, 0));
    float v001 = dot(gradient(uint3(a.x, a.y, b.z), seed), f - float3(0, 0, 1));
    float v101 = dot(gradient(uint3(b.x, a.y, b.z), seed), f - float3(1, 0, 1));
    float v011 = dot(gradient(uint3(a.x, b.y, b.z), seed), f - float3(0, 1, 1));
    float v111 = dot(gradient(uint3(b.x, b.y, b.z), seed), f - float3(1, 1, 1));
    return mix(mix(mix(v000, v100, u.x), mix(v010, v110, u.x), u.y),
               mix(mix(v001, v101, u.x), mix(v011, v111, u.x), u.y), u.z);
}

// three octaves only, so the finest wavelength spans eight texels and stays smooth under
// trilinear filtering; filament geometry is derived from its gradients
static float fbm(float3 p, uint seed) {
    float sum = 0, amp = 0.5, norm = 0;
    uint period = 4;
    for (uint o = 0; o < 3; o++) {
        sum += amp * periodicPerlin(p * float(period), period, seed + o * 31u);
        norm += amp;
        amp *= 0.35;
        period *= 2;
    }
    return sum / norm;
}

// noise: two independent fields in rg. sheet: one field with its gradient (per unit texture
// coordinate) in gba, so sheet distances need a single fetch
kernel void generateNoise(texture3d<float, access::write> noise [[texture(0)]],
                          texture3d<float, access::write> sheet [[texture(1)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint size = noise.get_width();
    if (any(gid >= size)) return;
    float3 p = (float3(gid) + 0.5) / float(size);
    float a = fbm(p, 1u);
    float b = fbm(p, 977u);
    noise.write(float4(saturate(a * 1.4 + 0.5), saturate(b * 1.4 + 0.5), 0, 0), gid);

    const uint seed = 4231u;
    float h = 0.25 / float(size);
    float3 g = float3(fbm(p + float3(h, 0, 0), seed) - fbm(p - float3(h, 0, 0), seed),
                      fbm(p + float3(0, h, 0), seed) - fbm(p - float3(0, h, 0), seed),
                      fbm(p + float3(0, 0, h), seed) - fbm(p - float3(0, 0, h), seed)) / (2.0 * h);
    sheet.write(float4(fbm(p, seed) * 1.4 + 0.5, g * 1.4), gid);
}

// ---- fullscreen passes ----

struct FullscreenOut {
    float4 position [[position]];
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    return o;
}

static float3 viewRay(float2 position, float2 size, constant Uniforms &u) {
    float2 ndc = float2(position.x / size.x * 2.0 - 1.0, 1.0 - position.y / size.y * 2.0);
    return normalize(u.forward.xyz + ndc.x * u.right.w * u.right.xyz + ndc.y * u.up.w * u.up.xyz);
}

// ---- nebula: wrinkled emissive sheets, like the shock fronts of a supernova remnant ----
//
// a sheet is an isosurface of a noise field; its signed distance is (v - level) / |grad v| from
// one fetch of the baked field and gradient. emission is a thin gaussian slab integrated exactly
// across each march step from the distances at both ends, so sheets can be far thinner than a
// step. the column through a slab grows as 1/cos where the ray grazes it: face-on sheets are
// faint veils and edge-on ones crisp bright arcs and strands. nearby levels give layered sheets.

// all tiles divide WORLD_PERIOD so the field wraps with the camera
constant float shellTile = WORLD_PERIOD / 2.0;
constant float filigreeTile = WORLD_PERIOD / 8.0;
constant float warpTile = WORLD_PERIOD / 8.0;
constant float detailTile = WORLD_PERIOD / 32.0;
constant float regionTile = WORLD_PERIOD;

struct Sheet {
    float level;
    float width;      // half thickness in world units
    float brightness; // column brightness seen face-on
};

constant int shellCount = 5;
constant Sheet shells[shellCount] = {
    { 0.500, 0.030, 0.050 },
    { 0.515, 0.020, 0.030 },
    { 0.535, 0.025, 0.035 },
    { 0.482, 0.020, 0.025 },
    { 0.465, 0.015, 0.020 },
};

constant int filigreeCount = 3;
constant Sheet filigree[filigreeCount] = {
    { 0.50, 0.015, 0.016 },
    { 0.45, 0.012, 0.012 },
    { 0.56, 0.012, 0.012 },
};

struct NebulaOut {
    float4 colour [[color(0)]]; // rgb radiance
    float depth [[color(1)]];   // radiance-weighted distance, for reprojection
};

constant float nebulaFar = 1.0e4;

// a very faint glow at infinity so the darkest areas are not flat black
static float3 backdrop(float3 dir, texture3d<float> noise) {
    float2 a = noise.sample(noiseSampler, dir * 0.45 + 0.2).rg;
    return float3(0.0012, 0.0010, 0.0025) * (0.3 + a.x) + float3(0.004, 0.0006, 0.0008) * smoothstep(0.4, 0.9, a.y);
}

static float erfApprox(float x) {
    float x2 = x * x;
    float e = 1.0 - exp(-x2 * (1.27324 + 0.147 * x2) / (1.0 + 0.147 * x2));
    return copysign(sqrt(e), x);
}

struct Field {
    float value;
    float gradient; // world units
    float limb;     // extra edge-on brightening on top of the geometric 1/cos
};

static Field sampleField(texture3d<float> tex, float3 q, float tile, float3 dir, float base, float offset) {
    float4 s = tex.sample(noiseSampler, q);
    float3 g = s.gba / tile;
    float len = max(length(g), 1e-5);
    float rim = 1.0 - abs(dot(g, dir)) / len;
    return { s.r + offset, len, base + (1.0 - base) * rim * rim * rim };
}

// integral over a step of length len of the slab profile, normalised to unit face-on column,
// with the signed distance varying linearly from d0 to d1
static float crossing(float d0, float d1, float w, float len) {
    float dd = d1 - d0;
    if (abs(dd) < 1e-3 * w) {
        float m = 0.5 * (d0 + d1) / w;
        return len * exp(-m * m) / (1.7725 * w);
    }
    return len * (erfApprox(d1 / w) - erfApprox(d0 / w)) / (2.0 * dd);
}

struct Point {
    float2 region;
    float2 warp;
    float2 detail;
    Field shell;
    Field filigree;
};

static Point samplePoint(float3 p, float3 dir, texture3d<float> noise, texture3d<float> sheet) {
    Point o;
    o.region = noise.sample(noiseSampler, p / regionTile + 0.31).rg;
    o.warp = noise.sample(noiseSampler, p / warpTile + 0.57).rg;
    float3 pw = p + (float3(o.warp.x, o.warp.y, 1.0 - o.warp.x) - 0.5) * 6.0;
    o.detail = noise.sample(noiseSampler, pw / detailTile + 0.77).rg;
    // small scale wrinkles shift the shell level rather than the sample position
    o.shell = sampleField(sheet, pw / shellTile, shellTile, dir, 0.15, (o.detail.x - 0.5) * 0.015);
    // outside filigree patches the fetch is skipped; a far value means no crossing is found
    o.filigree = o.region.x > 0.52 ? sampleField(sheet, pw / filigreeTile + 0.43, filigreeTile, dir, 0.05, 0)
                                   : Field{ 10.0, 1.0, 0.0 };
    return o;
}

// the flight starts inside an empty pocket; this is the signed distance past its wall, bent into
// lobes by the warp field and frayed by the detail field so tendrils reach in ahead of the bulk
constant float pocketRag = 36.0; // furthest the wall reaches inside the radius
static float pocketDistance(float3 rel, Point p, float radius) {
    return length(rel) + (p.warp.y - 0.5) * 48.0 + (p.detail.y - 0.5) * 24.0 - radius;
}

fragment NebulaOut nebulaFragment(FullscreenOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture3d<float> noise [[texture(0)]],
                                  texture3d<float> sheetField [[texture(1)]]) {
    float3 dir = viewRay(in.position.xy + u.jitter.xy, u.viewport.zw, u);
    // sheets are only widened to the history's finer pixels; jitter and accumulation resolve them
    float pixelAngle = 2.0 * u.right.w / u.jitter.z;

    const float tMin = 0.3;
    const float tMax = 260.0;
    float jitter = ign(in.position.xy + u.params.y * 5.588238);
    float t = tMin;
    // nothing to gather until the ray can reach the pocket wall
    float3 pocket = u.pocket.xyz;
    float inner = u.pocket.w - pocketRag - 2.0;
    float along = dot(pocket, dir), excess = dot(pocket, pocket) - inner * inner;
    if (excess < 0) t = max(t, -along + sqrt(along * along - excess));

    const float3 shellBlue = float3(0.22, 0.48, 1.00);
    const float3 shellCyan = float3(0.45, 0.80, 1.00);
    const float3 gold = float3(1.00, 0.62, 0.12);
    const float3 ember = float3(1.00, 0.26, 0.07);
    const float3 hydrogen = float3(1.00, 0.10, 0.06);

    float3 colour = 0;
    float transmittance = 1;
    float depthSum = 0, depthWeight = 0;
    Point last = samplePoint(u.camera.xyz + dir * t, dir, noise, sheetField);
    for (int i = 0; i < 600 && t < tMax && transmittance > 0.02; i++) {
        float len = (0.25 + 0.018 * t) * (i == 0 ? 0.5 + jitter : 1.0);
        float tNext = t + len;
        Point next = samplePoint(u.camera.xyz + dir * tNext, dir, noise, sheetField);

        float tMid = t + 0.5 * len;
        float footprint = tMid * pixelAngle;
        float fade = smoothstep(tMin, 6.0, tMid) * (1.0 - smoothstep(tMax * 0.45, tMax, tMid));
        float3 gained = 0;

        // large layered shells, blue oxygen emission, everywhere but uneven
        float shellMask = mix(0.15, 1.0, smoothstep(0.35, 0.7, next.region.y)) * mix(0.3, 1.5, next.detail.x);
        float3 shellColour = mix(shellBlue, shellCyan, smoothstep(0.3, 0.7, next.warp.x));
        for (int k = 0; k < shellCount; k++) {
            constant Sheet &s = shells[k];
            float w = max(s.width, footprint);
            float c = crossing((last.shell.value - s.level) / last.shell.gradient,
                               (next.shell.value - s.level) / next.shell.gradient, w, len);
            gained += mix(shellColour, float3(0.75, 0.88, 1.0), 0.2 * s.width / w) * c * s.brightness;
        }
        gained *= shellMask * next.shell.limb;

        // fine filigree in patches, gold and red
        float filigreeMask = smoothstep(0.52, 0.75, next.region.x) * (0.4 + next.detail.x);
        float3 filigreeColour = mix(ember, gold, smoothstep(0.35, 0.65, next.detail.y));
        float3 fil = 0;
        for (int k = 0; k < filigreeCount; k++) {
            constant Sheet &s = filigree[k];
            float w = max(s.width, footprint);
            float c = crossing((last.filigree.value - s.level) / last.filigree.gradient,
                               (next.filigree.value - s.level) / next.filigree.gradient, w, len);
            fil += mix(filigreeColour, float3(1.0, 0.8, 0.45), 0.2 * s.width / w) * c * s.brightness;
        }
        gained += fil * filigreeMask * next.filigree.limb;

        // diffuse hydrogen glow and dust
        float haze = smoothstep(0.3, 0.85, next.region.x) * smoothstep(0.25, 0.85, next.warp.y);
        gained += hydrogen * haze * haze * 0.0018 * len;
        float dust = 0.02 * smoothstep(0.55, 0.8, next.warp.y) * smoothstep(0.3, 0.6, next.region.y);

        // the pocket: empty inside, the nebula rising past its wall with a brightened rim, like
        // the shocked outer edge of a remnant
        float wall = pocketDistance(pocket + dir * tNext, next, u.pocket.w);
        float rim = (wall - 22.0) / 14.0;
        float envelope = smoothstep(0.0, 30.0, wall);
        gained *= envelope * (1.0 + 1.5 * exp(-rim * rim));
        dust *= envelope;

        gained *= fade * transmittance;
        colour += gained;
        transmittance *= exp(-dust * len);
        float weight = luma(gained);
        depthSum += tMid * weight;
        depthWeight += weight;
        t = tNext;
        last = next;
    }

    NebulaOut o;
    o.colour = float4(colour + backdrop(dir, noise) * transmittance, 1);
    o.depth = depthWeight > 1e-5 ? depthSum / depthWeight : nebulaFar;
    return o;
}

// temporal upscaling: each history pixel blends the coarse, jittered nebula frame with last
// frame's result, reprojected through the camera motion at the nebula's weighted depth. the new
// frame counts for more where its jittered sample landed close to the pixel, so detail finer
// than the nebula resolution builds up over frames. history is clamped to the new frame's
// neighbourhood so moving structure does not smear.
fragment float4 resolveFragment(FullscreenOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> current [[texture(0)]],
                                texture2d<float> depth [[texture(1)]],
                                texture2d<float> history [[texture(2)]]) {
    float2 size = float2(current.get_width(), current.get_height());
    int2 limit = int2(size) - 1;
    // position in nebula pixels; nebula pixel i was sampled at i + 0.5 + jitter
    float2 x = in.position.xy * size / u.jitter.zw - u.jitter.xy;
    int2 nearest = clamp(int2(floor(x)), int2(0), limit);
    float2 delta = x - (float2(nearest) + 0.5);

    // the new frame is reconstructed from its jittered samples with a gaussian of their true
    // distances, which antialiases edges that bilinear filtering would leave stepped
    float4 c = 0, lo = 1e9, hi = -1e9;
    float total = 0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int2 at = nearest + int2(i, j);
            float4 s = current.read(uint2(clamp(at, int2(0), limit)));
            float2 d = x - (float2(at) + 0.5);
            float w = exp(-2.5 * dot(d, d));
            c += s * w;
            total += w;
            lo = min(lo, s);
            hi = max(hi, s);
        }
    }
    c /= total;
    if (u.previousForward.w < 0.5) return c;

    float3 dir = viewRay(in.position.xy, u.jitter.zw, u);
    float3 rel = dir * depth.read(uint2(nearest)).r + u.motion.xyz;
    float z = dot(rel, u.previousForward.xyz);
    if (z < 0.1) return c;
    float2 ndc = float2(dot(rel, u.previousRight.xyz) / (z * u.previousRight.w),
                        dot(rel, u.previousUp.xyz) / (z * u.previousUp.w));
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0)) return c;

    float4 h = clamp(history.sample(screenSampler, uv), lo, hi);
    float confidence = exp(-4.0 * dot(delta, delta));
    return mix(h, c, u.motion.w * mix(0.3, 1.5, confidence));
}

// ---- bloom: 13-tap downsample chain and tent-filtered upsample ----

static float3 tap(texture2d<float> src, float2 uv, float2 texel, float x, float y) {
    return max(src.sample(screenSampler, uv + texel * float2(x, y)).rgb, 0.0);
}

fragment float4 bloomDownsample(FullscreenOut in [[stage_in]],
                                constant BloomStep &s [[buffer(0)]],
                                texture2d<float> src [[texture(0)]]) {
    float2 uv = in.position.xy * s.texel.xy;
    float2 t = s.texel.zw;
    float3 a = tap(src, uv, t, -2, 2), b = tap(src, uv, t, 0, 2), c = tap(src, uv, t, 2, 2);
    float3 d = tap(src, uv, t, -2, 0), e = tap(src, uv, t, 0, 0), f = tap(src, uv, t, 2, 0);
    float3 g = tap(src, uv, t, -2, -2), h = tap(src, uv, t, 0, -2), i = tap(src, uv, t, 2, -2);
    float3 j = tap(src, uv, t, -1, 1), k = tap(src, uv, t, 1, 1);
    float3 l = tap(src, uv, t, -1, -1), m = tap(src, uv, t, 1, -1);

    if (s.options.x < 0.5) {
        float3 sum = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
        return float4(sum, 1);
    }

    // the first level weights each group by inverse luma so single bright pixels cannot flicker
    float3 groups[5] = { (j + k + l + m) * 0.25, (a + b + d + e) * 0.25, (b + c + e + f) * 0.25,
                         (d + e + g + h) * 0.25, (e + f + h + i) * 0.25 };
    float weights[5] = { 0.5, 0.125, 0.125, 0.125, 0.125 };
    float3 sum = 0;
    float total = 0;
    for (int n = 0; n < 5; n++) {
        float w = weights[n] / (1.0 + luma(groups[n]));
        sum += groups[n] * w;
        total += w;
    }
    return float4(sum / total, 1);
}

fragment float4 bloomUpsample(FullscreenOut in [[stage_in]],
                              constant BloomStep &s [[buffer(0)]],
                              texture2d<float> src [[texture(0)]]) {
    float2 uv = in.position.xy * s.texel.xy;
    float2 t = s.texel.zw;
    float3 sum = tap(src, uv, t, 0, 0) * 4.0
               + (tap(src, uv, t, -1, 0) + tap(src, uv, t, 1, 0) + tap(src, uv, t, 0, -1) + tap(src, uv, t, 0, 1)) * 2.0
               + tap(src, uv, t, -1, -1) + tap(src, uv, t, 1, -1) + tap(src, uv, t, -1, 1) + tap(src, uv, t, 1, 1);
    return float4(sum / 16.0, 1);
}

// ---- final: lens effects, filmic tonemap, grain ----

// stephen hill's fit of the aces reference rendering transform
static float3 acesFitted(float3 c) {
    const float3x3 input = float3x3(float3(0.59719, 0.07600, 0.02840),
                                    float3(0.35458, 0.90834, 0.13383),
                                    float3(0.04823, 0.01566, 0.83777));
    const float3x3 output = float3x3(float3(1.60475, -0.10208, -0.00327),
                                     float3(-0.53108, 1.10813, -0.07276),
                                     float3(-0.07367, -0.00605, 1.07602));
    c = input * c;
    float3 a = c * (c + 0.0245786) - 0.000090537;
    float3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
    return saturate(output * (a / b));
}

static float3 linearToSRGB(float3 c) {
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

fragment float4 finalFragment(FullscreenOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> hdr [[texture(0)]],
                              texture2d<float> bloom [[texture(1)]]) {
    float2 uv = in.position.xy / u.viewport.xy;
    float2 v = uv - 0.5;
    float2 shift = v * dot(v, v) * u.post.z;
    float3 c = float3(hdr.sample(screenSampler, uv + shift).r,
                      hdr.sample(screenSampler, uv).g,
                      hdr.sample(screenSampler, uv - shift).b);
    c = mix(c, bloom.sample(screenSampler, uv).rgb / u.params.z, u.post.y);
    c *= u.post.x * (1.0 - dot(v, v) * 0.6);
    c = max(mix(float3(luma(c)), c, 1.2), 0.0);
    c = linearToSRGB(acesFitted(c));

    uint3 seed = uint3(uint2(in.position.xy), uint(u.params.y));
    float grain = float(hashU(seed, 11u) & 0xffffu) / 65535.0 + float(hashU(seed, 23u) & 0xffffu) / 65535.0 - 1.0;
    c += grain * u.post.w * (0.3 + 0.7 * c);
    c += (ign(in.position.xy) - 0.5) / 255.0;
    return float4(c, 1);
}
