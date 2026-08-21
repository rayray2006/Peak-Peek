#include <metal_stdlib>
using namespace metal;

// Layout MUST match `struct Uniforms` in Uniforms.swift (208-byte stride).
struct Uniforms {
    float4 cameraPos;   // xyz = ENU meters
    float4 forward;
    float4 right;
    float4 up;
    float4 sunDir;
    float  skySunElDeg;   // sun elevation (deg) from skySunDir, CPU-hoisted
    float  terrainBright; // view-pass terrain dimming (1 day … 0.34 night)
    float  tanHalfFovY;
    float  aspect;
    float  maxDistance;
    float  curvatureK;
    float  heightScale;
    float  pad0;          // unused; keeps the 208-byte layout
    // DEM sampling
    float2 gridMinENU;    // ENU of SW corner
    float2 cellSizeENU;   // meters per col, per row
    float2 gridDims;      // ncols, nrows
    float  useDEM;
    float  globalMaxHeight;
    float  panoElevMax;   // half-height of panorama vertical band (radians)
    // Far (coarse) DEM tier, bound at texture(1).
    float  useFar;
    float2 gridMinENU2;
    float2 cellSizeENU2;
    float2 gridDims2;
    float4 skySunDir;     // real sun ENU direction → dynamic sky colour (.w unused)
    // ENU projection correction (identity when 0/1/0 — see Uniforms.swift).
    float  refLatRad;     // ENU reference latitude, radians
    float  cosRefLat;     // cos(refLatRad)
    float  geoK;          // tan(refLatRad) / (2 R_enu): m northing per (m easting)²
};

// Guard the byte-for-byte layout contract with the Swift struct (stride 208,
// verified: skySunDir @176, refLatRad @192, geoK @200).
static_assert(sizeof(Uniforms) == 208, "Uniforms layout must match Uniforms.swift");

// Radians of latitude per meter of northing (1 / (111,320 m/deg · 180/π)).
// Must match `Uniforms.metersPerDegree` in Uniforms.swift.
constant float kRadPerMeterNorth = M_PI_F / (180.0f * 111320.0f);

// Realistic sky colour for a view ray, given the real sun direction (ENU) and its
// elevation in degrees (CPU-hoisted — uniform-only, so computing asin() per pixel
// was pure waste). Night is dark, twilight glows orange near the sun + horizon,
// day is blue (paler at the horizon). Blended by the sun's altitude so it tracks
// sunrise→day→sunset→night.
static float3 skyColorFor(float3 rd, float3 sunDir, float sunEl) {
    float h = clamp(rd.z, 0.0, 1.0);                               // 0 horizon → 1 zenith
    float alt = pow(h, 0.55);

    float3 dayZen = float3(0.16, 0.38, 0.78);
    float3 dayHor = float3(0.58, 0.72, 0.92);
    float3 twiZen = float3(0.09, 0.11, 0.30);
    float3 twiHor = float3(0.42, 0.26, 0.40);     // muted purple base; orange added below
    float3 ngtZen = float3(0.015, 0.020, 0.045);
    float3 ngtHor = float3(0.035, 0.045, 0.085);

    float f1 = smoothstep(-16.0, -2.0, sunEl);    // night → twilight
    float f2 = smoothstep(0.0, 12.0, sunEl);      // twilight → day
    float3 zen = mix(mix(ngtZen, twiZen, f1), dayZen, f2);
    float3 hor = mix(mix(ngtHor, twiHor, f1), dayHor, f2);
    float3 col = mix(hor, zen, alt);

    // Warm sunrise/sunset glow, strongest toward the sun + near the horizon.
    // `rd` arrives normalized from every caller.
    float twi = (1.0 - smoothstep(2.0, 14.0, sunEl)) * smoothstep(-12.0, -2.0, sunEl);
    float sunDot = max(0.0, dot(rd, sunDir));
    float horizonBand = 1.0 - smoothstep(0.0, 0.45, h);
    float glow = twi * pow(sunDot, 3.0) * (0.4 + 0.6 * horizonBand);
    col = mix(col, float3(1.0, 0.45, 0.16), clamp(glow, 0.0, 0.85));
    return col;
}

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

