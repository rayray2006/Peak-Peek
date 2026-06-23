#include <metal_stdlib>
using namespace metal;

// Layout MUST match `struct Uniforms` in Uniforms.swift (160-byte stride).
struct Uniforms {
    float4 cameraPos;   // xyz = ENU meters
    float4 forward;
    float4 right;
    float4 up;
    float4 sunDir;
    float2 resolution;
    float  tanHalfFovY;
    float  aspect;
    float  maxDistance;
    float  curvatureK;
    float  heightScale;
    float  time;
    // DEM sampling
    float2 gridMinENU;    // ENU of SW corner
    float2 cellSizeENU;   // meters per col, per row
    float2 gridDims;      // ncols, nrows
    float  useDEM;
    float  globalMaxHeight;
    float  panoElevMax;   // half-height of panorama vertical band (radians)
    float  _pad2;
    float  _pad3;
    float  _pad4;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VSOut o;
    o.position = float4(p[vid], 0.0, 1.0);
    o.uv = p[vid] * 0.5 + 0.5;
    return o;
}

// ---------------------------------------------------------------------------
// Procedural fallback (Phase 0)
// ---------------------------------------------------------------------------
static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
static float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(i), b = hash(i + float2(1, 0));
    float c = hash(i + float2(0, 1)), d = hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    float2x2 rot = float2x2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < 6; i++) { v += amp * valueNoise(p); p = rot * p * 2.02; amp *= 0.5; }
    return v;
}
static float proceduralHeight(float2 xy, constant Uniforms& u) {
    float2 p = xy / 1000.0;
    float ridge = 1.0 - fabs(fbm(p * 0.15) * 2.0 - 1.0);
    float base = fbm(p * 0.35);
    return (400.0 + 2600.0 * (0.55 * ridge + 0.45 * base)) * u.heightScale;
}

// ---------------------------------------------------------------------------
// DEM sampling
// ---------------------------------------------------------------------------
constexpr sampler demSampler(filter::linear, address::clamp_to_edge, coord::normalized);

// Returns elevation in meters, or a large negative sentinel when outside the grid.
static float sampleDEM(float2 xy, constant Uniforms& u, texture2d<float> dem) {
    float colf = (xy.x - u.gridMinENU.x) / u.cellSizeENU.x;
    float rowFromBottom = (xy.y - u.gridMinENU.y) / u.cellSizeENU.y;
    float uu = colf / u.gridDims.x;
    float vv = 1.0 - rowFromBottom / u.gridDims.y;   // row 0 = north (top)
    if (uu < 0.0 || uu > 1.0 || vv < 0.0 || vv > 1.0) return -10000.0;
    float h = dem.sample(demSampler, float2(uu, vv)).r;
    return h * u.heightScale;
}

static float terrainHeight(float2 xy, constant Uniforms& u, texture2d<float> dem) {
    return (u.useDEM > 0.5) ? sampleDEM(xy, u, dem) : proceduralHeight(xy, u);
}

static float3 terrainNormal(float2 xy, constant Uniforms& u, texture2d<float> dem) {
    float ex = max(8.0, u.cellSizeENU.x);
    float ey = max(8.0, u.cellSizeENU.y);
    float hL = terrainHeight(xy - float2(ex, 0), u, dem);
    float hR = terrainHeight(xy + float2(ex, 0), u, dem);
    float hD = terrainHeight(xy - float2(0, ey), u, dem);
    float hU = terrainHeight(xy + float2(0, ey), u, dem);
    return normalize(float3(hL - hR, hD - hU, ex + ey));
}

static float surfaceZ(float2 xy, float t, constant Uniforms& u, texture2d<float> dem) {
    return terrainHeight(xy, u, dem) - u.curvatureK * t * t;
}

// ---------------------------------------------------------------------------
// Raymarcher
// ---------------------------------------------------------------------------
// Pass 1 output: shaded color + linear eye depth (meters). Depth is retained as
// the bake/raymarch pipelines are MRT, though nothing consumes it downstream now.
struct GBuffer {
    float4 color [[color(0)]];
    float  depth [[color(1)]];
};

