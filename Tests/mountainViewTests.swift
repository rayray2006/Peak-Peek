import XCTest
@testable import PeakPeek

final class GeoMathTests: XCTestCase {
    // One degree of longitude on the equator: 2πR / 360 with R = 6,371 km.
    func testDistanceOneDegreeAtEquator() {
        let d = GeoMath.distanceMeters(fromLatitude: 0, fromLongitude: 0,
                                       toLatitude: 0, toLongitude: 1)
        XCTAssertEqual(d, 111_195, accuracy: 5)
    }

    func testDistanceEquatorToPole() {
        let d = GeoMath.distanceMeters(fromLatitude: 0, fromLongitude: 0,
                                       toLatitude: 90, toLongitude: 0)
        XCTAssertEqual(d, Double.pi * GeoMath.earthRadiusMeters / 2, accuracy: 5)
    }

    func testBearingCardinalDirections() {
        let north = GeoMath.bearingRad(fromLatitude: 0, fromLongitude: 0,
                                       toLatitude: 1, toLongitude: 0)
        XCTAssertEqual(north, 0, accuracy: 1e-9)
        let east = GeoMath.bearingRad(fromLatitude: 0, fromLongitude: 0,
                                      toLatitude: 0, toLongitude: 1)
        XCTAssertEqual(east, .pi / 2, accuracy: 1e-9)
        let south = GeoMath.bearingRad(fromLatitude: 1, fromLongitude: 0,
                                       toLatitude: 0, toLongitude: 0)
        XCTAssertEqual(south, .pi, accuracy: 1e-9)
    }

    func testDestinationRoundTrip() {
        let start = (lat: 47.6, lon: -122.3)
        let bearing = 1.234
        let dist = 87_000.0
        let end = GeoMath.destination(latitude: start.lat, longitude: start.lon,
                                      bearingRad: bearing, distanceMeters: dist)
        let back = GeoMath.distanceMeters(fromLatitude: start.lat, fromLongitude: start.lon,
                                          toLatitude: end.latitude, toLongitude: end.longitude)
        XCTAssertEqual(back, dist, accuracy: 1)
        let outBearing = GeoMath.bearingRad(fromLatitude: start.lat, fromLongitude: start.lon,
                                            toLatitude: end.latitude, toLongitude: end.longitude)
        XCTAssertEqual(outBearing, bearing, accuracy: 1e-3)
    }

    func testCurvatureDropIncludesRefractionFactor() {
        // 0.87 * d^2 / (2R) at 10 km.
        let drop = GeoMath.curvatureDrop(distanceMeters: 10_000)
        XCTAssertEqual(drop, 0.87 * 1e8 / (2 * 6_371_000), accuracy: 1e-6)
    }

    func testApparentRiseIsHeightDeltaMinusCurvature() {
        let rise = GeoMath.apparentRise(groundMeters: 1500, eyeMeters: 500,
                                        distanceMeters: 10_000, exaggeration: 1)
        XCTAssertEqual(rise, 1000 - GeoMath.curvatureDrop(distanceMeters: 10_000), accuracy: 1e-9)
    }
}

final class EphemerisTests: XCTestCase {
    // 2000-01-01 12:00 UTC is J2000.0 by definition.
    func testJulianDayAtJ2000() {
        let j2000 = Date(timeIntervalSince1970: 946_728_000)
        XCTAssertEqual(Ephemeris.julianDay(j2000), 2_451_545.0, accuracy: 1e-9)
        XCTAssertEqual(Ephemeris.julianDay(Date(timeIntervalSince1970: 0)), 2_440_587.5, accuracy: 1e-9)
    }

    // Sæmundsson: ~0.48° at the true horizon, ~0.02° at 45° altitude.
    func testRefractionMagnitudes() {
        XCTAssertEqual(Ephemeris.refractionDeg(trueAltitudeDeg: 0), 0.48, accuracy: 0.05)
        XCTAssertEqual(Ephemeris.refractionDeg(trueAltitudeDeg: 45), 0.016, accuracy: 0.01)
        XCTAssertLessThan(Ephemeris.refractionDeg(trueAltitudeDeg: 45),
                          Ephemeris.refractionDeg(trueAltitudeDeg: 0))
    }

    // Solar noon near the June solstice at 40°N, 0°E: azimuth due south,
    // elevation ≈ 90° − 40° + 23.44° ≈ 73.4°. 2026-06-21 12:00 UTC.
    func testSunNearSolsticeNoon() {
        let date = Date(timeIntervalSince1970: 1_781_784_000)
        let pos = Ephemeris.sunPosition(date: date, latitude: 40, longitude: 0)
        XCTAssertEqual(pos.azimuthDeg, 180, accuracy: 5)
        XCTAssertEqual(pos.elevationDeg, 73.4, accuracy: 1.0)
    }

    func testSunBelowHorizonAtMidnight() {
        let date = Date(timeIntervalSince1970: 1_781_784_000 - 12 * 3600)
        let pos = Ephemeris.sunPosition(date: date, latitude: 40, longitude: 0)
        XCTAssertLessThan(pos.elevationDeg, -10)
    }

    // The phase epoch (2000-01-06 18:14 UTC) is a real new moon; half a synodic
    // month later the moon is full.
    func testMoonPhaseAnchors() {
        let newMoon = Date(timeIntervalSince1970: 947_182_440)
        XCTAssertEqual(Ephemeris.moonPhase(date: newMoon).illuminatedFraction, 0, accuracy: 1e-6)
        let full = newMoon.addingTimeInterval(29.530588853 * 86_400 / 2)
        XCTAssertEqual(Ephemeris.moonPhase(date: full).illuminatedFraction, 1, accuracy: 1e-6)
        let anyPhase = Ephemeris.moonPhase(date: Date(timeIntervalSince1970: 1_752_000_000))
        XCTAssertTrue((0...1).contains(anyPhase.illuminatedFraction))
        XCTAssertTrue((0..<29.6).contains(anyPhase.ageDays))
    }

    // The documented contract windowPath's callers (and the day-cache) rely on:
    // the arc is anchored to the lap's LOWER CULMINATION, so any two instants
    // within the same lap produce identical samples — and the lap always
    // contains the requested instant.
    func testWindowPathAnchoredToLap() {
        // Longitude 0: the sun's lower culmination sits at ~00:00 UTC, so 01:00
        // and 23:00 UTC of one UTC day share a lap whatever the machine's zone.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let june = Date(timeIntervalSince1970: 1_781_784_000)
        let early = cal.startOfDay(for: june).addingTimeInterval(1 * 3600)
        let late = cal.startOfDay(for: june).addingTimeInterval(23 * 3600)
        let a = Ephemeris.windowPath(of: .sun, centeredOn: early, latitude: 47, longitude: 0)
        let b = Ephemeris.windowPath(of: .sun, centeredOn: late, latitude: 47, longitude: 0)
        XCTAssertEqual(a.samples.count, b.samples.count)
        XCTAssertEqual(a.samples.first?.date, b.samples.first?.date)
        XCTAssertEqual(a.samples.count, 1_440 / 10 + 1)
        XCTAssertTrue(a.covers(early))
        XCTAssertTrue(a.covers(late))
        // Sun elevation range over a mid-latitude day must straddle the horizon.
        let els = a.samples.map(\.position.elevationDeg)
        XCTAssertGreaterThan(els.max() ?? -90, 30)
        XCTAssertLessThan(els.min() ?? 90, -10)
    }

