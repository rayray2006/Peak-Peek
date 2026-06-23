import Foundation
import Metal
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Argument parsing

func argValue(_ name: String, _ def: Float) -> Float {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Float(args[i + 1]) {
        return v
    }
    return def
}
func argInt(_ name: String, _ def: Int) -> Int {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) {
        return v
    }
    return def
}
func argStr(_ name: String, _ def: String) -> String {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        return args[i + 1]
    }
    return def
}

let width   = argInt("--width", 1206 / 2)      // half of the iPhone screenshot, keeps it quick
let height  = argInt("--height", 2622 / 2)
let azimuth = argValue("--azimuth", 240)        // SW, matching the screenshot compass
let pitch   = argValue("--pitch", -2)
let fov     = argValue("--fov", 55)
let heightScale = argValue("--exaggeration", 1)
let outPath = argStr("--out", "/tmp/relief.png")

// Camera geographic location (default: Buckner Mountain summit, North Cascades).
let camLat  = Double(argValue("--lat", 48.4631))
let camLon  = Double(argValue("--lon", -121.0686))
let eyeHeight = argValue("--eye", 2)
let demPath = argStr("--dem", "DEMCache/cascades.asc")

// MARK: - Metal setup

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("No Metal device available.\n".data(using: .utf8)!)
    exit(1)
}

let renderer: TerrainRenderer
do {
    renderer = try TerrainRenderer(device: device, preferSource: true)
} catch {
    FileHandle.standardError.write("Renderer init failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// Offscreen render target.
let texDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: TerrainRenderer.colorFormat,
    width: width, height: height, mipmapped: false)
texDesc.usage = [.renderTarget, .shaderRead]
texDesc.storageMode = .shared
guard let target = device.makeTexture(descriptor: texDesc) else {
    FileHandle.standardError.write("Failed to allocate render target.\n".data(using: .utf8)!)
    exit(1)
}

// Load DEM, build height texture, place camera on the ground at (camLat,camLon).
let dem: DEMTile
do {
    dem = try DEMTile.load(ascPath: demPath)
} catch {
    FileHandle.standardError.write("DEM load failed (\(demPath)): \(error)\n".data(using: .utf8)!)
    exit(1)
}
guard let demTexture = dem.makeTexture(device: device) else {
    FileHandle.standardError.write("Failed to build DEM texture.\n".data(using: .utf8)!)
    exit(1)
}
renderer.heightTexture = demTexture

let stats = dem.elevationStats()
FileHandle.standardError.write(String(format: "DEM elev range %.0f..%.0f m; max at (%.4f, %.4f)\n",
                                      stats.min, stats.max, stats.maxLat, stats.maxLon).data(using: .utf8)!)

// Snap to the highest summit within ~600 m of the requested point (unless --nosnap).
let snap = !CommandLine.arguments.contains("--nosnap")
var effLat = camLat, effLon = camLon
if snap {
    let radius = Double(argValue("--snapradius", 600))
    let hi = dem.highestNear(lat: camLat, lon: camLon, radiusMeters: radius)
    effLat = hi.lat; effLon = hi.lon
}
let groundElev = dem.elevation(lat: effLat, lon: effLon)
let camElev = groundElev + eyeHeight

var camera = PanoramaCamera(
    position: SIMD3<Float>(0, 0, camElev),   // ENU origin = camera lon/lat
    azimuthDegrees: azimuth,
    pitchDegrees: pitch,
    verticalFovDegrees: fov)
camera.heightScale = heightScale
var uniforms = camera.makeUniforms(width: width, height: height)
dem.applyDEMUniforms(to: &uniforms, refLat: effLat, refLon: effLon)

// MARK: - Render (timed)

// --panorama: bake the full 360° once, then render the view by sampling it
// (verifies the seamless look-around path). Otherwise: direct perspective march.
let usePanorama = CommandLine.arguments.contains("--panorama")
if usePanorama {
    renderer.panoramaWidth = argInt("--panowidth", 16384)
    let bakeStart = DispatchTime.now()
    renderer.bakePanorama(uniforms: uniforms)
    let bakeMs = Double(DispatchTime.now().uptimeNanoseconds - bakeStart.uptimeNanoseconds) / 1_000_000
    FileHandle.standardError.write(String(format: "Panorama baked (w=%d) in %.1f ms\n",
                                          renderer.panoramaWidth, bakeMs).data(using: .utf8)!)
}

let start = DispatchTime.now()
guard let cb = renderer.commandQueue.makeCommandBuffer() else { exit(1) }
if usePanorama {
    renderer.encodeView(uniforms: uniforms, into: target, commandBuffer: cb)
} else {
    renderer.encode(uniforms: uniforms, into: target, commandBuffer: cb)
}
cb.commit()
cb.waitUntilCompleted()
let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

if let err = cb.error {
    FileHandle.standardError.write("GPU error: \(err)\n".data(using: .utf8)!)
    exit(1)
}
let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0

// Optional warm benchmark: re-render N times and report best GPU time (the
// per-frame view cost in panorama mode, or the full march otherwise).
let bench = argInt("--bench", 0)
var bestGpu = gpuMs
for _ in 0..<bench {
    guard let cb2 = renderer.commandQueue.makeCommandBuffer() else { break }
    if usePanorama {
        renderer.encodeView(uniforms: uniforms, into: target, commandBuffer: cb2)
    } else {
        renderer.encode(uniforms: uniforms, into: target, commandBuffer: cb2)
    }
    cb2.commit(); cb2.waitUntilCompleted()
    bestGpu = min(bestGpu, (cb2.gpuEndTime - cb2.gpuStartTime) * 1000.0)
}

// MARK: - Read back -> PNG

let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
target.getBytes(&pixels,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
guard let ctx = CGContext(data: &pixels,
                          width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                          space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
      let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("Failed to build CGImage.\n".data(using: .utf8)!)
    exit(1)
}

let outURL = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("Failed to create image destination.\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("Failed to write PNG.\n".data(using: .utf8)!)
    exit(1)
}

print(String(format: "Rendered %dx%d  az=%.0f pitch=%.0f fov=%.0f  cam(%.4f,%.4f) ground=%.0fm  DEM %dx%d  cpu+gpu %.2f ms  gpu %.2f ms  bestGpu %.2f ms -> %@",
             width, height, azimuth, pitch, fov, effLat, effLon, groundElev,
             dem.ncols, dem.nrows, elapsedMs, gpuMs, bestGpu, outPath))
