import simd

/// GPU uniforms for the terrain raymarcher.
///
/// IMPORTANT: the memory layout of this struct must match `struct Uniforms`
/// in `Shaders.metal` byte-for-byte. We use `SIMD4<Float>` for every vec3
/// quantity so that Swift and MSL agree on 16-byte alignment with no
/// hand-counted padding. Total stride is 112 bytes (a multiple of 16).
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
    var _pad2: Float = 0
    var _pad3: Float = 0
    var _pad4: Float = 0
}