    // Regression: the moon DISC must lie ON its drawn arc at any display
    // instant. The lap used to be anchored to the calendar day; the moon's
    // ~24h50m lap could then end BEFORE an evening `date`, and the disc sat a
    // day of orbital drift off the line after a date-picker change.
    func testMoonWindowPathCoversDateAndDiscSitsOnArc() {
        func shortestDelta(_ a: Double, _ b: Double) -> Double {
            var d = (b - a).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }; if d < -180 { d += 360 }
            return d
        }
        let base = Date(timeIntervalSince1970: 1_781_784_000)
        for day in 0..<6 {
            for hour in [0.0, 5.0, 11.0, 17.0, 22.5] {
                let d = base.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
                let path = Ephemeris.windowPath(of: .moon, centeredOn: d, latitude: 47, longitude: -121)
                XCTAssertTrue(path.covers(d), "lap must contain \(d)")
                let disc = Ephemeris.moonPosition(date: d, latitude: 47, longitude: -121)
                guard let i = path.samples.firstIndex(where: { $0.date >= d }), i > 0 else {
                    XCTAssertEqual(path.samples.first?.position.elevationDeg ?? -99,
                                   disc.elevationDeg, accuracy: 0.2)
                    continue
                }
                let s0 = path.samples[i - 1], s1 = path.samples[i]
                let f = d.timeIntervalSince(s0.date) / s1.date.timeIntervalSince(s0.date)
                let el = s0.position.elevationDeg
                    + f * (s1.position.elevationDeg - s0.position.elevationDeg)
                let az = s0.position.azimuthDeg
                    + f * shortestDelta(s0.position.azimuthDeg, s1.position.azimuthDeg)
                XCTAssertEqual(el, disc.elevationDeg, accuracy: 0.35, "elevation off arc at \(d)")
                XCTAssertEqual(shortestDelta(az, disc.azimuthDeg), 0, accuracy: 0.5,
                               "azimuth off arc at \(d)")
            }
        }
    }
}

@MainActor
final class ARZoomMatchTests: XCTestCase {
    // Entering AR must reproduce the 3D view's magnification: crop = camera's
    // native on-screen tan(½FOV) over the 3D one, clamped to the 1–4x pinch range.
    func testMatchedARZoomReproduces3DMagnification() {
        let cam = tanf(66 * .pi / 360)           // ~a phone camera's vertical FOV
        // 3D at the camera's own FOV → 1x (no crop).
        XCTAssertEqual(TerrainMetalView.Coordinator.matchedARZoom(
            cameraTanHalf1x: cam, tanHalf3D: cam), 1, accuracy: 1e-5)
        // 3D zoomed to a 30° FOV → crop by the exact tan ratio.
        let tan30 = tanf(30 * .pi / 360)
        XCTAssertEqual(TerrainMetalView.Coordinator.matchedARZoom(
            cameraTanHalf1x: cam, tanHalf3D: tan30), cam / tan30, accuracy: 1e-5)
    }

    func testMatchedARZoomClamps() {
        let cam = tanf(66 * .pi / 360)
        // 3D wider than the camera (90°) → can't zoom out past the lens: 1x.
        XCTAssertEqual(TerrainMetalView.Coordinator.matchedARZoom(
            cameraTanHalf1x: cam, tanHalf3D: tanf(90 * .pi / 360)), 1)
        // 3D zoomed way past the crop cap (15°) → 4x.
        XCTAssertEqual(TerrainMetalView.Coordinator.matchedARZoom(
            cameraTanHalf1x: cam, tanHalf3D: tanf(15 * .pi / 360)), 4)
    }

    // The clamp DETECTOR drives the AR-exit restore: a clamped entry showed
    // the lens/crop bound rather than the user's zoom, so exiting must give
    // the original 3D fov back instead of adopting the clamp (the one-time
    // "my zoom permanently became 0.8x after visiting AR" bug).
    func testClampDetectionMatchesTheClampBounds() {
        let cam = tanf(66 * .pi / 360)
        // Within the 1–4x crop range: not clamped (exit keeps adopting).
        XCTAssertFalse(TerrainMetalView.Coordinator.arZoomMatchClamps(
            cameraTanHalf1x: cam, tanHalf3D: cam))
        XCTAssertFalse(TerrainMetalView.Coordinator.arZoomMatchClamps(
            cameraTanHalf1x: cam, tanHalf3D: tanf(30 * .pi / 360)))
        // Wider than the lens, and past the 4x crop: clamped (exit restores).
        XCTAssertTrue(TerrainMetalView.Coordinator.arZoomMatchClamps(
            cameraTanHalf1x: cam, tanHalf3D: tanf(90 * .pi / 360)))
        XCTAssertTrue(TerrainMetalView.Coordinator.arZoomMatchClamps(
            cameraTanHalf1x: cam, tanHalf3D: tanf(15 * .pi / 360)))
    }
}

@MainActor
final class PanoramaViewModelTimeZoneTests: XCTestCase {
    func testApproxTimeZoneRoundsToNearestHour() {
        XCTAssertEqual(PanoramaViewModel.approxTimeZone(longitudeDeg: 0).secondsFromGMT(), 0)
        XCTAssertEqual(PanoramaViewModel.approxTimeZone(longitudeDeg: -122).secondsFromGMT(), -8 * 3600)
        XCTAssertEqual(PanoramaViewModel.approxTimeZone(longitudeDeg: 139.7).secondsFromGMT(), 9 * 3600)
    }

    func testApproxTimeZoneClamps() {
        XCTAssertEqual(PanoramaViewModel.approxTimeZone(longitudeDeg: 179.9).secondsFromGMT(), 12 * 3600)
        XCTAssertEqual(PanoramaViewModel.approxTimeZone(longitudeDeg: -179.9).secondsFromGMT(), -12 * 3600)
    }
}

