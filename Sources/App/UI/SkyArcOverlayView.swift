import UIKit
import simd

/// Sun and moon day-path arcs + discs over the live terrain, with rise/set time
/// tags at the points where each body crosses the visible ridge skyline. Arc
/// segments (and the discs) below the terrain horizon are hidden, so the lines
/// disappear behind the mountains. Visibility + crossings are precomputed per
/// viewpoint (against a DEM horizon profile); `project(...)` runs each frame with
/// the renderer's exact basis.
final class SkyArcOverlayView: UIView {

    struct Sample {
        let dir: SIMD3<Float>   // ENU direction to this sky point
        let visible: Bool       // above the terrain horizon at its azimuth
    }
    struct Disc {
        let dir: SIMD3<Float>
        let visible: Bool
    }
    struct Tag {
        let dir: SIMD3<Float>   // direction to the ridge-crossing point
        let text: String        // e.g. "↑ 6:32 AM"
        let color: UIColor
    }
    struct StarSample {
        let dir: SIMD3<Float>   // ENU direction to the star
        let visible: Bool       // above the terrain horizon at its azimuth
        let magnitude: Double   // brightness (lower = brighter = bigger dot)
        let colorIndex: Int     // 0…4, matches `starBucketColors`
    }
    /// A tappable, labelled sky object (star / planet / sun / moon). `magnitude`
    /// breaks ties when several objects are within tap range — the eye-catching
    /// bright one wins over a faint neighbor that happens to be nearer the finger.
    struct NamedObject {
        let name: String
        let dir: SIMD3<Float>
        let magnitude: Double
    }

    var sunSamples: [Sample] = []
    var moonSamples: [Sample] = []
    var sunDisc: Disc?
    var moonDisc: Disc?
    var tags: [Tag] = [] { didSet { rebuildTagLayers() } }
    /// Stars (white, brightness-tiered, unnamed) + planets (coloured, sized, named)
    /// + the day→night fade (0 = day, hidden; 1 = full night).
    var stars: [StarSample] = []
    var planets: [StarSample] = []
    var nightOpacity: Float = 0
    /// Tappable named objects (bright stars + planets + moon) for the name tag.
    var namedObjects: [NamedObject] = []
    /// Moon phase: illuminated fraction (0 new … 1 full) + waxing (lit limb on the
    /// right) vs waning (left) — drives the disc shape.
    var moonIlluminated: CGFloat = 1
    var moonWaxing: Bool = true
    /// Name tag currently shown (set by a tap; nil = none). Hiding on change stops
    /// the tag flashing the PREVIOUS star's name at the new position for a frame
    /// (the string/position update happens in the next `project(...)` pass).
    var selectedSkyName: String? {
        didSet { if selectedSkyName != oldValue { skyTagLayer.isHidden = true } }
    }

    private let sunArc = CAShapeLayer()
    private let moonArc = CAShapeLayer()
    private let sunDiscLayer = CAShapeLayer()
    private let moonDiscLayer = CAShapeLayer()    // unlit (earthshine) base disc
    private let moonLitLayer = CAShapeLayer()      // illuminated portion (phase shape)
    private let skyTagLayer = CATextLayer()        // tapped object's name tag
    private static let moonRadius: CGFloat = 9     // visible enough to read the phase
    /// Screen positions of named objects from the last `project(...)`, for hit-testing.
    private var namedScreen: [(name: String, point: CGPoint, magnitude: Double)] = []
    private var tagLayers: [CATextLayer] = []
    /// Stars are drawn as white points split into brightness TIERS — each tier is one
    /// layer with its own alpha + dot radius, so faint stars are small & dim and the
    /// few bright ones stand out (realistic, like real magnitudes). Planets get their
    /// own coloured layers (one per `CelestialSky.StarColor`), sized by magnitude.
    private let starTierLayers: [CAShapeLayer]
    private let planetLayers: [CAShapeLayer]
    private let starGlowLayer = CAShapeLayer()    // soft halos on the brightest objects
    /// (max magnitude, dot radius pt, alpha) per tier — faint → small + dim.
    private static let starTiers: [(maxMag: Double, radius: CGFloat, alpha: Float)] = [
        (1.0, 2.1, 1.00),
        (2.2, 1.4, 0.78),
        (3.5, 0.95, 0.50),
        (99.0, 0.6, 0.30),
    ]
    private static let starColor = UIColor(white: 0.96, alpha: 1)
    private static let planetColors: [UIColor] = [
        UIColor(red: 0.72, green: 0.82, blue: 1.00, alpha: 1),
        UIColor(red: 0.95, green: 0.97, blue: 1.00, alpha: 1),
        UIColor(red: 1.00, green: 0.92, blue: 0.72, alpha: 1),
        UIColor(red: 1.00, green: 0.72, blue: 0.44, alpha: 1),
        UIColor(red: 1.00, green: 0.50, blue: 0.38, alpha: 1),
    ]

