import simd

/// GPU uniforms for the terrain raymarcher.
///
/// IMPORTANT: the memory layout of this struct must match `struct Uniforms`
/// in `Shaders.metal` byte-for-byte. We use `SIMD4<Float>` for every vec3
/// quantity so that Swift and MSL agree on 16-byte alignment with no
/// hand-counted padding. Total stride is 208 bytes (a multiple of 16).
struct Uniforms {
    /// Camera position in local ENU meters (x=east, y=north, z=up). `.w` unused.
    var cameraPos: SIMD4<Float> = .zero
    /// Normalized look direction. `.w` unused.
    var forward: SIMD4<Float> = .zero
    /// Normalized camera-right. `.w` unused.
    var right: SIMD4<Float> = .zero
    /// Normalized camera-up. `.w` unused.
    var up: SIMD4<Float> = .zero
    /// Normalized direction *towards* the sun. `.w` unused.
    var sunDir: SIMD4<Float> = .zero

    /// Render target size in pixels.
    var resolution: SIMD2<Float> = .zero
    /// tan(verticalFOV / 2).
    var tanHalfFovY: Float = 0
    /// width / height.
    var aspect: Float = 1

    /// Far clip distance for ray marching, in meters.
    var maxDistance: Float = 80_000
    /// Earth-curvature + refraction term: apparent drop = curvatureK * t^2.
    /// Equals 1 / (2 * R_effective).
    var curvatureK: Float = 0
    /// Vertical exaggeration applied to sampled heights (1.0 = true scale).
    var heightScale: Float = 1
    /// Misc/animation parameter (procedural mode only).
    var time: Float = 0

    // --- DEM sampling (Phase 1+) ---
    /// ENU (east,north) meters of the grid's south-west corner (lower-left).
    var gridMinENU: SIMD2<Float> = .zero
    /// Meters per column (east) and per row (north) in the DEM grid.
    var cellSizeENU: SIMD2<Float> = .one
    /// Grid dimensions (ncols, nrows) as floats.
    var gridDims: SIMD2<Float> = .zero
    /// 1 = sample the bound DEM texture, 0 = procedural fallback.
    var useDEM: Float = 0
    /// Maximum terrain height in the grid (meters, post heightScale). Used to
    /// bound each ray's march window via the curvature envelope.
    var globalMaxHeight: Float = 4000

    /// Half-height of the baked panorama's vertical band, in radians. The
    /// equirectangular panorama covers elevation [-panoElevMax, +panoElevMax].
    var panoElevMax: Float = 1.0472   // 60°

    // --- Far (coarse) DEM tier, bound at texture(1) ---
    /// 1 = a coarse, wide-coverage DEM is bound for distance beyond the near grid;
    /// 0 = near grid only. Sampled only where the near grid has no coverage.
    var useFar: Float = 0
    /// Far grid SW corner in ENU meters (same meaning as `gridMinENU`).
    var gridMinENU2: SIMD2<Float> = .zero
    /// Far grid meters per column/row (same meaning as `cellSizeENU`).
    var cellSizeENU2: SIMD2<Float> = .one
    /// Far grid (ncols, nrows).
    var gridDims2: SIMD2<Float> = .zero

    /// Real sun direction (ENU) at the display time. Drives the dynamic sky colour in
    /// the 3D view pass (day blue / sunset orange / night dark). Terrain shading stays
    /// baked with `sunDir`; this only colours the sky. `.w` unused.
    var skySunDir: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 0)

    // --- ENU projection correction (set alongside the DEM uniforms) ---
    // The ENU frame flattens the lat/lon grid with a single cos(refLat), which
    // shifts distant azimuths off their true compass bearings (meridian
    // convergence + the poleward bulge of great-circle sightlines) — ~0.5° at
    // 120 km in mid-latitudes, over 1° at 60°N. These let the shader undo that
    // per sample; the label anchors apply the same forward mapping so labels
    // stay glued to the rendered summits. Defaults are the identity (procedural
    // mode, or uniforms built without a DEM, behave exactly as before).
    /// Reference latitude of the ENU origin, radians.
    var refLatRad: Float = 0
    /// cos(refLatRad). 1 = identity (no correction).
    var cosRefLat: Float = 1
    /// tan(refLatRad) / (2 · R_enu): geodesic-bulge northing (m) per (m easting)².
    var geoK: Float = 0
}

extension Uniforms {
    /// Meters per degree of latitude (and of longitude at the equator) used by the
    /// ENU mapping everywhere — must match `kMetersPerDegLat` in `Shaders.metal`.
    static let metersPerDegree = 111_320.0
    /// Sphere radius implied by that scale (111_320 · 180/π ≈ 6,378,100 m); the
    /// geodesic-bulge term `geoK` is derived from it on both CPU and GPU.
    static let enuEarthRadiusMeters = 111_320.0 * 180.0 / .pi
}
