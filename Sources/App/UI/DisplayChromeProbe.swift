import SwiftUI
import UIKit

/// What the system reserves along this display's edges — nothing on a classic
/// iPhone, but the iPhone Duo's outer screen runs its status bar down a
/// vertical bar on the trailing edge (84 pt, camera cutout inside it; top
/// inset 0) and the system treats that strip as a safe-area inset. With the
/// status bar hidden the strip is dead space, so the HUD spans it and parks
/// the ☰ inside it (RootScreen) — the Duo's own "bar items on the side" idiom.
///
/// Measured on hardware (iOS 27.3): closed 466×678 (compact/regular), bar
/// trailing in portrait and on the camera side in landscape (leading in one
/// rotation, trailing in the other); open 951×669 / 669×951, regular/regular,
/// NO bar and no top inset. The device reports no reserved camera region, so
/// the rail's fallback offsets are what actually ship.
struct DisplayChrome: Equatable {
    enum BarEdge { case none, leading, trailing }
    var barEdge: BarEdge = .none
    /// The bar's safe-area inset (0 without a bar).
    var barWidth: CGFloat = 0
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var windowSize: CGSize = .zero
    var isPortrait = true
    /// Window-space bottom edge of the camera cutout sitting at the TOP of the
    /// bar strip (nil when the system reports no reserved region there).
    var barOcclusionBottom: CGFloat?
    /// Window-space top edge of a camera cutout sitting at the BOTTOM of the
    /// bar strip (nil when none is reported there).
    var barOcclusionTop: CGFloat?
    /// The closed phone is held upside down but the interface stayed in
    /// portrait: iOS never rotates a compact (outer-screen) window to
    /// upside-down, even with the orientation declared, so the terrain —
    /// which follows the IMU — is already upright while the chrome is not.
    /// When set, every edge/inset above is already MIRRORED for a layout that
    /// RootScreen then turns 180° (bar on the leading edge, home-indicator
    /// inset on top), landing where the system's own flip would have put it.
    var isBodyFlipped = false

    var hasBar: Bool { barEdge != .none && barWidth > 0 }

    /// Too short for the full action menu to clear the mini-map row (the
    /// Duo's outer screen is 678 pt tall in portrait and 466 in landscape;
    /// its inner screen is 669 tall in landscape): the menu scrolls and the
    /// mini-map yields while it's open, as phone landscape already does.
    var isShort: Bool { windowSize.height > 0 && windowSize.height < 720 }

    /// Leading padding that keeps the top-left capsules out of a LEADING bar
    /// strip (and off the camera cutout at its top). Not when the chrome is
    /// turned around on the closed phone: the strip's end under those
    /// capsules is empty there, and the cards and footer span the strip, so
    /// the capsules line up flush with them like everywhere else.
    var topLeftInset: CGFloat {
        hasBar && barEdge == .leading && !isBodyFlipped ? max(0, barWidth - 20) : 0
    }

    /// The safe-area edge the chrome stops honouring so it spans the bar.
    /// Gated on a real inset: the unfolded Duo's inner screen keeps reporting
    /// a "trailing" edge trait with no bar at all (inset 0).
    var ignoredEdges: Edge.Set {
        guard hasBar else { return [] }
        switch barEdge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .none: return []
        }
    }

    /// Trailing padding that keeps the bottom-trailing mini-map out of a
    /// TRAILING bar strip whose camera sits at the bottom: the closed Duo
    /// turned curve-down (landscape, bar trailing) puts the cutout in the
    /// bottom-right corner, right where the mini-map goes. A reported
    /// cutout there decides it; without one (the phone reports none) the
    /// landscape-trailing posture is assumed to be that one.
    var bottomTrailingInset: CGFloat {
        guard hasBar, barEdge == .trailing else { return 0 }
        guard barOcclusionTop != nil || !isPortrait else { return 0 }
        return max(0, barWidth - 20)
    }

    /// The rail (☰) sits inside the strip only when there's a trailing bar.
    var railInBar: Bool { hasBar && barEdge == .trailing }

    /// Trailing padding that centres a `glyph`-wide button inside the bar.
    func railInset(glyph: CGFloat) -> CGFloat { max(0, (barWidth - glyph) / 2) }

    /// Top padding for the action rail: the classic 24 (centres ☰ on the compass
    /// track), pushed down past the camera when the rail lives in the bar.
    var railTopPadding: CGFloat {
        guard railInBar else { return 24 }
        if let bottom = barOcclusionBottom { return max(24, bottom - safeTop + 12) }
        // No reserved region reported (the Simulator's mask has no cutout, so
        // it reports none): in portrait the Duo's camera sits at the top of the
        // strip (~30–70 pt), so start below it; in landscape it's at the bottom.
        return isPortrait ? 84 : 24
    }
}

