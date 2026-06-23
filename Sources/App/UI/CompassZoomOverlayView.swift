import UIKit

/// Top-center compass tape + zoom readout, ported pixel-for-pixel from RidgeLine's
/// `PanoramaCanvasView` (`setupCompass` / `setupZoomIndicator` and their updates).
/// Driven by mountainView's live heading (deg, 0 = N) and zoom factor (×).
final class CompassZoomOverlayView: UIView {

    private static let noAnim: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
        "hidden": NSNull(), "foregroundColor": NSNull(), "string": NSNull(),
    ]

    private let compassLayer = CALayer()
    private let compassTrack = CAShapeLayer()
    private let compassHeadingText = CATextLayer()
    private var compassCardinals: [CATextLayer] = []

    private let zoomIndicatorLayer = CALayer()
    private let zoomIndicatorText = CATextLayer()

    private var yawDeg: Double = 0
    private var zoomFactor: Double = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupCompass()
        setupZoomIndicator()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func update(headingDeg: Double, zoom: Double) {
        yawDeg = headingDeg
        zoomFactor = zoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateCompass()
        updateZoomIndicator()
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateCompass()
        updateZoomIndicator()
        CATransaction.commit()
    }

    // MARK: - Compass (RidgeLine setupCompass, lines 362-404)

    private func setupCompass() {
        compassLayer.bounds = CGRect(x: 0, y: 0, width: 132, height: 40)
        compassLayer.backgroundColor = UIColor.clear.cgColor
        compassLayer.borderWidth = 0
        compassLayer.actions = Self.noAnim
        layer.addSublayer(compassLayer)

        let trackPath = CGMutablePath()
        trackPath.move(to: CGPoint(x: 16, y: 27))
        trackPath.addLine(to: CGPoint(x: 116, y: 27))
        compassTrack.path = trackPath
        compassTrack.strokeColor = UIColor.white.withAlphaComponent(0.18).cgColor
        compassTrack.lineWidth = 1
        compassTrack.lineCap = .round
        compassTrack.fillColor = nil
        compassTrack.actions = Self.noAnim
        compassLayer.addSublayer(compassTrack)

        compassHeadingText.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        compassHeadingText.fontSize = 12
        compassHeadingText.alignmentMode = .center
        compassHeadingText.foregroundColor = UIColor.white.withAlphaComponent(0.94).cgColor
        compassHeadingText.contentsScale = UIScreen.main.scale
        compassHeadingText.bounds = CGRect(x: 0, y: 0, width: 58, height: 16)
        compassHeadingText.position = CGPoint(x: 66, y: 11)
        compassHeadingText.actions = Self.noAnim
        compassLayer.addSublayer(compassHeadingText)

        compassCardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"].map { text in
            let label = CATextLayer()
            label.string = text
            label.font = UIFont.systemFont(ofSize: 9, weight: .medium)
            label.fontSize = 9
            label.alignmentMode = .center
            label.foregroundColor = UIColor.white.withAlphaComponent(0.58).cgColor
            label.contentsScale = UIScreen.main.scale
            label.bounds = CGRect(x: 0, y: 0, width: 26, height: 12)
            label.isHidden = true
            label.actions = Self.noAnim
            compassLayer.addSublayer(label)
            return label
        }
    }

    /// RidgeLine updateCompass (lines 504-527).
    private func updateCompass() {
        let top = max(safeAreaInsets.top + 12, 16)
        compassLayer.position = CGPoint(x: bounds.midX, y: top + 20)
        compassHeadingText.string = "\(Self.compassDirection(for: yawDeg)) \(Int(yawDeg.rounded()) % 360)°"

        func delta(for azimuth: Double) -> Double {
            var d = (azimuth - yawDeg).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }
        let visibleHalfWindowDeg = 38.0
        let pixelsPerCompassDegree = 50.0 / visibleHalfWindowDeg
        for (i, label) in compassCardinals.enumerated() {
            let azimuth = Double(i) * 45
            let d = delta(for: azimuth)
            let visible = abs(d) <= visibleHalfWindowDeg
            label.isHidden = !visible
            guard visible else { continue }
            label.position = CGPoint(x: 66 + CGFloat(d * pixelsPerCompassDegree), y: 27)
            let prominence = max(0.35, 1 - abs(d) / visibleHalfWindowDeg)
            label.foregroundColor = UIColor.white.withAlphaComponent(0.40 + prominence * 0.48).cgColor
        }
    }

    private static func compassDirection(for headingDeg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        var h = headingDeg.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return dirs[Int((h / 45).rounded()) % 8]
    }

    // MARK: - Zoom (RidgeLine setupZoomIndicator, lines 406-423)

    private func setupZoomIndicator() {
        zoomIndicatorLayer.bounds = CGRect(x: 0, y: 0, width: 52, height: 24)
        zoomIndicatorLayer.backgroundColor = UIColor.clear.cgColor
        zoomIndicatorLayer.borderWidth = 0
        zoomIndicatorLayer.actions = Self.noAnim
        layer.addSublayer(zoomIndicatorLayer)

        zoomIndicatorText.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        zoomIndicatorText.fontSize = 11
        zoomIndicatorText.alignmentMode = .center
        zoomIndicatorText.foregroundColor = UIColor.white.withAlphaComponent(0.86).cgColor
        zoomIndicatorText.contentsScale = UIScreen.main.scale
        zoomIndicatorText.bounds = CGRect(x: 0, y: 0, width: 46, height: 14)
        zoomIndicatorText.position = CGPoint(x: 26, y: 12)
        zoomIndicatorText.actions = Self.noAnim
        zoomIndicatorLayer.addSublayer(zoomIndicatorText)
    }

    /// RidgeLine updateZoomIndicator (lines 529-534).
    private func updateZoomIndicator() {
        let top = max(safeAreaInsets.top + 12, 16)
        zoomIndicatorLayer.position = CGPoint(x: bounds.midX, y: top + 52)
        zoomIndicatorText.string = String(format: "%.1fx", zoomFactor)
        zoomIndicatorLayer.isHidden = bounds.isEmpty
    }
}
