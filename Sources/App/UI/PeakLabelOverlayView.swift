import UIKit
import simd

/// User-facing peak/lake label density, cycled from the action menu
/// (All → Sparse → Saved → None). Sparse thins by SCREEN-space separation, so
/// zooming in reveals everything again; Saved shows only bookmarked (orange)
/// and climbed (green) peaks, names always on; None hides the overlay (the
/// selected peak's direction marker stays).
enum LabelDensity: Int, CaseIterable {
    case all, sparse, saved, none

    var title: String {
        switch self {
        case .all: return "All"
        case .sparse: return "Sparse"
        case .saved: return "Saved"
        case .none: return "None"
        }
    }

    var next: LabelDensity {
        LabelDensity(rawValue: (rawValue + 1) % Self.allCases.count) ?? .all
    }
}

/// Screen-space peak labels drawn over the live Metal terrain view.
///
/// Each anchor carries the peak's ENU **direction** from the eye (precomputed once
/// per viewpoint: snapped to the DEM summit, with the renderer's curvature +
/// exaggeration folded in). Every frame `project(...)` is called with the SAME
/// camera basis the renderer used that frame, and it inverts the renderer's ray
/// formula so each label lands exactly on the rendered summit and tracks it as you
/// look around. (Structure adapted from PeakPeek's AR3D label overlay; projection
/// is PeakPeek's own.)
final class PeakLabelOverlayView: UIView {

    struct Anchor {
        let peak: Peak
        /// Unnormalized ENU direction from the eye to the (DEM-snapped) summit,
        /// already including heightScale + curvature drop.
        let direction: SIMD3<Float>
        let distanceMeters: Double
        /// Water feature (lake/reservoir): blue dot + tinted name instead of the
        /// summit red. Same declutter/tap behavior as peaks.
        var isWater: Bool = false
    }

    /// Visible (non-occluded) anchors for the current viewpoint. Set off-main, then
    /// assigned on main; projection reads it each frame.
    var anchors: [Anchor] = [] {
        didSet { rebuildPool() }
    }

    /// Currently selected peak (highlighted with a white outline).
    var selectedPeakID: String?

    /// A searched/selected peak shown as an accent-colored DIRECTION marker when it is not already
    /// an on-screen label (off to the side, behind the camera, or occluded). Points
    /// toward the peak on the horizon and carries its distance.
    struct Target {
        let id: String
        let name: String
        let direction: SIMD3<Float>   // ENU direction from the eye (az/el/dist)
        let distanceText: String
    }
    var target: Target? { didSet { if target == nil { hideTarget() } } }

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
        setupTarget()
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