/// Zero-size-footprint probe (a `.background`) that reads the vertical-bar
/// edge trait, the window's safe-area insets and the reserved (occluded)
/// regions, and publishes them whenever they change — rotation, fold, RTL.
struct DisplayChromeProbe: UIViewRepresentable {
    @Binding var chrome: DisplayChrome

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { chrome = $0 }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = { chrome = $0 }
    }

    final class ProbeView: UIView {
        var onChange: ((DisplayChrome) -> Void)?
        private var last: DisplayChrome?
        /// Device orientation once it has SETTLED (half a second after the
        /// last change): long enough for an interface rotation that is going
        /// to follow (open Duo, home-button phones) to have landed first, so a
        /// body flip is only ever reported when the interface really stayed.
        private var settledDeviceOrientation: UIDeviceOrientation = .unknown
        private var settleTimer: DispatchWorkItem?
        #if DEBUG
        /// Debug-only hinge readout (closed / partially open / fully open).
        private var hingeProbe: AnyObject?
        #endif

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            if #available(iOS 27.1, *) {
                registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
                    (view: ProbeView, _: UITraitCollection) in view.setNeedsLayout()
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
            settleTimer?.cancel()
            if window != nil {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                NotificationCenter.default.addObserver(
                    self, selector: #selector(deviceOrientationChanged),
                    name: UIDevice.orientationDidChangeNotification, object: nil)
                settledDeviceOrientation = UIDevice.current.orientation
                #if DEBUG
                startSnapshotsIfRequested()
                #endif
            }
            setNeedsLayout()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            settleTimer?.cancel()
        }

        #if DEBUG
        /// `-snapshots`: every 1.5 s save the window's UIKit/SwiftUI layers
        /// (Metal content stays black) to Documents/snap-{flipped,normal}.png
        /// so the chrome's state on a physical device can be pulled with
        /// `devicectl device copy from --domain-type appDataContainer`.
        private var snapshotTimer: Timer?
        private func startSnapshotsIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains("-snapshots"), snapshotTimer == nil else { return }
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self, let window = self.window else { return }
                let img = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let name = (self.last?.isBodyFlipped ?? false) ? "snap-flipped.png" : "snap-normal.png"
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? img.pngData()?.write(to: docs.appendingPathComponent(name))
            }
        }
        #endif

        @objc private func deviceOrientationChanged() {
            #if DEBUG
            NSLog("PPGEO device orientation %d (interface %d)", UIDevice.current.orientation.rawValue,
                  window?.windowScene?.interfaceOrientation.rawValue ?? -1)
            #endif
            settleTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settledDeviceOrientation = UIDevice.current.orientation
                self.setNeedsLayout()
                self.followBodyIfStranded()
            }
            settleTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let chrome = measure()
            guard chrome != last else { return }
            #if DEBUG
            NSLog("PPGEO chrome edge=\(chrome.barEdge) flipped=\(chrome.isBodyFlipped) width=\(chrome.barWidth) safeTop=\(chrome.safeTop) safeBottom=\(chrome.safeBottom) window=\(chrome.windowSize) orient=\(window?.windowScene?.interfaceOrientation.rawValue ?? -1) winSafe=\(window?.safeAreaInsets ?? .zero) h=\(traitCollection.horizontalSizeClass.rawValue) v=\(traitCollection.verticalSizeClass.rawValue) portrait=\(chrome.isPortrait) occlusionBottom=\(String(describing: chrome.barOcclusionBottom))")
            if #available(iOS 27.1, *), hingeProbe == nil {
                let probe = UIHingeInteraction { _, update in
                    if let hinge = update.hinge {
                        NSLog("PPGEO hinge status=\(hinge.status.rawValue) angle=\(hinge.angle)")
                    } else {
                        NSLog("PPGEO hinge unavailable")
                    }
                }
                addInteraction(probe)
                hingeProbe = probe
            }
            #endif
            // Off the layout pass: SwiftUI state must not change mid-layout.
            // A body flip re-lays the whole chrome out upside down: run it
            // through the rotation fade (out before the new layout, dissolve
            // back once it has rendered) like a real interface rotation.
            let flipChanged = chrome.isBodyFlipped != (last?.isBodyFlipped ?? false)
            last = chrome
            DispatchQueue.main.async { [weak self] in
                if flipChanged {
                    NotificationCenter.default.post(name: TerrainRotationSnap.willRotate, object: nil)
                }
                self?.onChange?(chrome)
                if flipChanged {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NotificationCenter.default.post(name: TerrainRotationSnap.didRotate, object: nil)
                    }
                }
            }
        }

        private func measure() -> DisplayChrome {
            let chrome = measureWindow()
            return isBodyFlipped ? mirrored(chrome) : chrome
        }

        private func measureWindow() -> DisplayChrome {
            var chrome = DisplayChrome()
            guard let window else { return chrome }
            let insets = window.safeAreaInsets
            chrome.safeTop = insets.top
            chrome.safeBottom = insets.bottom
            chrome.windowSize = window.bounds.size
            chrome.isPortrait = window.bounds.height >= window.bounds.width
            if #available(iOS 27.1, *) {
                let rtl = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
                switch traitCollection.verticalBarEdge {
                case .leading:
                    chrome.barEdge = .leading
                    chrome.barWidth = rtl ? insets.right : insets.left
                case .trailing:
                    chrome.barEdge = .trailing
                    chrome.barWidth = rtl ? insets.left : insets.right
                default:
                    break
                }
                guard chrome.hasBar else { return chrome }
                let bounds = window.bounds
                let onLeft = (chrome.barEdge == .leading) != rtl
                let strip = CGRect(x: onLeft ? 0 : bounds.width - chrome.barWidth, y: 0,
                                   width: chrome.barWidth, height: bounds.height)
                let occlusions = window.reservedRegions(kind: .occlusion)
                    .filter { $0.isActive && $0.frame.intersects(strip) }
                chrome.barOcclusionBottom = occlusions
                    .filter { $0.frame.minY < bounds.height / 2 }
                    .map(\.frame.maxY)
                    .max()
                chrome.barOcclusionTop = occlusions
                    .filter { $0.frame.minY >= bounds.height / 2 }
                    .map(\.frame.minY)
                    .min()
                #if DEBUG
                let all = window.reservedRegions(kind: .occlusion).map { "occl \($0.frame) active=\($0.isActive)" }
                    + window.reservedRegions(kind: .division).map { "div \($0.frame) active=\($0.isActive)" }
                NSLog("PPGEO reserved regions (\(all.count)): \(all.joined(separator: "; "))")
                #endif
            }
            return chrome
        }

        /// The closed phone turned straight from landscape into the upside-down
        /// posture: iOS leaves a compact window in landscape (upside-down is
        /// never granted), so the chrome would sit a quarter turn off the
        /// body for good. Ask for portrait — a size-changing rotation the
        /// snap already handles — and the flipped layout takes over from
        /// there; the next quarter turn auto-rotates to landscape as usual.
        private func followBodyIfStranded() {
            guard let window, !window.isInnerFoldDisplay, let scene = window.windowScene,
                  settledDeviceOrientation == .portraitUpsideDown,
                  scene.interfaceOrientation.isLandscape else { return }
            #if DEBUG
            NSLog("PPGEO body upside down, window landscape: requesting portrait")
            #endif
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                #if DEBUG
                NSLog("PPGEO portrait request failed: \(error)")
                #endif
            }
        }

        /// The closed phone held upside down with the interface left in
        /// portrait (see `DisplayChrome.isBodyFlipped`). Never on the inner
        /// panel, which iOS does rotate to upside-down. Both the settled and
        /// the live device orientation must agree: coming back upright from a
        /// landscape the body had entered upside down, the window turns to
        /// portrait while the settled value is still "upside down".
        private var isBodyFlipped: Bool {
            #if DEBUG
            // `-bodyFlipped`: force the turned-around layout (the Simulator
            // can't report an upside-down device).
            if ProcessInfo.processInfo.arguments.contains("-bodyFlipped") { return true }
            #endif
            guard let window, !window.isInnerFoldDisplay else { return false }
            return settledDeviceOrientation == .portraitUpsideDown
                && UIDevice.current.orientation == .portraitUpsideDown
                && window.windowScene?.interfaceOrientation == .portrait
        }

        /// The same geometry seen from the turned-around chrome: the bar
        /// strip ends up on the other horizontal edge and the vertical insets
        /// swap (the home indicator is now at the chrome's top). The camera
        /// cutout moves to the bottom of the strip, where no rail lives.
        private func mirrored(_ chrome: DisplayChrome) -> DisplayChrome {
            var m = chrome
            m.isBodyFlipped = true
            swap(&m.safeTop, &m.safeBottom)
            switch chrome.barEdge {
            case .leading: m.barEdge = .trailing
            case .trailing: m.barEdge = .leading
            case .none: break
            }
            m.barOcclusionBottom = nil
            m.barOcclusionTop = nil
            return m
        }
    }
}

extension UIWindow {
    /// The window sits on a foldable's unfolded inner panel: a phone-idiom
    /// screen whose SHORT side is still tablet-wide (Duo inner 669×951 vs.
    /// outer 466×678; an iPad in compatibility mode stays phone-sized).
    var isInnerFoldDisplay: Bool {
        guard traitCollection.userInterfaceIdiom == .phone else { return false }
        return min(screen.bounds.width, screen.bounds.height) >= 600
    }
}