// Apple GPU families before 9 (pre-A17/M3) cannot linear-filter 32-bit float
// textures — a filter::linear sampler silently degrades to NEAREST there, so
// every ~30 m DEM cell rendered as a flat step on most iPhones. The host sets
// this from MTLDevice.supports32BitFloatFiltering at pipeline build; false
// selects the manual-bilinear path below (compile-time branch, no per-sample
// cost on capable GPUs). Defaults to the hardware path when a host doesn't
// set it (Mac-only tools).
constant bool kHWFilterF32 [[function_constant(0)]];
constant bool useHWFilterF32 = is_function_constant_defined(kHWFilterF32) ? kHWFilterF32 : true;

// Sample one grid (bilinear). Returns raw meters, or a large negative
// sentinel when the point is outside this grid's footprint.
static float sampleGrid(float2 xy, float2 gridMin, float2 cellSize, float2 dims,
                        texture2d<float> tex) {
    float colf = (xy.x - gridMin.x) / cellSize.x;     // texel units (dims = texture size)
    float rowf = dims.y - (xy.y - gridMin.y) / cellSize.y;   // row 0 = north (top)
    if (colf < 0.0 || colf > dims.x || rowf < 0.0 || rowf > dims.y) return -10000.0;
    if (useHWFilterF32) {
        return tex.sample(demSampler, float2(colf / dims.x, rowf / dims.y)).r;
    }
    // Manual bilinear, exact same texel math as the hardware sampler (sample
    // point minus the half-texel center offset, clamp_to_edge).
    float tx = colf - 0.5;
    float ty = rowf - 0.5;
    float fx = fract(tx), fy = fract(ty);
    int x0 = int(floor(tx)), y0 = int(floor(ty));
    int xMax = int(dims.x) - 1, yMax = int(dims.y) - 1;
    uint x0c = uint(clamp(x0, 0, xMax)), x1c = uint(clamp(x0 + 1, 0, xMax));
    uint y0c = uint(clamp(y0, 0, yMax)), y1c = uint(clamp(y0 + 1, 0, yMax));
    float v00 = tex.read(uint2(x0c, y0c)).r;
    float v10 = tex.read(uint2(x1c, y0c)).r;
    float v01 = tex.read(uint2(x0c, y1c)).r;
    float v11 = tex.read(uint2(x1c, y1c)).r;
    return mix(mix(v00, v10, fx), mix(v01, v11, fx), fy);
}

// Two-tier DEM: the high-res near grid where it covers the point, else the coarse
// far grid. Returns meters (post heightScale), or the sentinel where neither has data.
static float terrainHeight(float2 xy, constant Uniforms& u,
                           texture2d<float> dem, texture2d<float> demFar) {
    if (u.useDEM <= 0.5) return proceduralHeight(xy, u);
    // Undo the flat plate-carrée ENU mapping before sampling the lat/lon grid:
    // (1) subtract the poleward geodesic bulge from the northing — a target due
    // east is SEEN slightly poleward of east because sightlines follow great
    // circles; (2) scale the easting by cos(refLat)/cos(lat) so meridian
    // convergence tracks the sample's own latitude, not the origin's. Together
    // these put distant rendered azimuths on true compass bearings (the flat
    // mapping was off by ~0.5–1°+ at 120 km). Label anchors apply the identical
    // forward mapping (TerrainMetalView.buildAnchors), so labels stay glued.
    float yg = xy.y - xy.x * xy.x * u.geoK;
    float latRad = u.refLatRad + yg * kRadPerMeterNorth;
    float2 xyg = float2(xy.x * u.cosRefLat / max(cos(latRad), 1e-4f), yg);
    float h = sampleGrid(xyg, u.gridMinENU, u.cellSizeENU, u.gridDims, dem);
    if (h <= -9000.0 && u.useFar > 0.5) {
        h = sampleGrid(xyg, u.gridMinENU2, u.cellSizeENU2, u.gridDims2, demFar);
    }
    if (h <= -9000.0) return -10000.0;
    return h * u.heightScale;
}

static float3 terrainNormal(float2 xy, constant Uniforms& u,
                            texture2d<float> dem, texture2d<float> demFar,
                            float scale) {
    float ex = max(8.0, u.cellSizeENU.x) * scale;
    float ey = max(8.0, u.cellSizeENU.y) * scale;
    float hL = terrainHeight(xy - float2(ex, 0), u, dem, demFar);
    float hR = terrainHeight(xy + float2(ex, 0), u, dem, demFar);
    float hD = terrainHeight(xy - float2(0, ey), u, dem, demFar);
    float hU = terrainHeight(xy + float2(0, ey), u, dem, demFar);
    return normalize(float3(hL - hR, hD - hU, ex + ey));
}