    /// ENU direction (az clockwise from north, el up) — matches the shader's ray.
    static func enu(azimuthDeg: Double, elevationDeg: Double) -> SIMD3<Float> {
        let az = azimuthDeg * .pi / 180, el = elevationDeg * .pi / 180
        let ce = cos(el)
        return SIMD3<Float>(Float(sin(az) * ce), Float(cos(az) * ce), Float(sin(el)))
    }

    override init(frame: CGRect) {
        starTierLayers = Self.starTiers.map { _ in CAShapeLayer() }
        planetLayers = Self.planetColors.map { _ in CAShapeLayer() }
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Stars go at the BACK (behind the sun/moon arcs/discs): glow, then cores.
        starGlowLayer.fillColor = UIColor.white.cgColor
        starGlowLayer.strokeColor = nil
        starGlowLayer.shadowColor = UIColor.white.cgColor
        starGlowLayer.shadowRadius = 2.0
        starGlowLayer.shadowOpacity = 0.55
        starGlowLayer.shadowOffset = .zero
        starGlowLayer.opacity = 0
        layer.addSublayer(starGlowLayer)

        for s in starTierLayers {
            s.fillColor = Self.starColor.cgColor
            s.strokeColor = nil
            s.opacity = 0
            layer.addSublayer(s)
        }
        for (i, p) in planetLayers.enumerated() {
            p.fillColor = Self.planetColors[i].cgColor
            p.strokeColor = nil
            p.opacity = 0
            layer.addSublayer(p)
        }

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

        let sunR: CGFloat = 5
        sunDiscLayer.path = CGPath(ellipseIn: CGRect(x: -sunR, y: -sunR, width: 2 * sunR, height: 2 * sunR), transform: nil)
        sunDiscLayer.fillColor = UIColor(red: 0.95, green: 0.73, blue: 0.10, alpha: 1).cgColor
        sunDiscLayer.shadowColor = sunDiscLayer.fillColor
        sunDiscLayer.shadowOpacity = 0.8
        sunDiscLayer.shadowRadius = 8
        sunDiscLayer.shadowOffset = .zero

        // Moon = a dark (earthshine) base disc with the illuminated phase shape on top.
        let mR = Self.moonRadius
        moonDiscLayer.path = CGPath(ellipseIn: CGRect(x: -mR, y: -mR, width: 2 * mR, height: 2 * mR), transform: nil)
        moonDiscLayer.fillColor = UIColor(white: 0.17, alpha: 1).cgColor
        moonDiscLayer.strokeColor = UIColor(white: 0.32, alpha: 1).cgColor
        moonDiscLayer.lineWidth = 0.5
        moonLitLayer.fillColor = UIColor(white: 0.94, alpha: 1).cgColor
        moonLitLayer.shadowColor = UIColor(white: 0.96, alpha: 1).cgColor
        moonLitLayer.shadowRadius = 2.5
        moonLitLayer.shadowOpacity = 0.45
        moonLitLayer.shadowOffset = .zero
        for d in [sunDiscLayer, moonDiscLayer, moonLitLayer] { d.isHidden = true; layer.addSublayer(d) }

        // Tapped-object name tag: bare text (no box), kept legible over the sky
        // with a soft dark shadow.
        skyTagLayer.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        skyTagLayer.fontSize = 11
        skyTagLayer.alignmentMode = .center
        skyTagLayer.contentsScale = UIScreen.main.scale
        skyTagLayer.foregroundColor = UIColor.white.cgColor
        skyTagLayer.shadowColor = UIColor.black.cgColor
        skyTagLayer.shadowOpacity = 0.9
        skyTagLayer.shadowRadius = 2
        skyTagLayer.shadowOffset = .zero
        skyTagLayer.bounds = CGRect(x: 0, y: 0, width: 100, height: 18)
        skyTagLayer.isHidden = true
        layer.addSublayer(skyTagLayer)
    }

