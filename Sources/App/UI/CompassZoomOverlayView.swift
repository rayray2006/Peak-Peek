import UIKit

/// Top-center compass tape + zoom readout, ported pixel-for-pixel from RidgeLine's
/// `PanoramaCanvasView` (`setupCompass` / `setupZoomIndicator` and their updates).
/// Driven by PeakPeek's live heading (deg, 0 = N) and zoom factor (×).
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
    private var lastAppliedYaw: Double = .nan
    private var lastAppliedZoom: Double = .nan

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupCompass()
        setupZoomIndicator()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func update(headingDeg: Double, zoom: Double) {
        // draw() calls this every frame; reassigning CATextLayer strings and
        // per-cardinal colors forces layer re-renders even when nothing moved.
        // 0.05° is ~0.07 px of cardinal motion — skipping it is invisible.
        if !lastAppliedYaw.isNaN, abs(headingDeg - lastAppliedYaw) < 0.05,
           abs(zoom - lastAppliedZoom) < 0.005 { return }
        lastAppliedYaw = headingDeg
        lastAppliedZoom = zoom
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

    // MARK: - Day/night theme

    /// TopoStyle's dynamic ink/paper resolved for THIS view's traits — the
    /// scene flips to dark after sunset and the strip inverts with it.
    private var inkResolved: UIColor { TopoStyle.ink.resolvedColor(with: traitCollection) }
    private var paperResolved: UIColor { TopoStyle.paper.resolvedColor(with: traitCollection) }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyThemeColors()
        updateCompass()
        updateZoomIndicator()
        CATransaction.commit()
    }

    /// Everything static that carries a themed color; the per-frame updates
    /// (cardinal prominence) resolve on their own.
    private func applyThemeColors() {
        compassTrack.strokeColor = inkResolved.withAlphaComponent(0.45).cgColor
        compassHeadingText.foregroundColor = inkResolved.cgColor
        zoomIndicatorText.foregroundColor = inkResolved.withAlphaComponent(0.5).cgColor
    }

    // MARK: - Compass (RidgeLine setupCompass, lines 362-404)

    private func setupCompass() {
        compassLayer.bounds = CGRect(x: 0, y: 0, width: 132, height: 44)
        compassLayer.backgroundColor = UIColor.clear.cgColor
        compassLayer.borderWidth = 0
        compassLayer.actions = Self.noAnim
        layer.addSublayer(compassLayer)

        let trackPath = CGMutablePath()
        trackPath.move(to: CGPoint(x: 16, y: 31))
        trackPath.addLine(to: CGPoint(x: 116, y: 31))
        compassTrack.path = trackPath
        compassTrack.strokeColor = inkResolved.withAlphaComponent(0.45).cgColor
        compassTrack.lineWidth = 1
        compassTrack.lineCap = .butt
        compassTrack.fillColor = nil
        compassTrack.actions = Self.noAnim
        compassLayer.addSublayer(compassTrack)

        compassHeadingText.font = PPFont.grotesk(15, .semibold)
        compassHeadingText.fontSize = 15
        compassHeadingText.alignmentMode = .center
        compassHeadingText.foregroundColor = inkResolved.cgColor
        compassHeadingText.contentsScale = UIScreen.main.scale
        compassHeadingText.bounds = CGRect(x: 0, y: 0, width: 90, height: 19)
        compassHeadingText.position = CGPoint(x: 66, y: 12)
        compassHeadingText.actions = Self.noAnim
        compassLayer.addSublayer(compassHeadingText)

        compassCardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"].map { text in
            let label = CATextLayer()
            label.string = text
            label.font = PPFont.plexMono(10)
            label.fontSize = 10
            label.alignmentMode = .center
            label.foregroundColor = inkResolved.withAlphaComponent(0.6).cgColor
            label.contentsScale = UIScreen.main.scale
            label.bounds = CGRect(x: 0, y: 0, width: 26, height: 13)
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
        compassHeadingText.string = "\(UnitText.compassDirection(bearingDeg: yawDeg)) \(Int(yawDeg.rounded()) % 360)°"

        func delta(for azimuth: Double) -> Double {
            var d = (azimuth - yawDeg).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }
        let visibleHalfWindowDeg = 38.0
        let pixelsPerCompassDegree = 50.0 / visibleHalfWindowDeg
        var cardinalXs: [CGFloat] = []
        for (i, label) in compassCardinals.enumerated() {
            let azimuth = Double(i) * 45
            let d = delta(for: azimuth)
            let visible = abs(d) <= visibleHalfWindowDeg
            label.isHidden = !visible
            guard visible else { continue }
            let x = 66 + CGFloat(d * pixelsPerCompassDegree)
            label.position = CGPoint(x: x, y: 31)
            cardinalXs.append(x)
            let prominence = max(0.35, 1 - abs(d) / visibleHalfWindowDeg)
            label.foregroundColor = inkResolved.withAlphaComponent(0.35 + prominence * 0.55).cgColor
        }

        // The template's strip is "line — SE — line": rebuild the track with a
        // gap around each riding cardinal so the hairline never strikes
        // through the letters.
        let gapHalf: CGFloat = 11
        let path = CGMutablePath()
        var cursor: CGFloat = 16
        for x in cardinalXs.sorted() {
            let gapStart = max(cursor, x - gapHalf)
            if gapStart > cursor {
                path.move(to: CGPoint(x: cursor, y: 31))
                path.addLine(to: CGPoint(x: gapStart, y: 31))
            }
            cursor = max(cursor, x + gapHalf)
        }
        if cursor < 116 {
            path.move(to: CGPoint(x: cursor, y: 31))
            path.addLine(to: CGPoint(x: 116, y: 31))
        }
        compassTrack.path = path
    }

    // MARK: - Zoom (RidgeLine setupZoomIndicator, lines 406-423)

    private func setupZoomIndicator() {
        zoomIndicatorLayer.bounds = CGRect(x: 0, y: 0, width: 52, height: 24)
        zoomIndicatorLayer.backgroundColor = UIColor.clear.cgColor
        zoomIndicatorLayer.borderWidth = 0
        zoomIndicatorLayer.actions = Self.noAnim
        layer.addSublayer(zoomIndicatorLayer)

        zoomIndicatorText.font = PPFont.plexMono(11)
        zoomIndicatorText.fontSize = 11
        zoomIndicatorText.alignmentMode = .center
        zoomIndicatorText.foregroundColor = inkResolved.withAlphaComponent(0.5).cgColor
        zoomIndicatorText.contentsScale = UIScreen.main.scale
        zoomIndicatorText.bounds = CGRect(x: 0, y: 0, width: 46, height: 14)
        zoomIndicatorText.position = CGPoint(x: 26, y: 12)
        zoomIndicatorText.actions = Self.noAnim
        zoomIndicatorLayer.addSublayer(zoomIndicatorText)
    }

    /// RidgeLine updateZoomIndicator (lines 529-534).
    private func updateZoomIndicator() {
        let top = max(safeAreaInsets.top + 12, 16)
        zoomIndicatorLayer.position = CGPoint(x: bounds.midX, y: top + 58)
        zoomIndicatorText.string = String(format: "%.1f×", zoomFactor)
        zoomIndicatorLayer.isHidden = bounds.isEmpty
    }
}