// March a single ray from `ro` along `rd`, returning shaded color and writing
// linear eye depth (meters; FAR for sky/miss) to `outDepth`. Shared by the
// perspective raymarch and the 360° panorama bake.
static float4 marchAndShade(float3 ro, float3 rd, constant Uniforms& u,
                            texture2d<float> dem, thread float& outDepth) {
    const float tNear = 5.0;
    float tMax  = u.maxDistance;
    const float FAR = u.maxDistance * 4.0;       // sky/miss depth sentinel

    float3 skyTop = float3(0.05, 0.06, 0.08);
    float3 skyHorizon = float3(0.14, 0.16, 0.19);

    // Bound the march window using the curvature envelope: terrain can only
    // exist where the ray is below (globalMaxHeight - curvatureK*t^2). Outside
    // the [t1,t2] interval no hit is possible, so sky rays exit quickly.
    if (u.useDEM > 0.5) {
        float a = u.curvatureK;
        float b = rd.z;
        float c = ro.z - u.globalMaxHeight;
        float disc = b * b - 4.0 * a * c;
        if (disc <= 0.0) {                       // never below envelope -> sky
            float k = clamp(rd.z * 1.5 + 0.2, 0.0, 1.0);
            outDepth = FAR;
            return float4(mix(skyHorizon, skyTop, k), 1.0);
        }
        float t2 = (-b + sqrt(disc)) / (2.0 * a);
        tMax = min(tMax, max(tNear, t2));
    }

    float t = tNear;
    float prevT = t;
    bool hit = false;
    // Step tracks the DEM post spacing so distant ridges aren't skipped. The old
    // step (t * 0.011) grew to ~90 m at K2's ~8.5 km range — over 3 DEM cells —
    // so it marched past steep silhouettes and aliased them into false spikes and
    // "overhangs". Now the step stays near one cell out to mid range, then grows,
    // capped at a few cells so the far field is still reachable within the loop
    // budget. The binary refine below recovers the per-pixel silhouette.
    float cell = clamp(min(u.cellSizeENU.x, u.cellSizeENU.y), 8.0, 90.0);
    for (int i = 0; i < 2048; i++) {
        if (t > tMax) break;
        float3 p = ro + rd * t;
        float diff = p.z - surfaceZ(p.xy, t, u, dem);
        if (diff < 0.0) { hit = true; break; }
        prevT = t;
        float step = clamp(t * 0.0035, 12.0, cell * 4.0);
        t += step;
    }

    if (!hit) {
        float k = clamp(rd.z * 1.5 + 0.2, 0.0, 1.0);
        outDepth = FAR;
        return float4(mix(skyHorizon, skyTop, k), 1.0);
    }

    // Binary refine for a crisp per-pixel silhouette.
    float tLo = prevT, tHi = t;
    for (int i = 0; i < 24; i++) {
        float tm = 0.5 * (tLo + tHi);
        float3 pm = ro + rd * tm;
        float diff = pm.z - surfaceZ(pm.xy, tm, u, dem);
        if (diff < 0.0) tHi = tm; else tLo = tm;
    }
    float tHit = 0.5 * (tLo + tHi);
    float3 hitP = ro + rd * tHit;

    float3 n = terrainNormal(hitP.xy, u, dem);
    float3 sun = normalize(u.sunDir.xyz);
    float diffuse = max(0.0, dot(n, sun));
    float sky = 0.5 + 0.5 * n.z;                 // sky/ambient occlusion proxy
    // Relief tone curve. A low ambient floor + a wide sun term gives a broad
    // dynamic range; the gamma (>1) then deepens the shadows AND steepens the
    // highlights so subtle slope detail shows in the brighter, otherwise-flat
    // areas. Tunables: kAmbient (shadow floor — lower = darker), kSun (range),
    // kGamma (contrast — higher = darker darks + more highlight texture).
    const float kAmbient = 0.16;
    const float kSky     = 0.10;
    const float kSun     = 0.60;
    const float kGamma   = 1.10;
    float light = clamp(kAmbient + kSky * sky + kSun * diffuse, 0.0, 1.0);
    float shade = pow(light, kGamma);
    float3 color = float3(shade);


    outDepth = tHit;
    return float4(color, 1.0);
}