    private static let nameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    private static let elevFont = UIFont.systemFont(ofSize: 11, weight: .regular)
    private static let capsuleHeight: CGFloat = 26
    private static let hPad: CGFloat = 11
    private static let gap: CGFloat = 7
    private static let dotRadius: CGFloat = 3
    private static let tierLeaderHeights: [CGFloat] = [30, 74, 118]
    private static let pillBG = UIColor.black.withAlphaComponent(0.55).cgColor
    /// Summit dots: red (reads over snow, rock and haze alike).
    private static let peakFill = UIColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1).cgColor
    /// Water-feature styling: lake-blue dot + a light-blue name tint.
    private static let waterFill = UIColor(red: 0.36, green: 0.67, blue: 0.95, alpha: 1).cgColor
    private static let waterText = UIColor(red: 0.75, green: 0.88, blue: 1.00, alpha: 1).cgColor
    /// Saved-mode tints, matching the info-card chips: climbed = green,
    /// bookmarked = orange (climbed wins when a peak is somehow both).
    private static let climbedFill = UIColor.systemGreen.cgColor
    private static let climbedText = UIColor(red: 0.62, green: 0.92, blue: 0.66, alpha: 1).cgColor
    private static let bookmarkFill = UIColor.systemOrange.cgColor
    private static let bookmarkText = UIColor(red: 1.00, green: 0.80, blue: 0.50, alpha: 1).cgColor

    /// How many leading anchors have configured pool nodes. `project(...)` draws
    /// only below this — a node still holding the PREVIOUS viewpoint's text must
    /// never be shown for the new anchor at the same index.
    private var configuredCount = 0
    /// Invalidates an in-flight chunked build when `anchors` changes again.
    private var poolGeneration = 0

    private func rebuildPool() {
        // Configuring a node measures two strings and touches five layers; doing
        // all ~600 anchors in one synchronous pass stalled the main thread — a
        // visible hitch right as the freshly loaded view became interactive.
        // Build in chunks a runloop tick apart; labels stream in over a few frames.
        poolGeneration &+= 1
        configuredCount = 0
        // Precompute the angular-declutter inputs (parallel to `anchors`).
        unitDirs = anchors.map { simd_normalize($0.direction) }
        anchorAz = anchors.map { atan2($0.direction.x, $0.direction.y) }
        if pool.count > anchors.count {
            for i in anchors.count..<pool.count { pool[i].setHidden(true) }
        }
        configureNodes(from: 0, generation: poolGeneration)
    }

    private func configureNodes(from start: Int, generation: Int) {
        guard generation == poolGeneration else { return }   // superseded mid-build
        let end = min(anchors.count, start + 120)
        while pool.count < end { pool.append(makeNode()) }
        let scale = UIScreen.main.scale
        let textY = (Self.capsuleHeight - 18) / 2
        for i in start..<end {
            let a = anchors[i]
            let node = pool[i]
            let name = a.peak.name as NSString
            let nameW = ceil(name.size(withAttributes: [.font: Self.nameFont]).width)
            node.nameText.string = a.peak.name
            node.nameText.font = Self.nameFont
            node.nameText.fontSize = Self.nameFont.pointSize
            node.nameText.contentsScale = scale
            node.nameText.frame = CGRect(x: Self.hPad, y: textY, width: nameW + 1, height: 18)

            let elev = a.peak.elevationMeters > 0 ? UnitText.elevation(meters: a.peak.elevationMeters) : ""
            let elevW = elev.isEmpty ? 0 : ceil((elev as NSString).size(withAttributes: [.font: Self.elevFont]).width)
            node.elevText.string = elev
            node.elevText.font = Self.elevFont
            node.elevText.fontSize = Self.elevFont.pointSize
            node.elevText.contentsScale = scale
            node.elevText.isHidden = elev.isEmpty
            node.elevText.frame = CGRect(x: Self.hPad + nameW + Self.gap, y: textY, width: elevW + 1, height: 18)

            node.width = Self.hPad + nameW + (elev.isEmpty ? 0 : Self.gap + elevW) + Self.hPad
            node.capsule.bounds = CGRect(x: 0, y: 0, width: node.width, height: Self.capsuleHeight)
        }
        configuredCount = end
        if end < anchors.count {
            DispatchQueue.main.async { [weak self] in
                self?.configureNodes(from: end, generation: generation)
            }
        } else {
            setNeedsLayout()
        }
    }

    private func makeNode() -> Node {
        let n = Node()
        // Layered by role, not by node order: all dots < all leaders < all capsules,
        // so a busy summit field never draws its dots OVER a neighbor's name pill.
        n.dot.zPosition = 1
        n.leader.zPosition = 2
        n.capsule.zPosition = 3
        n.leader.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        n.leader.lineWidth = 1
        n.leader.fillColor = nil
        n.dot.fillColor = Self.peakFill
        n.dot.strokeColor = UIColor.black.withAlphaComponent(0.55).cgColor
        n.dot.lineWidth = 1
        n.dot.path = UIBezierPath(ovalIn: CGRect(x: -Self.dotRadius, y: -Self.dotRadius,
                                                 width: Self.dotRadius * 2, height: Self.dotRadius * 2)).cgPath
        // Clean upright pill, matching the HUD's translucent-black chrome.
        n.capsule.backgroundColor = Self.pillBG
        n.capsule.cornerRadius = Self.capsuleHeight / 2
        n.capsule.anchorPoint = CGPoint(x: 0.5, y: 1)   // bottom-centre sits on the leader top
        n.nameText.foregroundColor = UIColor.white.cgColor
        n.nameText.alignmentMode = .left
        n.elevText.foregroundColor = UIColor.white.withAlphaComponent(0.6).cgColor
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

    /// User-facing label density (Labels menu item). The declutter spacing is
    /// zoom-scaled ANGULAR separation (see `recomputeSelection`), so `.sparse`
    /// shows only well-separated features at 1× — zooming spreads the world
    /// across more pixels and everything reappears. Panning never changes it.
    /// `.none` hides dots and capsules entirely; the selected peak keeps its
    /// direction marker so search/selection still works.
    var density: LabelDensity = .all {
        didSet { if density != oldValue { setNeedsLayout() } }
    }

    /// Saved-list membership for the `.saved` density: only these anchors show,
    /// dot + name tinted green (climbed) / orange (bookmarked). Pushed from the
    /// peak-list store whenever it changes.
    var climbedIDs: Set<String> = [] { didSet { savedListsStamp &+= 1 } }
    var bookmarkedIDs: Set<String> = [] { didSet { savedListsStamp &+= 1 } }
    /// Bumped when the saved lists change so the stable selection recomputes.
    private var savedListsStamp = 0

    /// (dot spacing pt, capsule x-spacing pt, capsule budget)
    private var densityKnobs: (dot: CGFloat, capX: CGFloat, capMax: Int) {
        switch density {
        case .all, .saved: return (13, 46, 60)
        case .sparse: return (48, 130, 24)
        case .none: return (0, 0, 0)
        }
    }

    // MARK: - Stable (pan-independent) selection

    /// WHICH anchors are labeled is decided here, in WORLD space, over the full
    /// 360° — a greedy priority contest spaced by ANGULAR separation (the
    /// screen-point knobs divided by the current pixels-per-radian). Panning
    /// merely culls this stable set to the screen, so labels never blink in and
    /// out as you look around; only zoom (which rescales the angular spacing),
    /// density, selection or new anchors re-run the contest.
    private struct StableSelection {
        var dots: [Int] = []
        var capsules = Set<Int>()
        var tierFor: [Int: Int] = [:]
        // Inputs this selection was computed for (its cache key):
        var pixelsPerRadian: CGFloat = -1
        var capsulesOn = false
        var densityRaw = -1
        var configured = -1
        var generation = -1
        var selectedID: String?
        var savedStamp = -1
    }
    private var selection = StableSelection()
    /// Unit direction + azimuth per anchor (parallel to `anchors`).
    private var unitDirs: [SIMD3<Float>] = []
    private var anchorAz: [Float] = []

    private func selectionIsCurrent(pixelsPerRadian: CGFloat, capsulesOn: Bool) -> Bool {
        selection.generation == poolGeneration
            && selection.configured == configuredCount
            && selection.densityRaw == density.rawValue
            && selection.capsulesOn == capsulesOn
            && selection.selectedID == selectedPeakID
            && selection.savedStamp == savedListsStamp
            // Re-run on a ≥3% zoom change, not continuously while pinching.
            && abs(pixelsPerRadian - selection.pixelsPerRadian) <= selection.pixelsPerRadian * 0.03
    }

    private func recomputeSelection(pixelsPerRadian: CGFloat, capsulesOn: Bool) {
        var sel = StableSelection()
        sel.pixelsPerRadian = pixelsPerRadian
        sel.capsulesOn = capsulesOn
        sel.densityRaw = density.rawValue
        sel.configured = configuredCount
        sel.generation = poolGeneration
        sel.selectedID = selectedPeakID
        sel.savedStamp = savedListsStamp
        defer { selection = sel }
        let knobs = densityKnobs
        guard density != .none, configuredCount > 0, pixelsPerRadian > 1 else { return }
        let angDot = Float(knobs.dot / pixelsPerRadian)
        let angCap = Float(knobs.capX / pixelsPerRadian)

        func azDelta(_ a: Float, _ b: Float) -> Float {
            let d = abs(a - b)
            return d > .pi ? 2 * .pi - d : d
        }

        // Only anchors with configured pool nodes contest (the chunked build
        // streams them in over a few frames; `configured` in the cache key
        // grows the set with them).
        var order = (0..<configuredCount).filter { i in
            guard density == .saved else { return true }
            let id = anchors[i].peak.id
            return climbedIDs.contains(id) || bookmarkedIDs.contains(id)
        }
        // Deterministic order (index tie-break), so equal priorities can't
        // reshuffle the outcome between recomputes.
        order.sort {
            let pa = anchors[$0].peak.priority, pb = anchors[$1].peak.priority
            return pa == pb ? $0 < $1 : pa > pb
        }
        // The selected peak contests first, so its label always survives.
        if let selID = selectedPeakID,
           let pos = order.firstIndex(where: { anchors[$0].peak.id == selID }) {
            order.insert(order.remove(at: pos), at: 0)
        }

        // Dots: greedy keep-if-separated in 3D angle (chord ≈ angle at these
        // sizes, and it handles summits stacked in elevation too). The cheap
        // azimuth early-out skips the vector math for the vast majority of
        // pairs (window widened ×1.3 to stay conservative at high elevations).
        for i in order {
            let az = anchorAz[i], dir = unitDirs[i]
            var ok = true
            for k in sel.dots {
                if azDelta(az, anchorAz[k]) >= angDot * 1.3 { continue }
                if simd_distance(dir, unitDirs[k]) < angDot { ok = false; break }
            }
            if ok { sel.dots.append(i) }
        }

        guard capsulesOn else { return }
        // Capsules: horizontal (azimuth) spacing among the kept dots; the old
        // per-screen budget scales to the whole circle (~5 screens at 1×).
        var caps: [Int] = []
        for i in sel.dots where caps.allSatisfy({ azDelta(anchorAz[i], anchorAz[$0]) >= angCap }) {
            caps.append(i)
            if caps.count >= knobs.capMax * 5 { break }
        }
        sel.capsules = Set(caps)

        // Stagger stem heights in azimuth order — stable while panning.
        let angTier = Float(132 / pixelsPerRadian)
        var lastAz = [Float](repeating: -.greatestFiniteMagnitude,
                             count: Self.tierLeaderHeights.count)
        for i in caps.sorted(by: { anchorAz[$0] < anchorAz[$1] }) {
            let az = anchorAz[i]
            var tier = -1
            for t in lastAz.indices where az - lastAz[t] >= angTier { tier = t; break }
            if tier < 0 { tier = lastAz.indices.min { lastAz[$0] < lastAz[$1] } ?? 0 }
            lastAz[tier] = az
            sel.tierFor[i] = tier
        }
    }

    /// Project anchors with the current camera basis (the exact vectors the renderer
    /// used this frame) and lay out them. Dots show by default; capsule labels show
    /// only when zoomed in past `labelZoom`, or for the selected peak. Cheap — call
    /// every frame.
    func project(forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                 tanHalfFovY: Float, aspect: Float, zoom: Float) {
        let W = bounds.width, H = bounds.height
        guard W > 1, H > 1 else { hideAll(); return }
        // Still run (to place the search direction marker) even with no visible peaks.
        guard !anchors.isEmpty || target != nil else { hideAll(); return }

        // Device roll about the view axis: the terrain self-levels from the gyro, so
        // when the phone is tilted/held landscape the screen-fixed pills look sideways
        // and float off to the side. Build the gravity-up direction ON SCREEN and (a)
        // rotate each pill by the roll so its TEXT stays upright, (b) offset the pill +
        // draw the stem along gravity-up so it sits ABOVE the summit, not to the side.
        // worldUp=(0,0,1) ⇒ its NDC comps are (right.z, up.z); NDC→UIKit flips y, so the
        // on-screen gravity-up unit is (right.z, -up.z)/‖·‖. Level ⇒ (0,-1) (screen-up).
        let gLen = max(1e-4, hypot(CGFloat(right.z), CGFloat(up.z)))
        let sinRoll = CGFloat(right.z) / gLen, cosRoll = CGFloat(up.z) / gLen
        let gUpX = sinRoll, gUpY = -cosRoll        // gravity-up on screen (UIKit coords)
        let rollT = CATransform3DMakeRotation(atan2(sinRoll, cosRoll), 0, 0, 1)

        // Pixels-per-radian at screen centre (isotropic there:
        // 0.5·W/(aspect·tanHalfFovY) == 0.5·H/tanHalfFovY) — converts the
        // screen-point density knobs into the angular spacings the stable
        // selection uses. Panning doesn't change it, so the set holds still.
        let pxPerRad = 0.5 * H / CGFloat(tanHalfFovY)
        let capsulesOn = zoom >= Self.labelZoom || density == .saved
        if !selectionIsCurrent(pixelsPerRadian: pxPerRad, capsulesOn: capsulesOn) {
            recomputeSelection(pixelsPerRadian: pxPerRad, capsulesOn: capsulesOn)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var shown = Set<Int>()
        var capsuleShownIDs = Set<String>()
        hitTargets.removeAll(keepingCapacity: true)
        for i in selection.dots {
            let a = anchors[i]
            let d = a.direction
            let f = simd_dot(d, forward)
            if f <= 0 { continue }                       // behind the camera
            let r = simd_dot(d, right), u = simd_dot(d, up)
            let ndcX = (r / f) / (aspect * tanHalfFovY)
            let ndcY = (u / f) / tanHalfFovY
            if abs(ndcX) > 1.25 || ndcY < -1.25 || ndcY > 1.7 { continue }
            let point = CGPoint(x: (CGFloat(ndcX) + 1) * 0.5 * W,
                                y: (1 - CGFloat(ndcY)) * 0.5 * H)

            shown.insert(i)
            let node = pool[i]
            let peak = a.peak
            // Saved mode tints by list membership (climbed wins over bookmark).
            let isClimbed = density == .saved && climbedIDs.contains(peak.id)
            let isBookmarked = density == .saved && !isClimbed && bookmarkedIDs.contains(peak.id)
            node.dot.fillColor = isClimbed ? Self.climbedFill
                : isBookmarked ? Self.bookmarkFill
                : a.isWater ? Self.waterFill : Self.peakFill
            node.dot.position = point
            node.dot.isHidden = false

            let selected = peak.id == selectedPeakID
            // Capsule membership comes from the stable set, so it can't change
            // while panning. The SELECTED peak always gets one — but only while
            // its summit is on the true screen; once it leaves, it hands off to
            // the centered direction marker (arrow-to-side) below, instead of
            // leaving a label stuck against the edge with a bent stem.
            var wantsCapsule = selection.capsules.contains(i) || selected
            if selected,
               !(point.x >= 0 && point.x <= W && point.y >= 0 && point.y <= H) {
                wantsCapsule = false
            }
            if wantsCapsule {
                // Pill floats STRAIGHT along GRAVITY-up from the summit (so it stays
                // "above" the peak however the phone is rolled). The leader is a straight
                // stem — we deliberately DON'T clamp the pill's X to the screen, so it
                // never bends to hug an edge.
                let leaderH = Self.tierLeaderHeights[selection.tierFor[i] ?? 0]
                let pcx = point.x + gUpX * leaderH
                let pcy = point.y + gUpY * leaderH
                let path = CGMutablePath()
                path.move(to: CGPoint(x: point.x + gUpX * Self.dotRadius,
                                      y: point.y + gUpY * Self.dotRadius))
                path.addLine(to: CGPoint(x: pcx, y: pcy))
                node.leader.path = path
                node.leader.isHidden = false
                node.capsule.position = CGPoint(x: pcx, y: pcy)
                node.capsule.transform = rollT          // keep text gravity-upright
                node.capsule.isHidden = false
                node.capsule.backgroundColor = selected ? TopoStyle.accent.cgColor : Self.pillBG
                node.nameText.foregroundColor = selected ? TopoStyle.accentText.cgColor
                    : isClimbed ? Self.climbedText
                    : isBookmarked ? Self.bookmarkText
                    : a.isWater ? Self.waterText : UIColor.white.cgColor
                node.elevText.foregroundColor = selected
                    ? TopoStyle.accentText.withAlphaComponent(0.85).cgColor
                    : UIColor.white.withAlphaComponent(0.6).cgColor
                capsuleShownIDs.insert(peak.id)
                hitTargets.append((peak, node.capsule.frame.insetBy(dx: -6, dy: -6), point))
            } else {
                node.leader.isHidden = true
                node.capsule.isHidden = true
                hitTargets.append((peak, .null, point))   // dot is still tappable
            }
        }
        for i in pool.indices where !shown.contains(i) { pool[i].setHidden(true) }

        // Search target: show the accent direction marker only when the selected peak
        // ISN'T already drawn as an on-screen capsule above.
        if let t = target, !capsuleShownIDs.contains(t.id) {
            layoutTarget(t, forward: forward, right: right, up: up,
                         tanHalfFovY: tanHalfFovY, aspect: aspect,
                         roll: rollT, gUpX: gUpX, gUpY: gUpY, W: W, H: H)
        } else {
            hideTarget()
        }
        CATransaction.commit()
    }

    private func hideAll() {
        hitTargets.removeAll(keepingCapacity: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for n in pool { n.setHidden(true) }
        hideTarget()
        CATransaction.commit()
    }

    // MARK: - Search direction marker

    private let targetCapsule = CALayer()
    private let targetText = CATextLayer()
    private let targetDot = CAShapeLayer()
    private let targetLeader = CAShapeLayer()
    /// Off-screen cue: a small, quiet chevron pinned to the physical left/right edge,
    /// pointing the way to turn. No name/distance — just "over there". A faint dark
    /// disc keeps it legible over snow without shouting.
    private let targetArrow = CAShapeLayer()
    private let targetArrowBG = CALayer()
    private static let arrowSize: CGFloat = 24
    private static let arrowMargin: CGFloat = 22

    private func setupTarget() {
        targetCapsule.cornerRadius = Self.capsuleHeight / 2
        targetCapsule.backgroundColor = TopoStyle.accent.cgColor
        targetCapsule.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        targetText.foregroundColor = TopoStyle.accentText.cgColor
        targetText.alignmentMode = .center
        targetText.contentsScale = UIScreen.main.scale
        targetText.font = Self.nameFont
        targetText.fontSize = Self.nameFont.pointSize
        targetCapsule.addSublayer(targetText)
        targetDot.fillColor = TopoStyle.accent.cgColor
        targetDot.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        targetDot.lineWidth = 1.5
        targetDot.path = UIBezierPath(ovalIn: CGRect(x: -4, y: -4, width: 8, height: 8)).cgPath
        targetLeader.strokeColor = TopoStyle.accent.withAlphaComponent(0.85).cgColor
        targetLeader.lineWidth = 1.5
        targetLeader.fillColor = nil

        let a = Self.arrowSize
        targetArrowBG.bounds = CGRect(x: -a / 2, y: -a / 2, width: a, height: a)
        targetArrowBG.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        targetArrowBG.cornerRadius = a / 2
        targetArrowBG.backgroundColor = UIColor.black.withAlphaComponent(0.25).cgColor
        // Chevron pointing +x (screen-right); rotated per-frame toward the peak.
        targetArrow.bounds = CGRect(x: -a / 2, y: -a / 2, width: a, height: a)
        targetArrow.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let chev = CGMutablePath()
        chev.move(to: CGPoint(x: -3, y: -5.5))
        chev.addLine(to: CGPoint(x: 3, y: 0))
        chev.addLine(to: CGPoint(x: -3, y: 5.5))
        targetArrow.path = chev
        targetArrow.fillColor = nil
        targetArrow.strokeColor = TopoStyle.accent.withAlphaComponent(0.8).cgColor
        targetArrow.lineWidth = 2
        targetArrow.lineCap = .round
        targetArrow.lineJoin = .round

        // Above every pooled dot/leader/capsule (which use zPositions 1–3).
        targetLeader.zPosition = 4
        targetDot.zPosition = 4
        targetCapsule.zPosition = 5
        targetArrowBG.zPosition = 5
        targetArrow.zPosition = 6
        layer.addSublayer(targetLeader)
        layer.addSublayer(targetDot)
        layer.addSublayer(targetCapsule)
        layer.addSublayer(targetArrowBG)
        layer.addSublayer(targetArrow)
        hideTarget()
    }

    private func hideTarget() {
        targetCapsule.isHidden = true
        targetDot.isHidden = true
        targetLeader.isHidden = true
        targetArrow.isHidden = true
        targetArrowBG.isHidden = true
    }

    private func setTargetText(_ string: String) {
        targetText.string = string
        let tw = ceil((string as NSString).size(withAttributes: [.font: Self.nameFont]).width)
        targetCapsule.bounds = CGRect(x: 0, y: 0, width: tw + 2 * Self.hPad, height: Self.capsuleHeight)
        targetText.frame = CGRect(x: Self.hPad, y: (Self.capsuleHeight - 18) / 2, width: tw + 1, height: 18)
    }

    /// Place the accent direction marker for `t`: a dot on the horizon in the peak's
    /// direction + a capsule (name · distance), or, when the peak is off to the side or
    /// behind, a chevroned capsule clamped to the nearest screen edge.
    private func layoutTarget(_ t: Target, forward: SIMD3<Float>, right: SIMD3<Float>,
                              up: SIMD3<Float>, tanHalfFovY: Float, aspect: Float,
                              roll: CATransform3D, gUpX: CGFloat, gUpY: CGFloat,
                              W: CGFloat, H: CGFloat) {
        targetCapsule.transform = roll
        let d = t.direction
        let f = simd_dot(d, forward)
        if f > 0 {
            let ndcX = CGFloat((simd_dot(d, right) / f) / (aspect * tanHalfFovY))
            let ndcY = CGFloat((simd_dot(d, up) / f) / tanHalfFovY)
            let px = (ndcX + 1) * 0.5 * W
            let py = (1 - ndcY) * 0.5 * H
            // Gate/clamp in the GRAVITY frame, not raw overlay axes. The overlay
            // lives in the device-portrait frame (counter-rotated with the
            // render), so in landscape its X axis runs VERTICALLY on the
            // physical screen — the old `abs(ndcX) <= 1` gate + Y-only clamp
            // treated a peak off the SIDE of a landscape screen as "on screen"
            // and slid its dot along an edge instead of handing off to the
            // centered chevron. Project the offset from screen centre onto
            // gravity-right/-up and use the window's half-extents along those
            // axes: identical to the old behavior in portrait, correct rolled.
            let gRX = -gUpY, gRY = gUpX                        // gravity-right on screen
            let vx = px - W * 0.5, vy = py - H * 0.5
            let a = vx * gRX + vy * gRY                        // offset along gravity-right
            let b = vx * gUpX + vy * gUpY                      // offset along gravity-up
            let eR = abs(gRX) * W * 0.5 + abs(gRY) * H * 0.5   // visible half-extents
            let eU = abs(gUpX) * W * 0.5 + abs(gUpY) * H * 0.5
            if abs(a) <= eR {
                setTargetText("\(t.name)  ·  \(t.distanceText)")
                let bc = min(max(b, -(eU - 30)), eU - 30)      // pin the dot on screen vertically
                let qx = W * 0.5 + a * gRX + bc * gUpX
                let qy = H * 0.5 + a * gRY + bc * gUpY
                let lift: CGFloat = 34
                let cx = qx + gUpX * lift                      // straight stem, no edge-clamp
                let cy = qy + gUpY * lift
                let path = CGMutablePath()
                path.move(to: CGPoint(x: qx + gUpX * 4, y: qy + gUpY * 4))
                path.addLine(to: CGPoint(x: cx, y: cy))
                targetLeader.path = path
                targetDot.position = CGPoint(x: qx, y: qy)
                targetCapsule.position = CGPoint(x: cx, y: cy)
                targetDot.isHidden = false; targetLeader.isHidden = false; targetCapsule.isHidden = false
                targetArrow.isHidden = true; targetArrowBG.isHidden = true
                return
            }
        }
        // Off screen (to the side or behind): no name/distance — just a chevron pinned
        // to the physical left/right edge, pointing the way to turn.
        //
        // "Left/right" is PHYSICAL, so decide and place in the gravity frame, not the
        // raw camera/overlay axes — otherwise a peak off the side of a LANDSCAPE screen
        // (where the overlay's X runs vertically on the device) gets the wrong edge.
        // Screen gravity-right (UIKit) is (cosRoll, sinRoll) = (-gUpY, gUpX); the world
        // axis that projects onto it is right·cosRoll − up·sinRoll, which stays valid
        // even when the peak is behind the camera.
        let gRX = -gUpY, gRY = gUpX
        let physRightWorld = right * Float(gRX) - up * Float(gRY)
        let toRight = simd_dot(d, physRightWorld) >= 0
        let sign: CGFloat = toRight ? 1 : -1
        // Distance from screen centre to the edge along the (signed) gravity-right axis.
        let ex = abs(gRX) > 1e-4 ? (W * 0.5) / abs(gRX) : .greatestFiniteMagnitude
        let ey = abs(gRY) > 1e-4 ? (H * 0.5) / abs(gRY) : .greatestFiniteMagnitude
        let edge = min(ex, ey) - Self.arrowMargin
        let cx = W * 0.5 + sign * gRX * edge
        let cy = H * 0.5 + sign * gRY * edge
        let angle = atan2(sign * gRY, sign * gRX)      // chevron points toward the peak
        targetArrowBG.position = CGPoint(x: cx, y: cy)
        targetArrow.position = CGPoint(x: cx, y: cy)
        targetArrow.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        targetArrowBG.isHidden = false; targetArrow.isHidden = false
        targetCapsule.isHidden = true; targetDot.isHidden = true; targetLeader.isHidden = true
    }
}