@MainActor
final class ProgressSmoothingTests: XCTestCase {
    /// The displayed load percent must never move backward within one load.
    /// Regression: the smoother's creep runs a few points past the last real
    /// report, and a subsequent real report landing under the crept value
    /// used to trip the "fresh load" reset and snap the percent back.
    func testShownProgressIsMonotonicWithinALoad() {
        let model = PanoramaViewModel()
        var maxSeen = -1.0
        var wentBackward = false
        func record() {
            let p: Double?
            switch model.status {
            case let .preparingTerrain(progress): p = progress
            case let .rendering(progress): p = progress
            default: p = nil
            }
            guard let p else { return }
            if p + 1e-9 < maxSeen { wentBackward = true }
            maxSeen = max(maxSeen, p)
        }

        model.renderStatusChanged(.preparingTerrain(progress: nil))   // load starts
        model.renderStatusChanged(.preparingTerrain(progress: 0.10))
        record()
        // No fresh reports for a while: the display creeps past the target.
        let creepUntil = Date().addingTimeInterval(1.2)
        while Date() < creepUntil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            record()
        }
        // A real report BELOW the crept display — the old reset fired here.
        model.renderStatusChanged(.preparingTerrain(progress: 0.11))
        record()
        // Normal climb through the phase handoff to the bake.
        for step in stride(from: 0.15, through: 0.9, by: 0.05) {
            model.renderStatusChanged(.rendering(progress: step))
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            record()
        }
        model.renderStatusChanged(.ready)

        XCTAssertFalse(wentBackward, "displayed progress moved backward (max seen \(maxSeen))")
        XCTAssertGreaterThan(maxSeen, 0.5, "progress should have climbed with the reports")
    }
}

@MainActor
final class PeakListStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PeakListStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func peak(_ id: String, name: String = "Test Peak") -> Peak {
        Peak(id: id, name: name, latitude: 47, longitude: -121,
             elevationMeters: 2000, prominenceMeters: 500)
    }

    func testToggleAddsAndRemoves() {
        let store = PeakListStore(defaults: defaults)
        let p = peak("a")
        XCTAssertFalse(store.contains(p, in: .climbed))
        store.toggle(p, in: .climbed)
        XCTAssertTrue(store.contains(p, in: .climbed))
        XCTAssertEqual(store.count(in: .climbed), 1)
        store.toggle(p, in: .climbed)
        XCTAssertFalse(store.contains(p, in: .climbed))
        XCTAssertEqual(store.count(in: .climbed), 0)
    }

    func testListsAreIndependent() {
        let store = PeakListStore(defaults: defaults)
        let p = peak("a")
        store.toggle(p, in: .climbed)
        store.toggle(p, in: .wantToClimb)
        store.remove(p, from: .climbed)
        XCTAssertFalse(store.contains(p, in: .climbed))
        XCTAssertTrue(store.contains(p, in: .wantToClimb))
    }

    func testPersistsAcrossInstances() {
        let first = PeakListStore(defaults: defaults)
        first.toggle(peak("a"), in: .wantToClimb)
        let second = PeakListStore(defaults: defaults)
        XCTAssertTrue(second.contains(peak("a"), in: .wantToClimb))
    }

    func testPeaksSortedNewestFirst() {
        let store = PeakListStore(defaults: defaults)
        store.toggle(peak("older"), in: .climbed)
        store.toggle(peak("newer"), in: .climbed)
        XCTAssertEqual(store.peaks(in: .climbed).map(\.id), ["newer", "older"])
    }
}

final class LinearPeakMergeTests: XCTestCase {
    private func peak(_ id: String, name: String, lat: Double, lon: Double) -> Peak {
        Peak(id: id, name: name, latitude: lat, longitude: lon,
             elevationMeters: 1000, prominenceMeters: nil)
    }

    func testDropsExactIDDuplicates() {
        var merge = OSMPeakService.LinearPeakMerge()
        merge.insert(peak("1", name: "A", lat: 47, lon: -121))
        merge.insert(peak("1", name: "B", lat: 48, lon: -120))
        XCTAssertEqual(merge.peaks.count, 1)
    }

    func testDropsSameNameWithin200m() {
        var merge = OSMPeakService.LinearPeakMerge()
        merge.insert(peak("1", name: "Mount Foo", lat: 47.0, lon: -121.0))
        // ~110 m north — same name, tile-overlap duplicate.
        merge.insert(peak("2", name: "mount foo", lat: 47.001, lon: -121.0))
        XCTAssertEqual(merge.peaks.count, 1)
    }

    func testKeepsSameNameBeyond200m() {
        var merge = OSMPeakService.LinearPeakMerge()
        merge.insert(peak("1", name: "Mount Foo", lat: 47.0, lon: -121.0))
        // ~1.1 km north — a genuinely distinct same-named summit.
        merge.insert(peak("2", name: "Mount Foo", lat: 47.01, lon: -121.0))
        XCTAssertEqual(merge.peaks.count, 2)
    }

    func testKeepsDifferentNamesNearby() {
        var merge = OSMPeakService.LinearPeakMerge()
        merge.insert(peak("1", name: "North Summit", lat: 47.0, lon: -121.0))
        merge.insert(peak("2", name: "South Summit", lat: 47.0005, lon: -121.0))
        XCTAssertEqual(merge.peaks.count, 2)
    }
}

final class RegionBoxTests: XCTestCase {
    private func box(_ s: Double, _ w: Double, _ n: Double, _ e: Double) -> RegionBox {
        RegionBox(south: s, west: w, north: n, east: e)
    }

    private func area(_ boxes: [RegionBox]) -> Double {
        boxes.reduce(0) { $0 + ($1.north - $1.south) * ($1.east - $1.west) }
    }

    func testIntersects() {
        XCTAssertTrue(box(0, 0, 2, 2).intersects(box(1, 1, 3, 3)))
        // Touching edges don't count as overlap (no merge for adjacency).
        XCTAssertFalse(box(0, 0, 1, 1).intersects(box(0, 1, 1, 2)))
        XCTAssertFalse(box(0, 0, 1, 1).intersects(box(5, 5, 6, 6)))
    }

    func testUnionOfDisjointBoxesKeepsBoth() {
        let rects = RegionStore.unionRects([box(0, 0, 1, 1), box(5, 5, 6, 6)])
        XCTAssertEqual(area(rects), 2.0, accuracy: 1e-9)
    }

    func testUnionOfOverlappingBoxesCountsOverlapOnce() {
        // Two 2×2 boxes overlapping in a 1×1 corner: union area = 4+4−1.
        let rects = RegionStore.unionRects([box(0, 0, 2, 2), box(1, 1, 3, 3)])
        XCTAssertEqual(area(rects), 7.0, accuracy: 1e-9)
        // Decomposition must not overlap itself.
        for (i, a) in rects.enumerated() {
            for b in rects.dropFirst(i + 1) {
                XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)")
            }
        }
    }

    func testUnionOfIdenticalBoxesIsOneBox() {
        let rects = RegionStore.unionRects([box(0, 0, 1, 1), box(0, 0, 1, 1)])
        XCTAssertEqual(area(rects), 1.0, accuracy: 1e-9)
    }

    func testUnionCoversEveryInputPoint() {
        let boxes = [box(0, 0, 2, 3), box(1, 2, 4, 5), box(3, 0, 5, 1)]
        let rects = RegionStore.unionRects(boxes)
        // Sample a grid: every point inside any input box must be inside
        // exactly one output rect (interior points, so no edge ambiguity).
        var y = 0.05
        while y < 5 {
            var x = 0.05
            while x < 5 {
                let inInput = boxes.contains { $0.contains(latitude: y, longitude: x) }
                let hits = rects.filter { $0.contains(latitude: y, longitude: x) }.count
                if inInput {
                    XCTAssertGreaterThanOrEqual(hits, 1, "(\(y), \(x)) uncovered")
                } else {
                    XCTAssertEqual(hits, 0, "(\(y), \(x)) covered but shouldn't be")
                }
                x += 0.5
            }
            y += 0.5
        }
    }

    func testOldManifestWithoutBoxesStillDecodes() throws {
        let json = """
        [{"id":"a","name":"Rainier","latitude":46.8,"longitude":-121.7,
          "radiusKm":50,"tileNames":["N46W122"],"byteCount":100,
          "date":700000000}]
        """.data(using: .utf8)!
        let regions = try JSONDecoder().decode([DownloadedRegion].self, from: json)
        XCTAssertEqual(regions.count, 1)
        XCTAssertTrue(regions[0].boxes.isEmpty)   // load() backfills from tiles
    }
}