    /// The lit-region path for a moon of radius R, illuminated fraction k (0…1),
    /// waxing (lit limb on +x/right) or waning (−x/left). Centred at the origin; the
    /// terminator is an elliptical arc (bulge `R(1−2k)`), the lit limb a semicircle.
    private static func moonLitPath(radius R: CGFloat, illuminated k: CGFloat, waxing: Bool) -> CGPath {
        let p = CGMutablePath()
        let s: CGFloat = waxing ? 1 : -1
        let kp: CGFloat = 0.5522847498
        let lb = s * R                       // lit-limb bulge (semicircle)
        let tb = s * R * (1 - 2 * k)         // terminator bulge
        p.move(to: CGPoint(x: 0, y: -R))
        // Lit limb, top → bottom (a semicircle on the lit side).
        p.addCurve(to: CGPoint(x: lb, y: 0),
                   control1: CGPoint(x: lb * kp, y: -R), control2: CGPoint(x: lb, y: -R * kp))
        p.addCurve(to: CGPoint(x: 0, y: R),
                   control1: CGPoint(x: lb, y: R * kp), control2: CGPoint(x: lb * kp, y: R))
        // Terminator, bottom → top.
        p.addCurve(to: CGPoint(x: tb, y: 0),
                   control1: CGPoint(x: tb * kp, y: R), control2: CGPoint(x: tb, y: R * kp))
        p.addCurve(to: CGPoint(x: 0, y: -R),
                   control1: CGPoint(x: tb, y: -R * kp), control2: CGPoint(x: tb * kp, y: -R))
        p.closeSubpath()
        return p
    }

