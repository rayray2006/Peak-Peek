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

    func testVerdictNilForImperceptibleRingBandPeak() {
        // In-band, crests nothing, too small to judge: no badge (nil), not
        // a false "Occluded".
        let v = PanoramaViewModel.visibilityVerdict(
            peakID: "hill", isSaddle: false, elevationMeters: 1800,
            prominenceMeters: 300, isWater: false,
            distanceMeters: 200_000, visibleIDs: [], isCandidate: true)
        XCTAssertNil(v)
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