final class RingPerceptibilityTests: XCTestCase {
    func testRainierScalePassesAnywhereInBand() {
        // ~4 km prominence: perceptible across the whole ring band.
        XCTAssertTrue(FarHorizon.perceptible(
            prominenceMeters: 4023, elevationMeters: 4392, distanceMeters: 200_000))
        XCTAssertTrue(FarHorizon.perceptible(
            prominenceMeters: 4023, elevationMeters: 4392, distanceMeters: 600_000))
    }

    func testSmallHillFailsInBand() {
        XCTAssertFalse(FarHorizon.perceptible(
            prominenceMeters: 300, elevationMeters: 1800, distanceMeters: 200_000))
    }

    func testMidPeakPassesNearBandFailsFar() {
        // ~1 km prominence: a real mountain — reads at 250 km, not at 550 km.
        XCTAssertTrue(FarHorizon.perceptible(
            prominenceMeters: 1000, elevationMeters: 2500, distanceMeters: 250_000))
        XCTAssertFalse(FarHorizon.perceptible(
            prominenceMeters: 1000, elevationMeters: 2500, distanceMeters: 550_000))
    }

    func testVerdictOccludedForImperceptibleRingBandPeak() {
        // In-band, crests nothing, too small to discern at 200 km: the honest
        // practical answer is "you can't see it" — Occluded, not nil (nil now
        // means only no-pass-yet / standing-on-it / never-judged, per
        // visibilityVerdict's contract).
        let v = PanoramaViewModel.visibilityVerdict(
            peakID: "hill", isSaddle: false, elevationMeters: 1800,
            prominenceMeters: 300, isWater: false,
            distanceMeters: 200_000, visibleIDs: [], isCandidate: true)
        XCTAssertEqual(v, false)
    }

    func testVerdictOccludedForPerceptibleRingBandPeak() {
        let v = PanoramaViewModel.visibilityVerdict(
            peakID: "giant", isSaddle: false, elevationMeters: 4392,
            prominenceMeters: 4023, isWater: false,
            distanceMeters: 300_000, visibleIDs: [], isCandidate: true)
        XCTAssertEqual(v, false)
    }

    func testVerdictOccludedBeyondRingReachAnySize() {
        // Past 600 km Earth curvature settles it regardless of size.
        let v = PanoramaViewModel.visibilityVerdict(
            peakID: "far", isSaddle: false, elevationMeters: 1800,
            prominenceMeters: 300, isWater: false,
            distanceMeters: 900_000, visibleIDs: [], isCandidate: false)
        XCTAssertEqual(v, false)
    }
}

@MainActor
final class CancelMoveTests: XCTestCase {
    /// The switching card's ✕: mid-move cancel must stand the model back at
    /// the last scene that actually rendered, bump the renderer's drop token,
    /// and retire the ✕ (nothing further to go back to).
    func testCancelRevertsToThePreviousRenderedScene() {
        let model = PanoramaViewModel()
        let home = PanoramaViewModel.Viewpoint(name: "Home", latitude: 48.5, longitude: -121.0)
        let away = PanoramaViewModel.Viewpoint(name: "Away", latitude: 46.85, longitude: -121.76)
        model.teleport(to: home, manual: true)
        model.renderStatusChanged(.ready)                 // home actually rendered
        XCTAssertFalse(model.canCancelMove)               // nothing in flight yet
        model.teleport(to: away, manual: true)            // move begins
        XCTAssertTrue(model.canCancelMove)
        let token = model.moveCancelToken
        model.cancelLocationChange()
        XCTAssertEqual(model.viewpoint, home)
        XCTAssertEqual(model.moveCancelToken, token + 1)  // renderer told to drop the move
        XCTAssertFalse(model.canCancelMove)
    }

    /// A first-ever load has no previous scene: cancel must be a no-op and
    /// the card must not offer the ✕.
    func testCancelUnavailableOnFirstLoad() {
        let model = PanoramaViewModel()
        let first = PanoramaViewModel.Viewpoint(name: "First", latitude: 47.0, longitude: -122.0)
        model.teleport(to: first, manual: true)
        XCTAssertFalse(model.canCancelMove)
        let token = model.moveCancelToken
        model.cancelLocationChange()
        XCTAssertEqual(model.viewpoint, first)            // unchanged
        XCTAssertEqual(model.moveCancelToken, token)
    }
}

final class LakeClassificationTests: XCTestCase {
    /// The Wing Lake bug: a lake teleported to from beyond the nearby cache's
    /// 160 km reach must still classify as water, via the bundled global lakes
    /// file — `standOnPeak` looks the tapped id up at the tapped coordinate.
    /// This exercises that exact lookup against the real bundled data.
    func testBundledLakesDBResolvesALakeByIdAtItsOwnCoordinate() throws {
        let lakes = try XCTUnwrap(GlobalPeakDatabase.lakes, "bundled lakes_global.bin missing")
        let wing = lakes.search(nameContains: "Wing Lake")
            .first { abs($0.latitude - 48.5) < 0.2 && abs($0.longitude + 120.9) < 0.3 }
        let lake = try XCTUnwrap(wing, "Wing Lake (North Cascades) not in bundled lakes DB")
        let hit = lakes.peaks(nearLatitude: lake.latitude, longitude: lake.longitude,
                              withinMeters: 500).contains { $0.id == lake.id }
        XCTAssertTrue(hit, "cell lookup at the lake's own coordinate must find its id")
    }
}

final class DEMDespikeTests: XCTestCase {

    func testRemovesSpikeAndWell() {
        // The real N47W123 artifacts that rendered as spires from Indian Point:
        // a 4001 m post and a −5802 m well amid ~2 m Puget Sound water.
        let n = 9
        var e = [Float](repeating: 2, count: n * n)
        e[4 * n + 4] = 4001
        e[2 * n + 6] = -5802
        let fixed = DEMFetcher.despike(&e, ncols: n, nrows: n, thresholdMeters: 150)
        XCTAssertEqual(fixed, 2)
        XCTAssertEqual(e[4 * n + 4], 2)
        XCTAssertEqual(e[2 * n + 6], 2)
    }