// Perspective raymarch: ray from camera basis + screen NDC.
fragment GBuffer raymarchFragment(VSOut in [[stage_in]],
                                  constant Uniforms& u [[buffer(0)]],
                                  texture2d<float> dem [[texture(0)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, in.uv.y * 2.0 - 1.0);
    float3 rd = normalize(u.forward.xyz
                          + ndc.x * u.aspect * u.tanHalfFovY * u.right.xyz
                          + ndc.y * u.tanHalfFovY * u.up.xyz);
    GBuffer o;
    float depth;
    o.color = marchAndShade(u.cameraPos.xyz, rd, u, dem, depth);
    o.depth = depth;
    return o;
}

// 360° panorama bake: equirectangular mapping. uv.x -> azimuth [0,2pi),
// uv.y -> elevation [+panoElevMax (top) .. -panoElevMax (bottom)].
// Single color output (no depth attachment): nothing downstream reads the bake's
// depth, so emitting only color halves the bake's render-target memory — which is
// what lets the panorama be baked at higher resolution.
fragment float4 panoramaBakeFragment(VSOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(0)]],
                                     texture2d<float> dem [[texture(0)]]) {
    float az = in.uv.x * 2.0 * M_PI_F;
    // uv.y maps to texture rows so that sampling v=0 (top) => +panoElevMax.
    // The view pass uses v = 0.5 - 0.5*el/panoElevMax, so match it here.
    float el = u.panoElevMax * (2.0 * in.uv.y - 1.0);
    float ce = cos(el);
    float3 rd = float3(sin(az) * ce, cos(az) * ce, sin(el));  // ENU, az cw from north
    float depth;
    float4 c = marchAndShade(u.cameraPos.xyz, rd, u, dem, depth);
    // Encode a sky/terrain mask in alpha: terrain = 1, sky/miss = 0. The 3D view
    // pass forces alpha to 1, so this is invisible to 3D mode; the AR view pass
    // uses it to make the sky transparent over the live camera.
    c.a = (depth >= u.maxDistance * 3.9) ? 0.0 : 1.0;
    return c;
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Pass 2: box-downsample the supersampled color to the final resolution.
// This anti-aliases the distant silhouette (1-ray-per-pixel aliasing).
// ---------------------------------------------------------------------------
fragment float4 downsampleFragment(VSOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   constant uint& ss [[buffer(0)]]) {
    uint w = src.get_width();
    uint h = src.get_height();
    uint2 base = uint2(in.position.xy) * ss;
    float3 acc = float3(0.0);
    float n = 0.0;
    for (uint j = 0; j < ss; j++) {
        for (uint i = 0; i < ss; i++) {
            uint2 c = min(base + uint2(i, j), uint2(w - 1, h - 1));
            acc += src.read(c).rgb;
            n += 1.0;
        }
    }
    return float4(acc / n, 1.0);
}

// ---------------------------------------------------------------------------
// 360° PANORAMA PATH
//
// Bake the full 360° once (panoramaBake), then per-frame sample the panorama
// for the current heading (panoramaView). Look-around is then a cheap texture
// lookup instead of a fresh raymarch — seamless rotation.
// ---------------------------------------------------------------------------

// Per-frame view: map each screen pixel's ray to (azimuth, elevation) and
// sample the baked panorama. Azimuth wraps (s_address::repeat); elevation
// clamps. Cheap -> seamless look-around.
constexpr sampler panoSampler(filter::linear, s_address::repeat,
                              t_address::clamp_to_edge, mag_filter::linear);

fragment float4 panoramaViewFragment(VSOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(0)]],
                                     texture2d<float> pano [[texture(0)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, in.uv.y * 2.0 - 1.0);
    float3 rd = normalize(u.forward.xyz
                          + ndc.x * u.aspect * u.tanHalfFovY * u.right.xyz
                          + ndc.y * u.tanHalfFovY * u.up.xyz);

    float az = atan2(rd.x, rd.y);                // clockwise from north
    if (az < 0.0) az += 2.0 * M_PI_F;
    float el = asin(clamp(rd.z, -1.0, 1.0));

    float uu = az / (2.0 * M_PI_F);
    float vv = 0.5 - 0.5 * el / u.panoElevMax;   // +panoElevMax -> top (v=0)
    return float4(pano.sample(panoSampler, float2(uu, vv)).rgb, 1.0);
}

