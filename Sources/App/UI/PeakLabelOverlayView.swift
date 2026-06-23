import UIKit
import simd

/// Screen-space peak labels drawn over the live Metal terrain view.
///
/// Each anchor carries the peak's ENU **direction** from the eye (precomputed once
/// per viewpoint: snapped to the DEM summit, with the renderer's curvature +
/// exaggeration folded in). Every frame `project(...)` is called with the SAME
/// camera basis the renderer used that frame, and it inverts the renderer's ray
/// formula so each label lands exactly on the rendered summit and tracks it as you
/// look around. (Structure adapted from PeakPeek's AR3D label overlay; projection
/// is mountainView's own.)
final class PeakLabelOverlayView: UIView {

    struct Anchor {
        let peak: Peak
        /// Unnormalized ENU direction from the eye to the (DEM-snapped) summit,
        /// already including heightScale + curvature drop.
        let direction: SIMD3<Float>
        let distanceMeters: Double
    }

    /// Visible (non-occluded) anchors for the current viewpoint. Set off-main, then
    /// assigned on main; projection reads it each frame.
    var anchors: [Anchor] = [] {
        didSet { rebuildPool() }
    }

    /// Currently selected peak (highlighted with a white outline).
    var selectedPeakID: String?

    /// Screen rects + summit points of the labels shown in the last `project(...)`,
    /// for tap hit-testing.
    private var hitTargets: [(peak: Peak, rect: CGRect, summit: CGPoint)] = []