static float surfaceZ(float2 xy, float t, constant Uniforms& u,
                      texture2d<float> dem, texture2d<float> demFar) {
    return terrainHeight(xy, u, dem, demFar) - u.curvatureK * t * t;
}

// ---------------------------------------------------------------------------
// Raymarcher
// ---------------------------------------------------------------------------

// Baked sky RGB is discarded in the view passes (sky alpha 0 → recoloured live
// / transparent); it only shows where the panorama resample blends a fractional
// edge texel at the skyline. Keeping it PALE (near the haze colour in
// marchAndShade) makes that silhouette blend seamless instead of fringing the
// horizon dark grey.
constant float3 kBakedSkyTop = float3(0.45, 0.52, 0.64);
constant float3 kBakedSkyHorizon = float3(0.74, 0.80, 0.88);

static float4 bakedSky(float3 rd, thread float& outDepth, float FAR) {
    float k = clamp(rd.z * 1.5 + 0.2, 0.0, 1.0);
    outDepth = FAR;
    return float4(mix(kBakedSkyHorizon, kBakedSkyTop, k), 1.0);
}

// March a single ray from `ro` along `rd`, returning shaded color and writing
// linear eye depth (meters; FAR for sky/miss) to `outDepth`. Shared by the
// perspective raymarch and the 360° panorama bake.
static float4 marchAndShade(float3 ro, float3 rd, constant Uniforms& u,
                            texture2d<float> dem, texture2d<float> demFar,
                            thread float& outDepth) {
    const float tNear = 5.0;
    float tMax  = u.maxDistance;
    const float FAR = u.maxDistance * 4.0;       // sky/miss depth sentinel

    // Bound the march window using the curvature envelope: terrain can only
    // exist where the ray is below (globalMaxHeight - curvatureK*t^2). Outside
    // the [t1,t2] interval no hit is possible, so sky rays exit quickly.
    if (u.useDEM > 0.5) {
        float a = u.curvatureK;
        float b = rd.z;
        float c = ro.z - u.globalMaxHeight;
        float disc = b * b - 4.0 * a * c;
        if (disc <= 0.0) {                       // never below envelope -> sky
            return bakedSky(rd, outDepth, FAR);
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
    float cellNear = clamp(min(u.cellSizeENU.x, u.cellSizeENU.y), 8.0, 90.0);
    // Beyond the near grid's reach only the COARSE far tile answers, so keeping
    // the near-grid step cap there just burned the iteration budget: a ~10 m DEM
    // (cap 40 m) exhausted 2048 steps around 68 km and silently rendered the
    // rest of the 135 km range as sky. Past the near grid's half-extent, cap by
    // the far tile's own cell size instead.
    float cellFar = (u.useFar > 0.5)
        ? clamp(min(u.cellSizeENU2.x, u.cellSizeENU2.y), cellNear, 400.0)
        : cellNear;
    // Half-DIAGONAL, not half-extent: diagonal rays stay inside the near grid
    // past the half-extent, and coarsening the step while the fine DEM still
    // answers could skip a thin ridge there. Overshooting costs only a few
    // hundred iterations, comfortably inside the 2048 budget.
    float nearReach = 0.5 * length(float2(u.gridDims.x * u.cellSizeENU.x,
                                          u.gridDims.y * u.cellSizeENU.y));
    for (int i = 0; i < 2048; i++) {
        if (t > tMax) break;
        float3 p = ro + rd * t;
        float diff = p.z - surfaceZ(p.xy, t, u, dem, demFar);
        if (diff < 0.0) { hit = true; break; }
        prevT = t;
        float cap = (t < nearReach) ? cellNear : cellFar;
        float step = clamp(t * 0.0035, 12.0, cap * 4.0);
        t += step;
    }

    if (!hit) {
        return bakedSky(rd, outDepth, FAR);
    }

    // Binary refine for a crisp per-pixel silhouette. 14 bisections of a ≤1-step
    // interval land well under 0.1 m — already invisible at any pixel scale (the
    // previous 24 refined to ~2e-5 m, pure waste at a full terrain sample each).
    float tLo = prevT, tHi = t;
    for (int i = 0; i < 14; i++) {
        float tm = 0.5 * (tLo + tHi);
        float3 pm = ro + rd * tm;
        float diff = pm.z - surfaceZ(pm.xy, tm, u, dem, demFar);
        if (diff < 0.0) tHi = tm; else tLo = tm;
    }
    float tHit = 0.5 * (tLo + tHi);
    float3 hitP = ro + rd * tHit;

    // Two normals, two jobs: the FINE normal (1× post spacing) carries rock
    // texture; the BROAD normal (4×) carries the landform — ridge vs wall vs
    // floor. Blending their sun response keeps micro-detail while whole
    // valley walls hold a consistent tone, so adjacent surfaces separate
    // instead of averaging into one gray (multi-scale relief shading).
    float3 n  = terrainNormal(hitP.xy, u, dem, demFar, 1.0);
    float3 nB = terrainNormal(hitP.xy, u, dem, demFar, 4.0);
    float3 sun = normalize(u.sunDir.xyz);
    float diffuse  = 0.6 * max(0.0, dot(n,  sun))
                   + 0.4 * max(0.0, dot(nB, sun));
    float sky = 0.5 + 0.5 * n.z;                 // sky/ambient occlusion proxy
    // Relief tone curve. A low ambient floor + a wide sun term gives a broad
    // dynamic range; the gamma (>1) then deepens the shadows AND steepens the
    // highlights so subtle slope detail shows in the brighter, otherwise-flat
    // areas. Tunables: kAmbient (shadow floor — lower = darker), kSun (range),
    // kGamma (contrast — higher = darker darks + more highlight texture).
    const float kAmbient = 0.14;
    const float kSky     = 0.10;
    const float kSun     = 0.62;
    const float kGamma   = 1.40;
    float light = clamp(kAmbient + kSky * sky + kSun * diffuse, 0.0, 1.0);
    float shade = pow(light, kGamma);
    // Sun-INDEPENDENT slope tone: steep faces ink darker than flats, so a
    // fjord wall separates from the plateau above it even under a high sun
    // that lights both equally (Hornstrandir read as one white sheet — the
    // washed-out scene where dots correctly ON pale ridges looked like they
    // floated in the sky). Broad normal on purpose: a slope band should
    // shade as ONE surface, not per-cell noise. Flats (<~10°) stay paper.
    float slope = clamp(1.0 - nB.z, 0.0, 1.0);   // 1 - cos(slope angle)
    shade *= 1.0 - 0.35 * smoothstep(0.02, 0.5, slope);
    float3 color = float3(shade);

    // Aerial perspective: real distance reads as a pale, low-contrast haze, so far
    // ridges recede instead of standing as a flat grey wall at the horizon.
    // Exponential extinction by range (Beer-Lambert), capped so terrain never fully
    // dissolves. The haze tint is a faint cool grey that sits naturally under the
    // live sky; terrainBright in the view pass dims it at night with the rest.
    const float hazeDist     = 50000.0;          // ~e-folding range (m)
    const float hazeStrength = 0.70;             // max blend toward haze at far range
    const float3 hazeColor   = float3(0.80, 0.83, 0.88);
    float haze = (1.0 - exp(-tHit / hazeDist)) * hazeStrength;
    color = mix(color, hazeColor, haze);

    outDepth = tHit;
    return float4(color, 1.0);
}

// View ray for a screen uv from the camera basis (shared by the perspective
// raymarch and every panorama view pass).
static float3 viewRay(float2 uv, constant Uniforms& u) {
    float2 ndc = uv * 2.0 - 1.0;
    return normalize(u.forward.xyz
                     + ndc.x * u.aspect * u.tanHalfFovY * u.right.xyz
                     + ndc.y * u.tanHalfFovY * u.up.xyz);
}

// Equirectangular texcoord for a view ray: azimuth (clockwise from north,
// wrapping) → u, elevation → v with +panoElevMax at the top (v = 0). The
// single home of the ray→panorama mapping contract; the bake writes rows to
// match (see panoramaBakeFragment).
static float2 panoUV(float3 rd, constant Uniforms& u) {
    float az = atan2(rd.x, rd.y);
    if (az < 0.0) az += 2.0 * M_PI_F;
    float el = asin(clamp(rd.z, -1.0, 1.0));
    return float2(az / (2.0 * M_PI_F), 0.5 - 0.5 * el / u.panoElevMax);
}

// Perspective raymarch: ray from camera basis + screen NDC. Color only — the
// old MRT depth attachment was cleared, written, and stored every frame at the
// supersampled resolution (~48 MB resident) with no downstream reader.
fragment float4 raymarchFragment(VSOut in [[stage_in]],
                                 constant Uniforms& u [[buffer(0)]],
                                 texture2d<float> dem [[texture(0)]],
                                 texture2d<float> demFar [[texture(1)]]) {
    float depth;
    return marchAndShade(u.cameraPos.xyz, viewRay(in.uv, u), u, dem, demFar, depth);
}

// 360° panorama bake: equirectangular mapping. uv.x -> azimuth [0,2pi),
// uv.y -> elevation [+panoElevMax (top) .. -panoElevMax (bottom)].
// Single color output (no depth attachment): nothing downstream reads the bake's
// depth, so emitting only color halves the bake's render-target memory — which is
// what lets the panorama be baked at higher resolution.
// Far-horizon strip (see FarHorizon.swift): terrain BEYOND the raymarched
// tiers as a small az x elevation panorama of nearest-hit distances (km,
// 0 = sky; rows span tan(el) in [-0.08, +0.08], row 0 = top). Baking it in
// means every view mode and the edges Sobel inherit LAYERED distant ranges
// for one texture sample. The LABEL depth pass deliberately ignores it —
// ring terrain is unlabeled and must stay neutral sky to that pipeline. An
// "empty" 1-texel strip (0 = sky) is bound when the profile isn't ready, so
// there is no uniform flag.
constexpr sampler ringSampler(filter::linear, s_address::repeat,
                              t_address::clamp_to_edge, coord::normalized);

// Nearest beyond-tier hit distance (km) for a ray, or 0 for sky.
static float ringHitKm(texture2d<float> ring, float az, float el) {
    float tanEl = tan(el);
    if (tanEl >= 0.08) return 0.0;
    float v = clamp((0.08 - tanEl) / 0.16, 0.0, 1.0);
    return ring.sample(ringSampler, float2(az / (2.0 * M_PI_F), v)).r;
}

fragment float4 panoramaBakeFragment(VSOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(0)]],
                                     texture2d<float> dem [[texture(0)]],
                                     texture2d<float> demFar [[texture(1)]],
                                     texture2d<float> ring [[texture(2)]]) {
    float az = in.uv.x * 2.0 * M_PI_F;
    // uv.y maps to texture rows so that sampling v=0 (top) => +panoElevMax.
    // The view pass uses v = 0.5 - 0.5*el/panoElevMax, so match it here.
    float el = u.panoElevMax * (2.0 * in.uv.y - 1.0);
    float ce = cos(el);
    float3 rd = float3(sin(az) * ce, cos(az) * ce, sin(el));  // ENU, az cw from north
    float depth;
    float4 c = marchAndShade(u.cameraPos.xyz, rd, u, dem, demFar, depth);
    // Encode a sky/terrain mask in alpha: terrain = 1, sky/miss = 0. The 3D view
    // pass forces alpha to 1, so this is invisible to 3D mode; the AR view pass
    // uses it to make the sky transparent over the live camera.
    c.a = (depth >= u.maxDistance * 3.9) ? 0.0 : 1.0;
    if (c.a < 0.5) {
        float dk = ringHitKm(ring, az, el);
        if (dk > 1.0) {
            // Layered ranges, depth-graded: nearer masses a touch darker, the
            // farthest melting into the sky-horizon tint. The NEAR end matches
            // what tile terrain looks like at the tier boundary (base grays
            // under ~70% haze), so ring and raymarched terrain meet without a
            // visible color seam — the ring reads as more mountains, not a
            // different material.
            float t = clamp((dk - 150.0) / 450.0, 0.0, 1.0);
            c = float4(mix(float3(0.72, 0.745, 0.785), float3(0.76, 0.80, 0.862), t), 1.0);
        }
    }
    return c;
}