    /// The best tappable sky object within ~22 pt of `point`, if any. Scored by
    /// distance minus a brightness bonus (≤12 pt), so with the full ~2.9k-star
    /// catalog a tap near Vega picks Vega, not the faint neighbor a point closer —
    /// while isolated faint stars stay tappable.
    func skyObjectName(at point: CGPoint) -> String? {
        var best: (name: String, score: CGFloat)?
        for o in namedScreen {
            let d = hypot(o.point.x - point.x, o.point.y - point.y)
            guard d < 22 else { continue }
            let score = d - min(12, max(0, CGFloat(6 - o.magnitude) * 2))
            if score < (best?.score ?? .greatestFiniteMagnitude) { best = (o.name, score) }
        }
        return best?.name
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func rebuildTagLayers() {
        while tagLayers.count < tags.count {
            let t = CATextLayer()
            t.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
            t.fontSize = 10
            t.alignmentMode = .center
            t.contentsScale = UIScreen.main.scale
            t.bounds = CGRect(x: 0, y: 0, width: 86, height: 13)
            t.isHidden = true
            layer.addSublayer(t)
            tagLayers.append(t)
        }
        for (i, tag) in tags.enumerated() {
            tagLayers[i].string = tag.text
            tagLayers[i].foregroundColor = tag.color.cgColor
        }
        for i in tags.count..<tagLayers.count { tagLayers[i].isHidden = true }
    }

    func project(forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                 tanHalfFovY: Float, aspect: Float) {
        let W = bounds.width, H = bounds.height
        guard W > 1, H > 1 else { return }

        func screen(_ d: SIMD3<Float>) -> CGPoint? {
            let f = simd_dot(d, forward)
            if f <= 0.1 { return nil }
            let r = simd_dot(d, right), u = simd_dot(d, up)
            let ndcX = (r / f) / (aspect * tanHalfFovY)
            let ndcY = (u / f) / tanHalfFovY
            return CGPoint(x: (CGFloat(ndcX) + 1) * 0.5 * W, y: (1 - CGFloat(ndcY)) * 0.5 * H)
        }

        func polyline(_ samples: [Sample]) -> CGPath {
            let path = CGMutablePath()
            var penDown = false
            for s in samples {
                if s.visible, let p = screen(s.dir) {
                    if penDown { path.addLine(to: p) } else { path.move(to: p); penDown = true }
                } else {
                    penDown = false   // hidden behind terrain or off to the side
                }
            }
            return path
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Stars (behind the arcs), faded in/out with night.
        if nightOpacity > 0.001 {
            let glowPath = CGMutablePath()
            // Stars: white points split into brightness tiers (faint = small + dim).
            let starPaths = Self.starTiers.map { _ in CGMutablePath() }
            for st in stars where st.visible {
                if simd_dot(st.dir, forward) <= 0.05 { continue }   // behind the camera
                guard let p = screen(st.dir) else { continue }
                let tier = Self.starTierIndex(st.magnitude)
                let r = Self.starTiers[tier].radius
                // Cull off-screen so the procedural fill (thousands of stars) only
                // builds paths for the stars actually in frame.
                if p.x < -r || p.x > W + r || p.y < -r || p.y > H + r { continue }
                starPaths[tier].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                if st.magnitude < 1.0 {                          // brightest stars: soft halo
                    let g = r + 1.4
                    glowPath.addEllipse(in: CGRect(x: p.x - g, y: p.y - g, width: 2 * g, height: 2 * g))
                }
            }
            for (i, l) in starTierLayers.enumerated() {
                l.path = starPaths[i]
                l.opacity = nightOpacity * Self.starTiers[i].alpha
            }
            // Planets: coloured, sized by magnitude (Venus/Jupiter biggest), brighter.
            let planetPaths = planetLayers.map { _ in CGMutablePath() }
            for pl in planets where pl.visible {
                if simd_dot(pl.dir, forward) <= 0.05 { continue }
                guard let p = screen(pl.dir) else { continue }
                let r = Self.starRadius(pl.magnitude)
                if p.x < -r || p.x > W + r || p.y < -r || p.y > H + r { continue }
                planetPaths[pl.colorIndex].addEllipse(
                    in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                if pl.magnitude < 0.6 {
                    let g = r + 1.4
                    glowPath.addEllipse(in: CGRect(x: p.x - g, y: p.y - g, width: 2 * g, height: 2 * g))
                }
            }
            for (i, l) in planetLayers.enumerated() { l.path = planetPaths[i]; l.opacity = nightOpacity * 0.95 }
            starGlowLayer.path = glowPath
            starGlowLayer.opacity = nightOpacity * 0.5
        } else {
            starGlowLayer.opacity = 0
            for l in starTierLayers { l.opacity = 0 }
            for l in planetLayers { l.opacity = 0 }
        }

        // Gravity-up on screen + the roll counter-rotation. The terrain self-levels
        // from the gyro, so screen-fixed sky marks must be counter-rolled to stay
        // fixed to the WORLD (upright relative to the horizon) instead of spinning
        // with the phone. worldUp=(0,0,1) ⇒ NDC comps (right.z, up.z); NDC→UIKit
        // flips y ⇒ on-screen gravity-up unit = (right.z, -up.z)/‖·‖ (level ⇒ (0,-1)).
        let gLen = max(1e-4, hypot(CGFloat(right.z), CGFloat(up.z)))
        let gUpX = CGFloat(right.z) / gLen, gUpY = -CGFloat(up.z) / gLen
        let rollT = CATransform3DMakeRotation(CGFloat(atan2(right.z, up.z)), 0, 0, 1)

        sunArc.path = polyline(sunSamples)
        moonArc.path = polyline(moonSamples)
        positionDisc(sunDiscLayer, disc: sunDisc, screen: screen)

        // Moon: dark base disc + the illuminated phase shape on top. The crescent's
        // lit limb is fixed to the sky, so counter-roll it (like the tags) — otherwise
        // it rotates with the phone and the crescent tips sideways in landscape.
        if let md = moonDisc, md.visible, let p = screen(md.dir) {
            moonLitLayer.path = Self.moonLitPath(radius: Self.moonRadius,
                                                 illuminated: max(0, min(1, moonIlluminated)),
                                                 waxing: moonWaxing)
            moonDiscLayer.position = p
            moonLitLayer.position = p
            moonLitLayer.transform = rollT
            moonDiscLayer.isHidden = false
            moonLitLayer.isHidden = moonIlluminated < 0.02   // new moon → no lit part
        } else {
            moonDiscLayer.isHidden = true
            moonLitLayer.isHidden = true
        }

        // Rise/set time tags, with a stacking pass: when the sun and moon rise at
        // nearby azimuths their tags land on the same spot — step later tags along
        // gravity-up until they clear the ones already placed.
        var placedTagRects: [CGRect] = []
        for (i, layer) in tagLayers.enumerated() {
            if i < tags.count, let p = screen(tags[i].dir) {
                var pos = CGPoint(x: p.x + gUpX * 11, y: p.y + gUpY * 11)
                let sz = layer.bounds.size
                func frame(at c: CGPoint) -> CGRect {
                    // The text is centered in an 86 pt layer; test a tighter box so
                    // side-by-side tags don't trigger on empty padding.
                    CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2,
                           width: sz.width, height: sz.height).insetBy(dx: 14, dy: 0)
                }
                var steps = 0
                while steps < 4, placedTagRects.contains(where: { $0.intersects(frame(at: pos)) }) {
                    pos.x += gUpX * 15
                    pos.y += gUpY * 15
                    steps += 1
                }
                placedTagRects.append(frame(at: pos))
                layer.position = pos
                layer.transform = rollT
                layer.isHidden = false
            } else {
                layer.isHidden = true
            }
        }

        // Record named-object screen positions (for taps) + show the selected tag.
        namedScreen.removeAll(keepingCapacity: true)
        for o in namedObjects {
            if simd_dot(o.dir, forward) <= 0.05 { continue }
            guard let p = screen(o.dir) else { continue }
            if p.x < -24 || p.x > W + 24 || p.y < -24 || p.y > H + 24 { continue }
            namedScreen.append((o.name, p, o.magnitude))
        }
        if let name = selectedSkyName, let hit = namedScreen.first(where: { $0.name == name }) {
            skyTagLayer.string = name
            skyTagLayer.bounds.size.width = max(40, CGFloat(name.count) * 7 + 18)
            skyTagLayer.position = CGPoint(x: hit.point.x + gUpX * 20, y: hit.point.y + gUpY * 20)
            skyTagLayer.transform = rollT
            skyTagLayer.isHidden = false
        } else {
            skyTagLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private func positionDisc(_ layer: CAShapeLayer, disc: Disc?, screen: (SIMD3<Float>) -> CGPoint?) {
        if let disc, disc.visible, let p = screen(disc.dir) {
            layer.position = p
            layer.isHidden = false
        } else {
            layer.isHidden = true
        }
    }

    /// Brightness tier for a star of the given magnitude (faint → higher index).
    private static func starTierIndex(_ magnitude: Double) -> Int {
        for (i, t) in starTiers.enumerated() where magnitude < t.maxMag { return i }
        return starTiers.count - 1
    }

    /// Dot radius (points) for a PLANET of the given magnitude — brighter (lower
    /// magnitude) renders larger; Venus/Jupiter cap out biggest.
    private static func starRadius(_ magnitude: Double) -> CGFloat {
        CGFloat(max(0.8, min(2.8, 2.0 - 0.28 * magnitude)))
    }
}