    /// The peak whose label (capsule or summit dot) is at `point`, if any.
    func peak(at point: CGPoint) -> Peak? {
        for t in hitTargets.reversed() where t.rect.contains(point) { return t.peak }
        // Fall back to the nearest summit dot within a small radius.
        var best: (peak: Peak, d: CGFloat)?
        for t in hitTargets {
            let d = hypot(t.summit.x - point.x, t.summit.y - point.y)
            if d < 30, d < (best?.d ?? .infinity) { best = (t.peak, d) }
        }
        return best?.peak
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Layer pool

    private final class Node {
        let leader = CAShapeLayer()
        let dot = CAShapeLayer()
        let capsule = CALayer()
        let nameText = CATextLayer()
        let elevText = CATextLayer()
        var width: CGFloat = 0

        func setHidden(_ hidden: Bool) {
            leader.isHidden = hidden
            dot.isHidden = hidden
            capsule.isHidden = hidden
        }
    }
    private var pool: [Node] = []

    private static let nameFont = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let elevFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
    private static let capsuleHeight: CGFloat = 22
    private static let dotRadius: CGFloat = 2.6
    private static let tierLeaderHeights: [CGFloat] = [34, 80, 126]

    private func rebuildPool() {
        // Grow the pool to cover all anchors; nodes are reused across frames.
        while pool.count < anchors.count { pool.append(makeNode()) }
        let scale = UIScreen.main.scale
        for (i, a) in anchors.enumerated() {
            let node = pool[i]
            let name = a.peak.name as NSString
            let nameW = ceil(name.size(withAttributes: [.font: Self.nameFont]).width)
            node.nameText.string = a.peak.name
            node.nameText.font = Self.nameFont
            node.nameText.fontSize = Self.nameFont.pointSize
            node.nameText.contentsScale = scale

            let elev = a.peak.elevationMeters > 0 ? UnitText.elevation(meters: a.peak.elevationMeters) : ""
            let elevW = elev.isEmpty ? 0 : ceil((elev as NSString).size(withAttributes: [.font: Self.elevFont]).width) + 14
            node.elevText.string = elev
            node.elevText.font = Self.elevFont
            node.elevText.fontSize = Self.elevFont.pointSize
            node.elevText.contentsScale = scale
            node.elevText.isHidden = elev.isEmpty

            let nameSegW = nameW + 16
            node.nameText.frame = CGRect(x: 8, y: 0, width: nameW + 2, height: Self.capsuleHeight)
            node.elevText.frame = CGRect(x: nameSegW + 6, y: 0, width: max(0, elevW - 12), height: Self.capsuleHeight)
            node.width = nameSegW + elevW
            node.capsule.bounds = CGRect(x: 0, y: 0, width: node.width, height: Self.capsuleHeight)

            // Two-segment capsule: dark name area + teal elevation tab.
            node.capsule.sublayers?.first(where: { $0.name == "elevbg" })?.removeFromSuperlayer()
            if elevW > 0 {
                let tab = CALayer()
                tab.name = "elevbg"
                tab.frame = CGRect(x: nameSegW, y: 0, width: elevW, height: Self.capsuleHeight)
                tab.backgroundColor = TopoStyle.teal.cgColor
                node.capsule.insertSublayer(tab, below: node.elevText)
                node.elevText.foregroundColor = TopoStyle.tealText.cgColor
            }
        }
        if pool.count > anchors.count {
            for i in anchors.count..<pool.count { pool[i].setHidden(true) }
        }
        setNeedsLayout()
    }

    private func makeNode() -> Node {
        let n = Node()
        n.leader.strokeColor = TopoStyle.leader.cgColor
        n.leader.lineWidth = 1
        n.leader.fillColor = nil
        n.dot.fillColor = TopoStyle.teal.cgColor
        n.dot.strokeColor = UIColor.black.withAlphaComponent(0.5).cgColor
        n.dot.lineWidth = 1
        n.dot.path = UIBezierPath(ovalIn: CGRect(x: -Self.dotRadius, y: -Self.dotRadius,
                                                 width: Self.dotRadius * 2, height: Self.dotRadius * 2)).cgPath
        n.capsule.backgroundColor = TopoStyle.capsuleDark.cgColor
        n.capsule.cornerRadius = Self.capsuleHeight / 2
        n.capsule.anchorPoint = CGPoint(x: 0, y: 0.5)
        n.capsule.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 4))
        n.nameText.foregroundColor = UIColor.white.cgColor
        n.nameText.alignmentMode = .left
        n.elevText.alignmentMode = .left
        n.capsule.addSublayer(n.nameText)
        n.capsule.addSublayer(n.elevText)
        layer.addSublayer(n.leader)
        layer.addSublayer(n.capsule)
        layer.addSublayer(n.dot)
        n.setHidden(true)
        return n
    }

    // MARK: - Per-frame projection

    /// Zoom factor (×) at/above which capsule labels appear. Below it, only the
    /// summit dots show; zoom in (or tap a dot) to reveal a name.
    private static let labelZoom: Float = 1.8

    /// Project anchors with the current camera basis (the exact vectors the renderer
    /// used this frame) and lay out them. Dots show by default; capsule labels show
    /// only when zoomed in past `labelZoom`, or for the selected peak. Cheap — call
    /// every frame.
    func project(forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                 tanHalfFovY: Float, aspect: Float, zoom: Float) {
        let W = bounds.width, H = bounds.height
        guard W > 1, H > 1, !anchors.isEmpty else { hideAll(); return }

        struct Hit { let index: Int; let point: CGPoint; let priority: Double }
        var hits: [Hit] = []
        hits.reserveCapacity(anchors.count)
        for (i, a) in anchors.enumerated() {
            let d = a.direction
            let f = simd_dot(d, forward)
            if f <= 0 { continue }                       // behind the camera
            let r = simd_dot(d, right), u = simd_dot(d, up)
            let ndcX = (r / f) / (aspect * tanHalfFovY)
            let ndcY = (u / f) / tanHalfFovY
            if abs(ndcX) > 1.25 || ndcY < -1.25 || ndcY > 1.7 { continue }
            let x = (CGFloat(ndcX) + 1) * 0.5 * W
            let y = (1 - CGFloat(ndcY)) * 0.5 * H
            hits.append(Hit(index: i, point: CGPoint(x: x, y: y), priority: a.peak.priority))
        }
        hits.sort { $0.priority > $1.priority }

        // Dots: light declutter so coincident summits don't pile up.
        var dotKept: [Hit] = []
        for h in hits where dotKept.allSatisfy({ hypot($0.point.x - h.point.x, $0.point.y - h.point.y) >= 13 }) {
            dotKept.append(h)
            if dotKept.count >= 240 { break }
        }

        // Capsules: only when zoomed in (plus the selected peak always). Tighter
        // horizontal declutter than the dots.
        var capsuleIdx = Set<Int>()
        if zoom >= Self.labelZoom {
            var keptCap: [Hit] = []
            for h in dotKept where keptCap.allSatisfy({ abs($0.point.x - h.point.x) >= 46 }) {
                keptCap.append(h)
                if keptCap.count >= 60 { break }
            }
            capsuleIdx = Set(keptCap.map(\.index))
        }
        if let selID = selectedPeakID,
           let sel = dotKept.first(where: { anchors[$0.index].peak.id == selID }) {
            capsuleIdx.insert(sel.index)
        }

        // Stagger leader heights for the shown capsules (ordered left→right).
        let capList = dotKept.filter { capsuleIdx.contains($0.index) }.sorted { $0.point.x < $1.point.x }
        var lastX = [CGFloat](repeating: -.infinity, count: Self.tierLeaderHeights.count)
        var tierFor: [Int: Int] = [:]
        for h in capList {
            var tier = 0
            for t in Self.tierLeaderHeights.indices where h.point.x - lastX[t] >= 132 { tier = t; break }
            if h.point.x - lastX[tier] < 132 {
                tier = lastX.indices.min { lastX[$0] < lastX[$1] } ?? 0
            }
            lastX[tier] = h.point.x
            tierFor[h.index] = tier
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var shown = Set<Int>()
        hitTargets.removeAll(keepingCapacity: true)
        for h in dotKept {
            shown.insert(h.index)
            let node = pool[h.index]
            let peak = anchors[h.index].peak
            node.dot.position = h.point
            node.dot.isHidden = false

            if let tier = tierFor[h.index] {
                let top = CGPoint(x: h.point.x, y: h.point.y - Self.tierLeaderHeights[tier])
                let path = CGMutablePath()
                path.move(to: CGPoint(x: h.point.x, y: h.point.y - Self.dotRadius))
                path.addLine(to: top)
                node.leader.path = path
                node.leader.isHidden = false
                node.capsule.position = top
                node.capsule.isHidden = false
                let selected = peak.id == selectedPeakID
                node.capsule.borderWidth = selected ? 1.5 : 0
                node.capsule.borderColor = selected ? UIColor.white.cgColor : nil
                hitTargets.append((peak, node.capsule.frame.insetBy(dx: -8, dy: -8), h.point))
            } else {
                node.leader.isHidden = true
                node.capsule.isHidden = true
                hitTargets.append((peak, .null, h.point))   // dot is still tappable
            }
        }
        for i in pool.indices where !shown.contains(i) { pool[i].setHidden(true) }
        CATransaction.commit()
    }

    private func hideAll() {
        hitTargets.removeAll(keepingCapacity: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for n in pool { n.setHidden(true) }
        CATransaction.commit()
    }
}