// Per-texel HIT DISTANCE panorama (r32Float target; sky/miss = the FAR sentinel,
// maxDistance*4). The label pipeline reads this back once per viewpoint and asks,
// per peak: does the RENDER's ray toward it reach the peak's distance? Occlusion
// judged this way can never disagree with the picture on screen — same march,
// same eye, same DEM tiers, same curvature as the visible panorama.
fragment float4 panoramaDepthFragment(VSOut in [[stage_in]],
                                      constant Uniforms& u [[buffer(0)]],
                                      texture2d<float> dem [[texture(0)]],
                                      texture2d<float> demFar [[texture(1)]]) {
    float az = in.uv.x * 2.0 * M_PI_F;
    float el = u.panoElevMax * (2.0 * in.uv.y - 1.0);   // same row mapping as the bake
    float ce = cos(el);
    float3 rd = float3(sin(az) * ce, cos(az) * ce, sin(el));
    float depth;
    marchAndShade(u.cameraPos.xyz, rd, u, dem, demFar, depth);
    // Where only the far-horizon ring stands (beyond-tier haze), depth stays
    // the FAR sentinel: ring terrain is deliberately UNLABELED, and to the
    // label pipeline its texels must read as neutral sky — a hazy silhouette
    // must never vouch for (or occlude) a within-tier feature.
    return float4(depth, 0.0, 0.0, 1.0);
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
    for (uint j = 0; j < ss; j++) {
        for (uint i = 0; i < ss; i++) {
            uint2 c = min(base + uint2(i, j), uint2(w - 1, h - 1));
            acc += src.read(c).rgb;
        }
    }
    return float4(acc / float(ss * ss), 1.0);
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

// Silhouette reconstruction at VIEW rate. Zoomed in, one pano texel spans many
// screen pixels, so the baked alpha's bilinear ramp (and with it the skyline)
// smears into soft texel-scale stairs — "chunky" edges. Treating the alpha as
// a coverage field and re-sharpening it to ~1 screen pixel (the SDF-
// magnification trick: fwidth gives alpha-change-per-pixel, so 1.25·fwidth of
// alpha ≈ 2.5 px of transition) keeps the terrain/sky edge crisp at any zoom.
// Away from the silhouette alpha is flat 0 or 1 → untouched: no general blur.
// Unzoomed, the ramp is already ~1 px wide → the smoothstep degenerates to a
// near-identity, so this is a no-op exactly when the edge was already fine.
static float silhouetteAlpha(float a) {
    float f = min(1.25 * fwidth(a), 0.5);
    return f < 1e-5 ? a : smoothstep(0.5 - f, 0.5 + f, a);
}

fragment float4 panoramaViewFragment(VSOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(0)]],
                                     texture2d<float> pano [[texture(0)]]) {
    float3 rd = viewRay(in.uv, u);
    float4 c = pano.sample(panoSampler, panoUV(rd, u));
    // Sky (baked alpha 0) is recoloured live from the sun; terrain (alpha 1) keeps
    // its baked shading but is dimmed by the sun's altitude (u.terrainBright: full
    // by day → a 0.34 "moonlit" floor at night, computed CPU-side with the sun
    // elevation) so it isn't fully daylit under a night sky. The anti-aliased
    // alpha gives a clean silhouette blend.
    float3 sky = skyColorFor(rd, u.skySunDir.xyz, u.skySunElDeg);
    return float4(mix(sky, c.rgb * u.terrainBright, silhouetteAlpha(c.a)), 1.0);
}

