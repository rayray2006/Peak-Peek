import Foundation

/// Locates and loads the Metal shader source at runtime.
///
/// We compile the shader from source via `device.makeLibrary(source:)` rather
/// than relying on a precompiled `default.metallib`. This keeps a single code
/// path that works for both the iOS app bundle and the macOS command-line
/// harness (CLI tools have no resource bundle), and makes shader iteration
/// fast — no metallib bundling required.
enum ShaderLoader {
    static func loadSource() throws -> String {
        // 1) App bundle (iOS, and any target that copies Shaders.metal in).
        if let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        // 2) Dev fallback: sibling of this Swift source file in the repo.
        let here = URL(fileURLWithPath: #filePath)
        let sibling = here.deletingLastPathComponent().appendingPathComponent("Shaders.metal")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return try String(contentsOf: sibling, encoding: .utf8)
        }
        // 3) Environment override (useful for sandboxed test runs).
        if let path = ProcessInfo.processInfo.environment["MOUNTAINVIEW_SHADER_PATH"] {
            return try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        }
        throw NSError(domain: "ShaderLoader", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Shaders.metal (bundle, \(sibling.path), or MOUNTAINVIEW_SHADER_PATH)."
        ])
    }
}