    func testKeepsSteepRealTerrainAndSharpRidge() {
        // A sharp ridge crest climbing 120 m per 30 m post on both flanks —
        // steeper than any real C-band SRTM relief — must survive untouched:
        // every post has a same-height along-ridge neighbour.
        let n = 9
        var e = [Float](repeating: 0, count: n * n)
        for r in 0..<n {
            for c in 0..<n { e[r * n + c] = Float(min(c, n - 1 - c)) * 120 }
        }
        let before = e
        XCTAssertEqual(DEMFetcher.despike(&e, ncols: n, nrows: n, thresholdMeters: 150), 0)
        XCTAssertEqual(e, before)
    }

    func testIsolatedSummitPostJustUnderThresholdSurvives() {
        // An isolated post 150 m above flat surroundings sits exactly AT the
        // threshold — the filter requires strictly more before it intervenes.
        let n = 5
        var e = [Float](repeating: 100, count: n * n)
        e[2 * n + 2] = 250
        XCTAssertEqual(DEMFetcher.despike(&e, ncols: n, nrows: n, thresholdMeters: 150), 0)
        XCTAssertEqual(e[2 * n + 2], 250)
    }

    func testTinyGridIsLeftAlone() {
        var e: [Float] = [0, 9000, 0, 0, 9000, 0]   // 3x2: no interior posts
        XCTAssertEqual(DEMFetcher.despike(&e, ncols: 3, nrows: 2, thresholdMeters: 150), 0)
    }
}


