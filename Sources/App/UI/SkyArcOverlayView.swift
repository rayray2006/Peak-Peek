import UIKit
import simd

/// Sun and moon day-path arcs + discs over the live terrain. The path samples are
/// precomputed ENU directions (from `Ephemeris`, once per viewpoint); every frame
/// `project(...)` maps them to screen with the SAME camera basis the renderer used,
/// so the arcs track the sky correctly as you look around. (Styling matches
/// RidgeLine's sky layers.)
final class SkyArcOverlayView: UIView {

    /// Precomputed ENU directions for each path sample, and the current disc dirs.
    var sunDirs: [SIMD3<Float>] = []
    var moonDirs: [SIMD3<Float>] = []
    var sunNowDir: SIMD3<Float>?
    var moonNowDir: SIMD3<Float>?

    private let sunArc = CAShapeLayer()
    private let moonArc = CAShapeLayer()
    private let sunDisc = CAShapeLayer()
    private let moonDisc = CAShapeLayer()

    /// ENU direction (az clockwise from north, el up) — matches the shader's ray.
    static func enu(azimuthDeg: Double, elevationDeg: Double) -> SIMD3<Float> {
        let az = azimuthDeg * .pi / 180, el = elevationDeg * .pi / 180
        let ce = cos(el)
        return SIMD3<Float>(Float(sin(az) * ce), Float(cos(az) * ce), Float(sin(el)))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        for (arc, color) in [
            (sunArc, UIColor(red: 0.86, green: 0.66, blue: 0.12, alpha: 0.75)),
            (moonArc, UIColor(white: 0.75, alpha: 0.55)),
        ] {
            arc.strokeColor = color.cgColor
            arc.fillColor = nil
            arc.lineWidth = 1.2
            arc.lineCap = .round
            arc.lineJoin = .round
            layer.addSublayer(arc)
        }

        let sunR: CGFloat = 5, moonR: CGFloat = 4.5
        sunDisc.path = CGPath(ellipseIn: CGRect(x: -sunR, y: -sunR, width: 2 * sunR, height: 2 * sunR), transform: nil)
        sunDisc.fillColor = UIColor(red: 0.95, green: 0.73, blue: 0.10, alpha: 1).cgColor
        sunDisc.shadowColor = sunDisc.fillColor
        sunDisc.shadowOpacity = 0.8
        sunDisc.shadowRadius = 8
        sunDisc.shadowOffset = .zero
        moonDisc.path = CGPath(ellipseIn: CGRect(x: -moonR, y: -moonR, width: 2 * moonR, height: 2 * moonR), transform: nil)
        moonDisc.fillColor = UIColor(white: 0.85, alpha: 1).cgColor
        for d in [sunDisc, moonDisc] { d.isHidden = true; layer.addSublayer(d) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func project(forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                 tanHalfFovY: Float, aspect: Float) {
        let W = bounds.width, H = bounds.height
        guard W > 1, H > 1 else { return }

        // Project one ENU direction; nil if too far off the forward axis (so arcs
        // break cleanly instead of stretching to infinity near the edges).
        func screen(_ d: SIMD3<Float>) -> CGPoint? {
            let f = simd_dot(d, forward)
            if f <= 0.1 { return nil }
            let r = simd_dot(d, right), u = simd_dot(d, up)
            let ndcX = (r / f) / (aspect * tanHalfFovY)
            let ndcY = (u / f) / tanHalfFovY
            return CGPoint(x: (CGFloat(ndcX) + 1) * 0.5 * W, y: (1 - CGFloat(ndcY)) * 0.5 * H)
        }

        func polyline(_ dirs: [SIMD3<Float>]) -> CGPath {
            let path = CGMutablePath()
            var penDown = false
            for d in dirs {
                if let p = screen(d) {
                    if penDown { path.addLine(to: p) } else { path.move(to: p); penDown = true }
                } else {
                    penDown = false        // break the arc where it passes behind/aside
                }
            }
            return path
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sunArc.path = polyline(sunDirs)
        moonArc.path = polyline(moonDirs)
        positionDisc(sunDisc, dir: sunNowDir, screen: screen)
        positionDisc(moonDisc, dir: moonNowDir, screen: screen)
        CATransaction.commit()
    }

    private func positionDisc(_ disc: CAShapeLayer, dir: SIMD3<Float>?, screen: (SIMD3<Float>) -> CGPoint?) {
        if let dir, let p = screen(dir) {
            disc.position = p
            disc.isHidden = false
        } else {
            disc.isHidden = true
        }
    }
}