// AR view: same panorama resample as `panoramaViewFragment`, but keeps the baked
// sky/terrain alpha and premultiplies it — sky (alpha 0) becomes transparent so
// the live camera shows through while terrain stays opaque. Used only in AR mode;
// the 3D path above is unchanged.
fragment float4 panoramaViewARFragment(VSOut in [[stage_in]],
                                       constant Uniforms& u [[buffer(0)]],
                                       texture2d<float> pano [[texture(0)]]) {
    float4 c = pano.sample(panoSampler, panoUV(viewRay(in.uv, u), u));
    float a = silhouetteAlpha(c.a);
    return float4(c.rgb * a, a);                 // premultiplied; sky transparent
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
    float2 uv = panoUV(viewRay(in.uv, u), u);
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

    // Two-tier edges so the overlay doesn't bury the real mountains: the
    // SKYLINE (any neighbour is sky — the -0.5 sentinel) keeps the original
    // sensitive threshold and full brightness, because it's the line you align
    // against; INTERNAL shading creases need a much stronger gradient and draw
    // slightly dimmer, which clears the dense hatching on busy rocky faces.
    float minS = min(min(min(tl, tc), min(tr, ml)), min(min(mr, bl), min(bc, br)));
    float e;
    if (minS < 0.0) {
        e = smoothstep(0.08, 0.22, g);                       // skyline: crisp
    } else {
        // Interior creases: stricter than the skyline so rocky faces don't
        // hatch solid, but loose enough that secondary ridges still read.
        // (0.17/0.42 left mid-ground ridges too faint; picked from a
        // side-by-side of six densities on the Mt Hood west view.)
        e = smoothstep(0.13, 0.34, g) * 0.8;
    }
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