final class SightlineOcclusionTests: XCTestCase {
    /// Real 30 m SRTM window (N48W121, rows 1742..1786 x cols 763..814) spanning
    /// Lewis Lake and Horsefly Pass in the North Cascades. Ground truth in this
    /// data: a rib ~166 m from the pass rises ~46 m above the straight
    /// sightline, blocking BOTH directions. Exercises the exact CPU march used
    /// for WATER occlusion (and as `-labelWatch`'s second opinion) — peaks and
    /// saddles are judged by the renderer's depth panorama instead, whose
    /// margins deliberately trade cases like Horsefly-from-Lewis for robustness
    /// at summit viewpoints (see the buildAnchors depth branch).
    private static let lewisHorseflyTile = DEMTile(
        ncols: 52, nrows: 45,
        xllcorner: -120.78819444444444, yllcorner: 48.50375,
        cellsize: 1.0 / 3600.0, nodata: -9999,
        elevations: {
            let v: [Float] = [
            1839, 1842, 1844, 1843, 1845, 1847, 1846, 1846, 1846, 1844, 1844, 1849, 1854, 1859, 1865, 1863, 1854, 1842, 1831, 1821, 1812, 1802, 1794, 1783, 1770, 1760, 1749, 1734, 1723, 1712, 1692, 1667, 1649, 1637, 1628, 1619, 1606, 1592, 1582, 1576, 1570, 1561, 1551, 1543, 1534, 1524, 1517, 1511, 1505, 1499, 1494, 1489,
            1828, 1828, 1828, 1828, 1830, 1830, 1829, 1829, 1830, 1827, 1826, 1828, 1830, 1832, 1842, 1848, 1847, 1838, 1826, 1819, 1807, 1800, 1791, 1781, 1770, 1758, 1748, 1732, 1720, 1706, 1687, 1663, 1644, 1631, 1619, 1606, 1594, 1583, 1575, 1566, 1558, 1550, 1541, 1531, 1522, 1515, 1510, 1502, 1496, 1492, 1488, 1483,
            1825, 1824, 1824, 1823, 1822, 1822, 1821, 1820, 1819, 1819, 1817, 1818, 1819, 1818, 1819, 1831, 1837, 1835, 1831, 1823, 1814, 1804, 1796, 1786, 1774, 1759, 1746, 1729, 1714, 1698, 1679, 1657, 1643, 1628, 1613, 1594, 1582, 1576, 1567, 1558, 1549, 1538, 1528, 1522, 1517, 1511, 1505, 1499, 1491, 1486, 1483, 1479,
            1822, 1821, 1820, 1818, 1816, 1815, 1813, 1810, 1808, 1807, 1804, 1803, 1800, 1795, 1796, 1807, 1814, 1819, 1823, 1821, 1816, 1810, 1803, 1795, 1781, 1763, 1747, 1728, 1712, 1691, 1673, 1651, 1635, 1621, 1607, 1591, 1575, 1565, 1557, 1549, 1540, 1530, 1521, 1514, 1510, 1506, 1500, 1492, 1487, 1483, 1479, 1476,
            1820, 1820, 1819, 1817, 1811, 1809, 1806, 1801, 1794, 1791, 1787, 1784, 1783, 1780, 1781, 1785, 1790, 1796, 1801, 1807, 1807, 1806, 1802, 1795, 1784, 1765, 1748, 1728, 1710, 1687, 1657, 1642, 1628, 1615, 1597, 1582, 1569, 1561, 1551, 1541, 1532, 1525, 1516, 1508, 1503, 1499, 1492, 1486, 1483, 1480, 1477, 1471,
            1818, 1818, 1814, 1807, 1802, 1798, 1795, 1787, 1777, 1770, 1766, 1761, 1760, 1759, 1762, 1766, 1771, 1775, 1780, 1785, 1794, 1797, 1795, 1788, 1774, 1762, 1745, 1728, 1706, 1682, 1675, 1656, 1634, 1618, 1600, 1584, 1572, 1559, 1549, 1538, 1525, 1516, 1507, 1501, 1496, 1492, 1487, 1483, 1480, 1477, 1475, 1473,
            1816, 1809, 1801, 1794, 1787, 1775, 1769, 1766, 1759, 1753, 1749, 1746, 1742, 1741, 1741, 1742, 1745, 1746, 1747, 1758, 1767, 1775, 1779, 1775, 1767, 1754, 1741, 1723, 1709, 1715, 1716, 1698, 1658, 1624, 1603, 1586, 1573, 1561, 1551, 1541, 1531, 1522, 1511, 1503, 1496, 1492, 1487, 1487, 1485, 1482, 1479, 1477,
            1816, 1810, 1802, 1793, 1784, 1771, 1762, 1753, 1745, 1741, 1741, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1741, 1741, 1746, 1750, 1752, 1755, 1751, 1741, 1737, 1742, 1746, 1745, 1730, 1695, 1652, 1622, 1599, 1581, 1568, 1556, 1547, 1536, 1524, 1514, 1508, 1503, 1497, 1494, 1493, 1491, 1488, 1485, 1482,
            1816, 1808, 1798, 1786, 1774, 1766, 1761, 1755, 1747, 1740, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1740, 1741, 1742, 1743, 1744, 1745, 1748, 1753, 1758, 1765, 1769, 1754, 1731, 1696, 1653, 1620, 1592, 1574, 1559, 1550, 1540, 1532, 1524, 1514, 1510, 1504, 1502, 1500, 1499, 1495, 1492, 1489,
            1814, 1804, 1798, 1791, 1784, 1770, 1762, 1755, 1745, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1740, 1740, 1741, 1742, 1743, 1744, 1747, 1752, 1758, 1765, 1770, 1772, 1754, 1734, 1704, 1657, 1615, 1583, 1570, 1560, 1551, 1540, 1530, 1524, 1518, 1511, 1512, 1510, 1507, 1505, 1502, 1499,
            1815, 1807, 1802, 1796, 1789, 1778, 1766, 1759, 1745, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1740, 1740, 1741, 1741, 1742, 1743, 1744, 1747, 1754, 1758, 1765, 1769, 1766, 1756, 1732, 1697, 1656, 1624, 1589, 1570, 1559, 1552, 1546, 1538, 1523, 1527, 1526, 1523, 1519, 1514, 1511, 1509,
            1813, 1808, 1800, 1792, 1786, 1776, 1763, 1751, 1741, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1739, 1740, 1740, 1740, 1740, 1741, 1744, 1746, 1748, 1751, 1756, 1760, 1758, 1757, 1755, 1749, 1727, 1692, 1652, 1626, 1596, 1575, 1569, 1560, 1550, 1540, 1541, 1540, 1538, 1534, 1530, 1525, 1525,
            1810, 1807, 1803, 1798, 1791, 1780, 1770, 1764, 1756, 1746, 1742, 1741, 1740, 1740, 1740, 1739, 1739, 1739, 1739, 1739, 1740, 1739, 1738, 1738, 1739, 1740, 1742, 1744, 1745, 1746, 1749, 1750, 1749, 1749, 1746, 1739, 1717, 1694, 1654, 1628, 1599, 1583, 1577, 1569, 1553, 1558, 1556, 1553, 1550, 1549, 1545, 1544,
            1815, 1811, 1807, 1804, 1797, 1789, 1780, 1770, 1764, 1758, 1750, 1744, 1743, 1743, 1742, 1741, 1740, 1740, 1740, 1739, 1738, 1735, 1734, 1735, 1735, 1735, 1735, 1735, 1736, 1738, 1740, 1740, 1740, 1740, 1739, 1736, 1731, 1715, 1696, 1664, 1646, 1623, 1606, 1585, 1575, 1575, 1571, 1567, 1565, 1565, 1566, 1565,
            1826, 1822, 1817, 1813, 1807, 1800, 1791, 1782, 1769, 1758, 1754, 1754, 1750, 1745, 1744, 1743, 1743, 1742, 1742, 1740, 1733, 1731, 1731, 1731, 1732, 1731, 1731, 1730, 1729, 1730, 1731, 1732, 1730, 1730, 1730, 1728, 1726, 1721, 1714, 1701, 1674, 1657, 1634, 1613, 1603, 1596, 1594, 1592, 1586, 1586, 1589, 1591,
            1840, 1837, 1832, 1825, 1817, 1812, 1806, 1793, 1776, 1770, 1768, 1765, 1760, 1754, 1751, 1748, 1747, 1746, 1745, 1744, 1741, 1737, 1732, 1731, 1729, 1728, 1727, 1727, 1726, 1725, 1724, 1723, 1722, 1721, 1721, 1721, 1720, 1718, 1714, 1711, 1704, 1672, 1652, 1635, 1621, 1611, 1614, 1615, 1615, 1619, 1624, 1626,
            1856, 1852, 1845, 1839, 1833, 1824, 1816, 1809, 1789, 1791, 1788, 1783, 1775, 1770, 1764, 1764, 1764, 1762, 1761, 1758, 1754, 1748, 1740, 1735, 1733, 1732, 1732, 1732, 1731, 1730, 1729, 1728, 1727, 1726, 1724, 1721, 1718, 1716, 1712, 1708, 1700, 1691, 1678, 1663, 1643, 1635, 1644, 1647, 1651, 1655, 1658, 1660,
            1867, 1865, 1858, 1851, 1841, 1832, 1822, 1815, 1817, 1814, 1808, 1803, 1795, 1788, 1785, 1784, 1782, 1779, 1777, 1774, 1769, 1760, 1751, 1748, 1745, 1743, 1744, 1744, 1741, 1739, 1737, 1736, 1734, 1733, 1732, 1730, 1727, 1726, 1724, 1722, 1717, 1709, 1699, 1687, 1671, 1665, 1670, 1673, 1678, 1684, 1688, 1688,
            1889, 1883, 1876, 1874, 1866, 1856, 1852, 1845, 1842, 1839, 1836, 1829, 1819, 1813, 1806, 1802, 1799, 1797, 1796, 1793, 1787, 1778, 1776, 1774, 1766, 1766, 1765, 1762, 1758, 1754, 1752, 1749, 1748, 1746, 1743, 1741, 1739, 1737, 1735, 1732, 1727, 1720, 1711, 1700, 1693, 1690, 1695, 1702, 1707, 1711, 1713, 1715,
            1914, 1911, 1906, 1904, 1899, 1895, 1886, 1876, 1871, 1870, 1863, 1850, 1844, 1834, 1825, 1823, 1818, 1817, 1815, 1815, 1813, 1805, 1798, 1793, 1787, 1784, 1782, 1779, 1776, 1773, 1771, 1771, 1771, 1770, 1767, 1763, 1758, 1753, 1746, 1742, 1737, 1732, 1722, 1719, 1713, 1715, 1721, 1723, 1724, 1727, 1731, 1735,
            1938, 1934, 1930, 1927, 1923, 1920, 1909, 1905, 1904, 1896, 1886, 1880, 1867, 1857, 1851, 1848, 1842, 1842, 1837, 1836, 1837, 1833, 1821, 1817, 1810, 1807, 1802, 1798, 1798, 1795, 1789, 1790, 1786, 1784, 1783, 1780, 1777, 1772, 1765, 1757, 1750, 1745, 1740, 1737, 1734, 1736, 1735, 1735, 1737, 1741, 1745, 1751,
            1958, 1957, 1956, 1952, 1943, 1938, 1930, 1928, 1920, 1912, 1908, 1901, 1890, 1884, 1881, 1873, 1873, 1869, 1865, 1863, 1859, 1857, 1850, 1844, 1840, 1837, 1831, 1830, 1828, 1823, 1819, 1817, 1811, 1808, 1806, 1802, 1798, 1791, 1784, 1781, 1776, 1765, 1759, 1756, 1755, 1756, 1753, 1754, 1757, 1760, 1763, 1769,
            1966, 1965, 1963, 1962, 1959, 1956, 1953, 1947, 1940, 1934, 1926, 1914, 1908, 1907, 1902, 1900, 1896, 1894, 1896, 1892, 1891, 1893, 1894, 1894, 1891, 1888, 1886, 1880, 1874, 1871, 1862, 1854, 1844, 1842, 1837, 1828, 1822, 1818, 1813, 1808, 1798, 1784, 1779, 1775, 1776, 1777, 1776, 1776, 1780, 1787, 1793, 1797,
            1985, 1982, 1979, 1975, 1972, 1968, 1965, 1959, 1954, 1950, 1942, 1938, 1932, 1923, 1924, 1922, 1921, 1922, 1926, 1928, 1925, 1937, 1934, 1941, 1937, 1937, 1930, 1933, 1920, 1915, 1902, 1897, 1890, 1884, 1872, 1867, 1864, 1858, 1843, 1835, 1825, 1810, 1800, 1797, 1795, 1799, 1801, 1804, 1814, 1822, 1826, 1830,
            2005, 2003, 2000, 1996, 1991, 1987, 1980, 1972, 1968, 1963, 1959, 1958, 1954, 1949, 1952, 1956, 1959, 1969, 1977, 1982, 1998, 1998, 1990, 2006, 2005, 1999, 1991, 1982, 1976, 1968, 1960, 1949, 1939, 1929, 1909, 1900, 1897, 1887, 1874, 1868, 1851, 1829, 1814, 1818, 1818, 1822, 1826, 1832, 1840, 1857, 1867, 1870,
            2027, 2026, 2021, 2016, 2011, 2008, 2002, 1994, 1991, 1981, 1978, 1972, 1968, 1969, 1978, 1980, 1983, 1991, 2009, 2031, 2052, 2040, 2036, 2050, 2040, 2040, 2030, 2018, 2012, 2001, 1998, 1992, 1987, 1969, 1951, 1935, 1928, 1915, 1902, 1887, 1867, 1849, 1837, 1844, 1849, 1851, 1868, 1879, 1889, 1896, 1901, 1904,
            2044, 2045, 2041, 2031, 2026, 2021, 2015, 2012, 2006, 2003, 1997, 1993, 1991, 1989, 1988, 1995, 2003, 2028, 2060, 2079, 2092, 2086, 2082, 2085, 2077, 2071, 2066, 2057, 2043, 2037, 2033, 2025, 2010, 1992, 1982, 1969, 1955, 1937, 1921, 1905, 1893, 1876, 1874, 1885, 1891, 1896, 1904, 1909, 1908, 1914, 1925, 1929,
            2080, 2082, 2077, 2069, 2057, 2044, 2034, 2029, 2024, 2020, 2017, 2014, 2009, 2004, 2003, 2003, 2013, 2035, 2076, 2106, 2109, 2105, 2101, 2096, 2089, 2082, 2078, 2072, 2066, 2057, 2045, 2031, 2018, 2009, 2000, 1988, 1977, 1968, 1953, 1933, 1911, 1914, 1914, 1929, 1928, 1932, 1933, 1941, 1941, 1944, 1947, 1957,
            2134, 2114, 2096, 2095, 2089, 2078, 2057, 2042, 2039, 2037, 2036, 2033, 2029, 2026, 2023, 2036, 2044, 2070, 2094, 2103, 2116, 2114, 2108, 2100, 2093, 2086, 2079, 2073, 2067, 2060, 2047, 2038, 2027, 2017, 2007, 1999, 1989, 1979, 1965, 1944, 1940, 1948, 1950, 1960, 1963, 1962, 1965, 1969, 1969, 1974, 1978, 1986,
            2174, 2162, 2152, 2135, 2110, 2097, 2085, 2082, 2073, 2075, 2066, 2060, 2061, 2070, 2074, 2088, 2108, 2119, 2125, 2127, 2124, 2119, 2115, 2114, 2100, 2085, 2073, 2060, 2051, 2045, 2039, 2033, 2026, 2017, 2008, 1996, 1985, 1979, 1973, 1968, 1969, 1975, 1979, 1988, 1992, 1996, 2001, 2002, 2002, 2007, 2007, 2009,
            2210, 2193, 2187, 2179, 2170, 2153, 2149, 2143, 2126, 2132, 2123, 2120, 2127, 2130, 2129, 2125, 2121, 2118, 2115, 2112, 2111, 2116, 2116, 2115, 2102, 2088, 2073, 2059, 2047, 2035, 2027, 2021, 2014, 2005, 1996, 1985, 1976, 1970, 1966, 1967, 1969, 1973, 1978, 1987, 1991, 1997, 2003, 2006, 2011, 2016, 2025, 2034,
            2253, 2249, 2241, 2232, 2214, 2208, 2199, 2189, 2186, 2179, 2174, 2164, 2153, 2144, 2137, 2129, 2122, 2115, 2110, 2101, 2094, 2089, 2089, 2086, 2081, 2076, 2067, 2057, 2046, 2037, 2028, 2019, 2009, 1998, 1987, 1976, 1971, 1963, 1961, 1961, 1961, 1960, 1963, 1967, 1976, 1984, 1992, 1999, 2008, 2017, 2022, 2029,
            2286, 2281, 2276, 2271, 2264, 2259, 2252, 2243, 2223, 2206, 2193, 2170, 2160, 2151, 2139, 2123, 2113, 2105, 2100, 2093, 2086, 2080, 2071, 2066, 2060, 2056, 2051, 2044, 2037, 2030, 2025, 2018, 2011, 2001, 1990, 1981, 1973, 1966, 1961, 1956, 1952, 1953, 1950, 1957, 1966, 1976, 1982, 1989, 1994, 2000, 2008, 2013,
            2330, 2323, 2318, 2309, 2305, 2297, 2277, 2255, 2232, 2215, 2199, 2176, 2161, 2145, 2129, 2113, 2103, 2093, 2081, 2074, 2069, 2064, 2058, 2050, 2047, 2043, 2037, 2029, 2023, 2016, 2012, 2008, 2001, 1995, 1989, 1980, 1973, 1967, 1961, 1956, 1954, 1947, 1943, 1948, 1953, 1957, 1962, 1970, 1976, 1978, 1981, 1988,
            2379, 2373, 2359, 2344, 2322, 2299, 2281, 2262, 2237, 2216, 2199, 2175, 2151, 2131, 2116, 2104, 2092, 2081, 2072, 2063, 2054, 2048, 2044, 2039, 2037, 2035, 2030, 2023, 2014, 2002, 1995, 1989, 1985, 1982, 1977, 1970, 1963, 1960, 1956, 1953, 1944, 1939, 1932, 1932, 1937, 1936, 1939, 1946, 1950, 1954, 1958, 1962,
            2404, 2384, 2363, 2331, 2303, 2283, 2270, 2254, 2233, 2216, 2194, 2167, 2137, 2119, 2110, 2102, 2091, 2078, 2068, 2059, 2049, 2041, 2035, 2031, 2025, 2019, 2015, 2011, 2002, 1995, 1988, 1979, 1965, 1953, 1950, 1946, 1942, 1939, 1935, 1930, 1927, 1924, 1918, 1913, 1912, 1910, 1917, 1925, 1928, 1929, 1935, 1940,
            2396, 2369, 2342, 2318, 2298, 2282, 2264, 2240, 2215, 2187, 2165, 2148, 2131, 2117, 2109, 2097, 2088, 2079, 2069, 2059, 2049, 2040, 2028, 2021, 2016, 2009, 1998, 1990, 1984, 1974, 1967, 1959, 1950, 1935, 1925, 1918, 1911, 1904, 1902, 1897, 1890, 1883, 1886, 1893, 1894, 1888, 1893, 1895, 1898, 1903, 1909, 1918,
            2404, 2371, 2348, 2319, 2294, 2272, 2246, 2227, 2200, 2175, 2157, 2135, 2123, 2115, 2107, 2096, 2083, 2073, 2063, 2053, 2045, 2036, 2026, 2018, 2006, 1994, 1988, 1977, 1969, 1959, 1944, 1936, 1928, 1919, 1907, 1896, 1891, 1880, 1873, 1869, 1866, 1865, 1863, 1866, 1870, 1872, 1872, 1873, 1877, 1880, 1891, 1897,
            2398, 2370, 2349, 2323, 2301, 2274, 2242, 2216, 2191, 2170, 2147, 2134, 2123, 2115, 2106, 2097, 2085, 2073, 2062, 2051, 2039, 2028, 2018, 2007, 1997, 1987, 1974, 1964, 1953, 1941, 1931, 1920, 1911, 1904, 1893, 1880, 1871, 1864, 1854, 1853, 1853, 1852, 1851, 1851, 1854, 1857, 1859, 1860, 1860, 1865, 1876, 1879,
            2397, 2374, 2352, 2330, 2306, 2280, 2251, 2224, 2197, 2175, 2147, 2131, 2122, 2115, 2106, 2094, 2079, 2069, 2058, 2049, 2040, 2030, 2019, 2005, 1988, 1976, 1964, 1956, 1946, 1930, 1917, 1908, 1898, 1883, 1875, 1866, 1858, 1851, 1846, 1841, 1841, 1842, 1842, 1841, 1839, 1843, 1846, 1847, 1850, 1854, 1859, 1869,
            2397, 2374, 2354, 2333, 2310, 2287, 2266, 2241, 2209, 2190, 2168, 2141, 2126, 2117, 2106, 2095, 2083, 2071, 2060, 2048, 2034, 2021, 2007, 1994, 1982, 1969, 1958, 1947, 1932, 1919, 1908, 1899, 1892, 1877, 1865, 1856, 1850, 1845, 1839, 1833, 1831, 1832, 1832, 1831, 1828, 1831, 1834, 1834, 1836, 1842, 1851, 1858,
            2418, 2382, 2364, 2348, 2328, 2306, 2280, 2255, 2232, 2211, 2191, 2171, 2139, 2125, 2112, 2097, 2081, 2069, 2056, 2045, 2034, 2026, 2016, 1998, 1979, 1956, 1947, 1937, 1928, 1915, 1904, 1893, 1877, 1867, 1858, 1851, 1841, 1837, 1832, 1827, 1823, 1823, 1823, 1822, 1819, 1820, 1823, 1823, 1826, 1832, 1831, 1838,
            2441, 2397, 2368, 2358, 2345, 2322, 2300, 2279, 2257, 2234, 2217, 2199, 2169, 2137, 2117, 2102, 2088, 2075, 2063, 2052, 2041, 2032, 2024, 2004, 1982, 1962, 1948, 1928, 1911, 1908, 1901, 1887, 1872, 1861, 1851, 1842, 1836, 1828, 1821, 1818, 1815, 1815, 1815, 1814, 1813, 1814, 1816, 1814, 1814, 1817, 1831, 1844,
            2428, 2395, 2366, 2334, 2329, 2327, 2316, 2298, 2278, 2258, 2240, 2218, 2195, 2165, 2136, 2120, 2105, 2081, 2067, 2055, 2045, 2038, 2028, 2013, 1991, 1969, 1951, 1934, 1915, 1898, 1884, 1874, 1857, 1852, 1846, 1839, 1830, 1823, 1817, 1813, 1810, 1807, 1808, 1807, 1805, 1807, 1808, 1803, 1806, 1815, 1828, 1843,
            2411, 2417, 2368, 2333, 2302, 2286, 2282, 2279, 2278, 2267, 2250, 2223, 2198, 2173, 2153, 2135, 2112, 2095, 2081, 2066, 2055, 2044, 2031, 2020, 1999, 1976, 1957, 1938, 1915, 1900, 1887, 1873, 1862, 1850, 1840, 1831, 1822, 1812, 1810, 1808, 1805, 1802, 1801, 1799, 1798, 1798, 1797, 1794, 1800, 1807, 1818, 1829
            ]
            return v
        }(), maxElevation: 2441)