// AR view: same panorama resample as `panoramaViewFragment`, but keeps the baked
// sky/terrain alpha and premultiplies it — sky (alpha 0) becomes transparent so
// the live camera shows through while terrain stays opaque. Used only in AR mode;
// the 3D path above is unchanged.
fragment float4 panoramaViewARFragment(VSOut in [[stage_in]],
                                       constant Uniforms& u [[buffer(0)]],
                                       texture2d<float> pano [[texture(0)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, in.uv.y * 2.0 - 1.0);
    float3 rd = normalize(u.forward.xyz
                          + ndc.x * u.aspect * u.tanHalfFovY * u.right.xyz
                          + ndc.y * u.tanHalfFovY * u.up.xyz);

    float az = atan2(rd.x, rd.y);                // clockwise from north
    if (az < 0.0) az += 2.0 * M_PI_F;
    float el = asin(clamp(rd.z, -1.0, 1.0));

    float uu = az / (2.0 * M_PI_F);
    float vv = 0.5 - 0.5 * el / u.panoElevMax;
    float4 c = pano.sample(panoSampler, float2(uu, vv));
    return float4(c.rgb * c.a, c.a);             // premultiplied; sky transparent
}

// Per-texel signal for edge detection: terrain luminance, or a low sentinel for
// sky so the terrain/sky boundary (skyline) reads as a strong gradient.
static float edgeSignal(texture2d<float> pano, float2 uv) {
    float4 s = pano.sample(panoSampler, uv);
    float lum = dot(s.rgb, float3(0.299, 0.587, 0.114));
    return s.a > 0.5 ? lum : -0.5;
}

// AR edges view: white ridge/silhouette edges over a fully transparent overlay
// (the rest is camera passthrough). Edges come from a Sobel over the baked
// panorama. Premultiplied white.
fragment float4 panoramaViewEdgesFragment(VSOut in [[stage_in]],
                                          constant Uniforms& u [[buffer(0)]],
                                          texture2d<float> pano [[texture(0)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, in.uv.y * 2.0 - 1.0);
    float3 rd = normalize(u.forward.xyz
                          + ndc.x * u.aspect * u.tanHalfFovY * u.right.xyz
                          + ndc.y * u.tanHalfFovY * u.up.xyz);

    float az = atan2(rd.x, rd.y);
    if (az < 0.0) az += 2.0 * M_PI_F;
    float el = asin(clamp(rd.z, -1.0, 1.0));
    float2 uv = float2(az / (2.0 * M_PI_F), 0.5 - 0.5 * el / u.panoElevMax);
    float2 t = 1.0 / float2(pano.get_width(), pano.get_height());

    float tl = edgeSignal(pano, uv + t * float2(-1, -1));
    float tc = edgeSignal(pano, uv + t * float2( 0, -1));
    float tr = edgeSignal(pano, uv + t * float2( 1, -1));
    float ml = edgeSignal(pano, uv + t * float2(-1,  0));
    float mr = edgeSignal(pano, uv + t * float2( 1,  0));
    float bl = edgeSignal(pano, uv + t * float2(-1,  1));
    float bc = edgeSignal(pano, uv + t * float2( 0,  1));
    float br = edgeSignal(pano, uv + t * float2( 1,  1));
    float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    float g = length(float2(gx, gy));

    // Thresholds tuned for the shaded-relief panorama; raise lo to thin the
    // strokes, lower it to catch fainter internal ridges.
    float e = smoothstep(0.08, 0.22, g);
    return float4(e, e, e, e);                   // premultiplied white
}

// ---------------------------------------------------------------------------
// One-time edge anti-aliasing of the baked panorama (FXAA console-lite). Run
// ONCE after the bake, not per frame, so it removes the staircased silhouette/
// ridge edges (which magnify into stairs when the view resamples the panorama)
// without any per-frame cost. Flat areas return unchanged (no general blur);
// only edge texels are blended along the edge. RGBA is blended, so the AR
// sky/terrain alpha mask is anti-aliased too.
// ---------------------------------------------------------------------------
constexpr sampler aaSampler(filter::linear, s_address::repeat, t_address::clamp_to_edge);

static float aaLuma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

fragment float4 panoramaAAFragment(VSOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]]) {
    // Derive the texcoord from the fragment position (robust for a post-process
    // pass) rather than the interpolated uv.
    float2 px = 1.0 / float2(src.get_width(), src.get_height());
    float2 uv = in.position.xy * px;

    float4 cM  = src.sample(aaSampler, uv);
    float lM   = aaLuma(cM.rgb);
    float lNW  = aaLuma(src.sample(aaSampler, uv + px * float2(-1.0, -1.0)).rgb);
    float lNE  = aaLuma(src.sample(aaSampler, uv + px * float2( 1.0, -1.0)).rgb);
    float lSW  = aaLuma(src.sample(aaSampler, uv + px * float2(-1.0,  1.0)).rgb);
    float lSE  = aaLuma(src.sample(aaSampler, uv + px * float2( 1.0,  1.0)).rgb);

    float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
    // Not an edge → leave the texel untouched (no flat-area softening).
    if (lMax - lMin < max(0.045, lMax * 0.125)) return cM;

    float2 dir;
    dir.x = -((lNW + lNE) - (lSW + lSE));
    dir.y =  ((lNW + lSW) - (lNE + lSE));
    float dirReduce = max((lNW + lNE + lSW + lSE) * 0.03125, 0.0078125);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpDirMin, -8.0, 8.0) * px;

    float4 rgbA = 0.5 * (src.sample(aaSampler, uv + dir * (1.0 / 3.0 - 0.5))
                       + src.sample(aaSampler, uv + dir * (2.0 / 3.0 - 0.5)));
    float4 rgbB = rgbA * 0.5 + 0.25 * (src.sample(aaSampler, uv + dir * -0.5)
                                     + src.sample(aaSampler, uv + dir *  0.5));
    float lB = aaLuma(rgbB.rgb);
    return (lB < lMin || lB > lMax) ? rgbA : rgbB;
}