    private static let lewisLake = (lat: 48.5133938, lon: -120.7841313)
    private static let horseflyPass = (lat: 48.50802, lon: -120.77748)
    private static let curvatureK = (1 - GeoMath.refractionCoefficient)
        / (2 * GeoMath.earthRadiusMeters)

    /// Mirrors buildAnchors' inputs: eye on the DEM surface + lift, feature at
    /// its DEM elevation, curvature-dropped apparent height.
    private func marchOccluded(from eye: (lat: Double, lon: Double),
                               to feat: (lat: Double, lon: Double),
                               eyeLift: Double = 1.6) -> Bool {
        let tile = Self.lewisHorseflyTile
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(eye.lat * .pi / 180)
        let horiz = hypot((feat.lon - eye.lon) * mLon, (feat.lat - eye.lat) * mLat)
        let camElev = Double(tile.elevation(lat: eye.lat, lon: eye.lon)) + eyeLift
        let apparentUp = Double(tile.elevation(lat: feat.lat, lon: feat.lon))
            - Self.curvatureK * horiz * horiz - camElev
        return TerrainMetalView.Coordinator.waterSightlineOccluded(
            eyeLat: eye.lat, eyeLon: eye.lon, featLat: feat.lat, featLon: feat.lon,
            horiz: horiz, apparentUp: apparentUp, camElevMeters: camElev,
            heightScale: 1, curvatureK: Self.curvatureK,
            dem: tile, far: nil)
    }

    func testHorseflyPassHiddenFromLewisLake() {
        // The old saddle margin (250 m floor) let the occluding rib vouch for
        // the pass; the march must call it what the terrain says: hidden.
        XCTAssertTrue(marchOccluded(from: Self.lewisLake, to: Self.horseflyPass))
    }

    func testVerdictIsSymmetric() {
        // Same line, same rib: blocked from the pass side too.
        XCTAssertTrue(marchOccluded(from: Self.horseflyPass, to: Self.lewisLake))
    }

    func testClearSightlineStaysVisible() {
        // 70 m above the pass the line clears the rib -- the march must not
        // blanket-occlude everything downhill.
        XCTAssertFalse(marchOccluded(from: Self.horseflyPass, to: Self.lewisLake,
                                     eyeLift: 70))
    }
}
