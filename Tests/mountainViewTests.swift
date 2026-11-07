import XCTest
import Combine
import Compression
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

    // Regression hunt for "moon arc sometimes missing": at mid-latitudes the
    // moon crests well above the sea horizon on EVERY lap (max altitude ≥
    // 90° − 48.8° − 28.7° ≈ 12.5° even at extreme southern declination), so a
    // lap whose samples never clear the horizon means the anchor scan picked
    // the wrong culmination and sampled a misplaced window. Two lunar months,
    // four times a day, at the app's home latitude.
    func testMoonLapAlwaysCrestsAboveHorizonOverTwoMonths() {
        let base = Date(timeIntervalSince1970: 1_786_000_000)          // Aug 2026
        for day in 0..<60 {
            for hour in [2.0, 9.0, 15.0, 21.0] {
                let d = base.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
                let path = Ephemeris.windowPath(
                    of: .moon, centeredOn: d, latitude: 48.83, longitude: -121.27)
                XCTAssertTrue(path.covers(d), "lap must contain \(d)")
                let els = path.samples.map(\.position.elevationDeg)
                XCTAssertGreaterThan(els.max() ?? -90, 5,
                                     "moon lap never clears the horizon at \(d)")
                XCTAssertLessThan(els.min() ?? 90, -5,
                                  "lap not anchored at a lower culmination at \(d)")
            }
        }
    }
}

// (The AR magnification-matching crop and its tests are gone: AR is locked to
// the camera's native 1x so the overlay projects through one exact pinhole —
// see TerrainMetalView.setMode.)

@MainActor
final class SaddleNameHeuristicTests: XCTestCase {
    private func peak(_ name: String) -> Peak {
        Peak(id: name, name: name, latitude: 0, longitude: 0,
             elevationMeters: 1000, prominenceMeters: nil)
    }

    func testSaddleWordsMatchWholeWordsOnly() {
        XCTAssertTrue(peak("Easy Pass").nameSuggestsSaddle)
        XCTAssertTrue(peak("Last Chance Pass").nameSuggestsSaddle)
        XCTAssertTrue(peak("Dip Top Gap").nameSuggestsSaddle)
        XCTAssertTrue(peak("Col du Galibier").nameSuggestsSaddle)
        XCTAssertFalse(peak("Compass Rose").nameSuggestsSaddle)
    }

    func testSummitWordDefeatsAttributiveSaddleWord() {
        // The peak BESIDE the pass, not a pass: the explicit summit word wins.
        XCTAssertFalse(peak("Heather Pass Peak").nameSuggestsSaddle)
        XCTAssertFalse(peak("Pass Mountain").nameSuggestsSaddle)
        XCTAssertFalse(peak("Gap Point").nameSuggestsSaddle)
    }
}

@MainActor
final class ARYawAnchorMathTests: XCTestCase {
    // The stable-anchor gate and the divergence watchdog both run on circular
    // statistics — the wrap cases are exactly where naive means break.
    func testWrappedAngle() {
        XCTAssertEqual(ARAttitudeTracker.wrappedAngle(0), 0)
        // ±π are the same angle; float rounding at the exact boundary may
        // yield either sign — only the magnitude is contractual.
        XCTAssertEqual(abs(ARAttitudeTracker.wrappedAngle(3 * .pi)), .pi, accuracy: 1e-5)
        XCTAssertEqual(abs(ARAttitudeTracker.wrappedAngle(-3 * .pi)), .pi, accuracy: 1e-5)
        XCTAssertEqual(ARAttitudeTracker.wrappedAngle(0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(ARAttitudeTracker.wrappedAngle(-0.5), -0.5, accuracy: 1e-6)
    }

    func testCircularMeanHandlesNorthWrap() {
        // Headings straddling north: +179° and −179° average to ±180°, not 0°.
        let d = Float.pi / 180
        let mean = ARAttitudeTracker.circularMean([179 * d, -179 * d])
        XCTAssertEqual(abs(mean), .pi, accuracy: 1e-4)
        // And a plain cluster averages normally.
        XCTAssertEqual(ARAttitudeTracker.circularMean([10 * d, 20 * d]),
                       15 * d, accuracy: 1e-4)
    }

    func testCircularSpreadAcrossWrap() {
        let d = Float.pi / 180
        let xs: [Float] = [178 * d, -178 * d]     // 4° apart across the wrap
        let mean = ARAttitudeTracker.circularMean(xs)
        XCTAssertEqual(ARAttitudeTracker.circularSpread(xs, about: mean),
                       2 * d, accuracy: 1e-4)
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
        // Normal climb through the phase handoff to the bake. The display
        // sweep is RATE-CAPPED (≈18 pts/s — surges read as jumps), so give
        // the runloop time to actually sweep up to the reported targets
        // before asserting how far it climbed.
        for step in stride(from: 0.15, through: 0.9, by: 0.05) {
            model.renderStatusChanged(.rendering(progress: step))
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            record()
        }
        let settleUntil = Date().addingTimeInterval(2.5)
        while Date() < settleUntil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            record()
        }
        model.renderStatusChanged(.ready)

        XCTAssertFalse(wentBackward, "displayed progress moved backward (max seen \(maxSeen))")
        XCTAssertGreaterThan(maxSeen, 0.5, "progress should have climbed with the reports")
    }

    func testReadyRunsTheBarToTheEndBeforeLifting() {
        let model = PanoramaViewModel()
        // Pin a MANUAL viewpoint: the test host runs with live CLLocation, and
        // a stray fix/authorization callback mid-test teleports the model —
        // which (correctly) resets the very smoothing run this test drives.
        // Manual mode gates all of those.
        model.teleport(to: .init(name: "Test", latitude: 47, longitude: -121),
                       manual: true)
        var published: [Double] = []
        var readyAfterFullBar = false
        let sink = model.$status.sink { st in
            if case let .rendering(p) = st { published.append(p) }
            if case .ready = st, published.max() ?? 0 >= 0.999 { readyAfterFullBar = true }
        }
        defer { sink.cancel() }

        // No runloop spin between these: the test-host app's live location
        // callbacks can teleport the model mid-spin, which (correctly) resets
        // the load's smoothing and would break the sequence under test.
        model.renderStatusChanged(.preparingTerrain(progress: nil))   // load starts
        model.renderStatusChanged(.rendering(progress: 0.4))
        // The load completes while the rate-capped display is far behind: the
        // bar must sweep visibly to 100% and only then settle at .ready —
        // never vanish mid-flight.
        model.renderStatusChanged(.ready)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if case .ready = model.status { break }
        }
        XCTAssertTrue(readyAfterFullBar,
                      "expected the bar to reach 100% before .ready (max published \(published.max() ?? 0))")
        for (a, b) in zip(published, published.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b + 1e-9, "finish sweep moved backward")
        }
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

final class GeoNamesShadowDedupTests: XCTestCase {
    // Real records from peaks_global.bin: the main Kangchenjunga summit exists
    // THREE times within 60 m — OSM's canonical node plus two GeoNames
    // spellings — and no name comparison can see through the scripts. The
    // shadow filter must collapse them by source + proximity while leaving
    // the genuinely distinct sub-summits (832 m+ away) untouched.
    private let osmMain = Peak(id: "osm-4462458037", name: "Kangchenjunga",
                               latitude: 27.70301, longitude: 88.14748,
                               elevationMeters: 8586, prominenceMeters: 3922)
    private let gnMacron = Peak(id: "gn-1283259", name: "Kānchenjunga",
                                latitude: 27.70314, longitude: 88.14739,
                                elevationMeters: 8586, prominenceMeters: nil)
    private let gnNepali = Peak(id: "gn-12249834", name: "Kañchanjaṅghā",
                                latitude: 27.70268, longitude: 88.14744,
                                elevationMeters: 8505, prominenceMeters: nil)
    private let osmYalung = Peak(id: "osm-11867698454", name: "Yalung Kang",
                                 latitude: 27.70517, longitude: 88.13778,
                                 elevationMeters: 8505, prominenceMeters: 135)
    private let osmCentral = Peak(id: "osm-12151324351", name: "Kangchenjunga Central",
                                  latitude: 27.69634, longitude: 88.15083,
                                  elevationMeters: 8473, prominenceMeters: nil)
    private let osmSouth = Peak(id: "osm-12151324350", name: "Kangchenjunga South",
                                latitude: 27.69228, longitude: 88.15401,
                                elevationMeters: 8476, prominenceMeters: nil)
    private let gnSouth = Peak(id: "gn-12249835", name: "Kañchanjaṅghā South",
                               latitude: 27.69048, longitude: 88.15464,
                               elevationMeters: 8393, prominenceMeters: nil)

    func testCollapsesMultilingualTrioToTheOSMRecord() {
        let out = Peak.dedupedKeepingFirst([osmMain, gnMacron, gnNepali])
        XCTAssertEqual(out.map(\.id), ["osm-4462458037"])
    }

    func testShadowBeyondTheSameNameRadiusStillCollapses() {
        // The South pair is 210 m apart — past the 200 m same-name radius, and
        // differently spelled anyway. Only the source rule can catch it.
        let out = Peak.dedupedKeepingFirst([osmSouth, gnSouth])
        XCTAssertEqual(out.map(\.id), ["osm-12151324350"])
    }

    func testOSMWinsRegardlessOfArrivalOrder() {
        let out = Peak.dedupedKeepingFirst([gnMacron, gnNepali, osmMain])
        XCTAssertEqual(out.map(\.id), ["osm-4462458037"])
    }

    func testDistinctSubSummitsAllSurvive() {
        let out = Peak.dedupedKeepingFirst(
            [osmMain, gnMacron, gnNepali, osmYalung, osmCentral, osmSouth, gnSouth])
        XCTAssertEqual(out.map(\.id),
                       ["osm-4462458037", "osm-11867698454",
                        "osm-12151324351", "osm-12151324350"])
    }

    func testGeoNamesSaddleBesideOSMPeakIsNotAShadow() {
        let gap = Peak(id: "gn-777", name: "North Col",
                       latitude: 27.70330, longitude: 88.14760,
                       elevationMeters: 8100, prominenceMeters: nil, isSaddle: true)
        let out = Peak.dedupedKeepingFirst([osmMain, gap])
        XCTAssertEqual(out.count, 2)
    }

    func testGeoNamesOnlyPeakSurvivesWithoutANearbyOSMRecord() {
        let lone = Peak(id: "gn-42", name: "Cerro Solo",
                        latitude: -49.1, longitude: -73.0,
                        elevationMeters: 2121, prominenceMeters: nil)
        XCTAssertEqual(Peak.dedupedKeepingFirst([osmMain, lone]).count, 2)
    }

    func testDroppedShadowDonatesElevationToAnElevationlessOSMRecord() {
        let bare = Peak(id: "osm-99", name: "Gimmigela Chuli",
                        latitude: 27.74000, longitude: 88.15900,
                        elevationMeters: 0, prominenceMeters: nil)
        let gn = Peak(id: "gn-88", name: "गिम्मीगेला चुली",
                      latitude: 27.74010, longitude: 88.15910,
                      elevationMeters: 7350, prominenceMeters: nil)
        let out = Peak.dedupedKeepingFirst([bare, gn])
        XCTAssertEqual(out.map(\.id), ["osm-99"])
        XCTAssertEqual(out[0].elevationMeters, 7350)
    }

    func testShadowAcrossACellEdgeIsStillSeen() {
        // ~22 m apart but straddling a ~550 m grid-cell boundary (the cell
        // edge sits at lat 45.9975: ·200 = 9199.48 vs 9199.52 round to
        // different cells) — the 3×3 neighbour scan must catch it.
        let osm = Peak(id: "osm-5", name: "Grenzgipfel",
                       latitude: 45.99740, longitude: 7.87700,
                       elevationMeters: 4618, prominenceMeters: nil)
        let gn = Peak(id: "gn-6", name: "Пик Гренц",
                      latitude: 45.99760, longitude: 7.87700,
                      elevationMeters: 4618, prominenceMeters: nil)
        XCTAssertEqual(Peak.dedupedKeepingFirst([osm, gn]).map(\.id), ["osm-5"])
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

    /// ✕ during the move's BAKE phase (renderer reporting `.rendering`): the
    /// revert-teleport must NOT re-capture the abandoned target as the scene
    /// to go back to — it never reached the screen. Doing so kept the ✕ alive
    /// pointing at the dead move, so the card never lifted and every further
    /// tap ping-ponged full reloads (fetch + bake pile-up → jetsam crash).
    func testCancelDuringBakeRetiresTheXAndStaysReverted() {
        let model = PanoramaViewModel()
        let home = PanoramaViewModel.Viewpoint(name: "Home", latitude: 48.5, longitude: -121.0)
        let away = PanoramaViewModel.Viewpoint(name: "Away", latitude: 46.85, longitude: -121.76)
        model.teleport(to: home, manual: true)
        model.renderStatusChanged(.ready)                 // home actually rendered
        model.teleport(to: away, manual: true)            // move begins
        model.renderStatusChanged(.rendering(progress: 0.5))  // bake phase, away NOT on screen
        model.cancelLocationChange()
        XCTAssertEqual(model.viewpoint, home)
        XCTAssertFalse(model.canCancelMove)               // away must not become "last good"
        let token = model.moveCancelToken
        model.cancelLocationChange()                      // a straggler tap on a stale ✕
        XCTAssertEqual(model.viewpoint, home)             // no ping-pong back into the move
        XCTAssertEqual(model.moveCancelToken, token)      // and no renderer churn
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

@MainActor
final class StandOnPeakTests: XCTestCase {
    private func annotated(_ p: Peak) -> AnnotatedPeak {
        AnnotatedPeak(peak: p, azimuthDeg: 0, elevationAngleDeg: 0, distanceMeters: 1000)
    }

    /// A peak visit must carry the peak's IDENTITY and catalog height to the
    /// renderer: the height is what the eye's apex match agrees against (so the
    /// eye and the peak's own dot pick the same DEM cell), and the id is what
    /// suppresses that dot once you're standing there.
    func testStandingOnAPeakCarriesItsIDAndHeight() {
        let model = PanoramaViewModel()
        let k2 = Peak(id: "n:12345", name: "K2", latitude: 35.8825, longitude: 76.5133,
                      elevationMeters: 8611, prominenceMeters: 4020)
        model.standOnPeak(annotated(k2))
        XCTAssertEqual(model.viewpoint?.summitTarget,
                       PanoramaViewModel.SummitTarget(peakID: "n:12345",
                                                      elevationMeters: 8611))
    }

    /// A saddle is a LOW point: no target, so nothing snaps uphill onto the
    /// neighboring summit and nothing is suppressed.
    func testStandingOnASaddleCarriesNoTarget() {
        let model = PanoramaViewModel()
        let gap = Peak(id: "n:999", name: "Easy Pass", latitude: 48.6, longitude: -120.6,
                       elevationMeters: 1900, prominenceMeters: nil, isSaddle: true)
        model.standOnPeak(annotated(gap))
        XCTAssertNil(model.viewpoint?.summitTarget)
    }

    /// The map pin marks where the eye ACTUALLY stands: the renderer reports
    /// the (possibly summit-snapped) coordinate via eyeLanded, and a new
    /// teleport clears it until the new eye lands — so the pin can never show
    /// the previous mountain's apex on the next one.
    func testEyeLandedDrivesThePinAndClearsOnTeleport() {
        let model = PanoramaViewModel()
        let peak = Peak(id: "n:12345", name: "K2", latitude: 35.8825, longitude: 76.5133,
                        elevationMeters: 8611, prominenceMeters: 4020)
        model.standOnPeak(annotated(peak))
        XCTAssertNil(model.standingEyeCoordinate)   // nothing landed yet
        model.eyeLanded(latitude: 35.8830, longitude: 76.5140)   // snapped apex
        XCTAssertEqual(model.standingEyeCoordinate?.latitude, 35.8830)
        XCTAssertEqual(model.standingEyeCoordinate?.longitude, 76.5140)
        model.teleport(to: PanoramaViewModel.Viewpoint(
            name: "Elsewhere", latitude: 47.0, longitude: -121.0), manual: true)
        XCTAssertNil(model.standingEyeCoordinate)   // stale for the new eye
    }

    /// The target survives the last-viewpoint round trip, so reopening the app
    /// stands you back on the apex — not on the catalog point.
    func testSummitTargetSurvivesTheLastViewpointRoundTrip() throws {
        let model = PanoramaViewModel()
        let peak = Peak(id: "n:777", name: "Sahale Peak", latitude: 48.48, longitude: -121.06,
                        elevationMeters: 2621, prominenceMeters: 300)
        model.standOnPeak(annotated(peak))
        let reopened = try XCTUnwrap(PanoramaViewModel.loadSavedViewpoint())
        XCTAssertEqual(reopened.viewpoint.summitTarget?.peakID, "n:777")
        XCTAssertEqual(reopened.viewpoint.summitTarget?.elevationMeters, 2621)
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

final class DEMSanitizeTests: XCTestCase {
    // The Florida corruption (N28W081, the marsh corridor east of Orlando):
    // ~20k Int16-SATURATED posts (+32767 m) in runs up to 39 long and 2-D
    // blobs. Neighbour-consensus despiking can't heal a run's interior —
    // adjacent saturated posts protect each other exactly like a real ridge —
    // which is how the far tier rendered a forest of 32 km spires from Disney
    // World and chopped the sun arc at every poked horizon bin.

    func testHealsSaturationRun() {
        // A 40-post saturated run amid 2 m marsh — longer than 4 despike
        // passes could ever erode end-first.
        let ncols = 60, nrows = 9
        var e = [Float](repeating: 2, count: ncols * nrows)
        for c in 10..<50 { e[4 * ncols + c] = 32767 }
        let healed = DEMFetcher.sanitize(&e, ncols: ncols, nrows: nrows, cellMeters: 30)
        XCTAssertEqual(healed.voided, 40)
        for c in 10..<50 { XCTAssertEqual(e[4 * ncols + c], 2) }
    }

    func testHealsSaturationBlob() {
        // 2-D cluster: every interior post has 8 saturated neighbours.
        let n = 20
        var e = [Float](repeating: 3, count: n * n)
        for r in 7..<13 { for c in 7..<13 { e[r * n + c] = 32767 } }
        let healed = DEMFetcher.sanitize(&e, ncols: n, nrows: n, cellMeters: 30)
        XCTAssertEqual(healed.voided, 36)
        XCTAssertTrue(e.allSatisfy { $0 == 3 })
    }

    func testEverestSummitSurvives() {
        // The highest real terrain on Earth is inside the plausible range —
        // the gate must never touch it. A 3×3 summit plateau also gives every
        // post same-height neighbours, so despike leaves it too.
        let n = 9
        var e = [Float](repeating: 8700, count: n * n)
        for r in 3...5 { for c in 3...5 { e[r * n + c] = 8849 } }
        let before = e
        let healed = DEMFetcher.sanitize(&e, ncols: n, nrows: n, cellMeters: 30)
        XCTAssertEqual(healed.voided, 0)
        XCTAssertEqual(healed.spikes, 0)
        XCTAssertEqual(e, before)
    }

    func testCoastalBathymetrySurvives() {
        // The mirror blends real bathymetry into coastal tiles (the Atlantic
        // shelf east of Florida deepens smoothly to ~-500 m). Depths above the
        // deepest trench are data, not corruption.
        let ncols = 50, nrows = 5
        var e = [Float](repeating: 0, count: ncols * nrows)
        for r in 0..<nrows { for c in 0..<ncols { e[r * ncols + c] = Float(c) * -10 } }
        let before = e
        let healed = DEMFetcher.sanitize(&e, ncols: ncols, nrows: nrows, cellMeters: 30)
        XCTAssertEqual(healed.voided, 0)
        XCTAssertEqual(e, before)
    }

    func testImpossibleDepthAndNaNAreVoidedAndRefilled() {
        // Below-trench garbage and NaN (nothing today produces NaN, but a
        // corrupt snapshot float must not poison the raymarcher) both refill
        // from row neighbours.
        let ncols = 7, nrows = 3
        var e = [Float](repeating: 5, count: ncols * nrows)
        e[1 * ncols + 2] = -20000
        e[1 * ncols + 4] = .nan
        let healed = DEMFetcher.sanitize(&e, ncols: ncols, nrows: nrows, cellMeters: 30)
        XCTAssertEqual(healed.voided, 2)
        XCTAssertTrue(e.allSatisfy { $0 == 5 })
    }

    func testSaturationRunBesideRealTerrainRefillsFromTheLand() {
        // Refill must come from the surviving row neighbours, not smear the
        // saturated value: land at 30 m west of a saturated stretch, marsh at
        // 1 m east — healed posts take a real neighbour's height, and despike
        // then has nothing left to do (a step from 30 to 1 m is real terrain).
        let ncols = 12, nrows = 5
        var e = [Float](repeating: 1, count: ncols * nrows)
        for r in 0..<nrows {
            e[r * ncols + 0] = 30; e[r * ncols + 1] = 30
            for c in 2..<6 { e[r * ncols + c] = 32767 }
        }
        let healed = DEMFetcher.sanitize(&e, ncols: ncols, nrows: nrows, cellMeters: 30)
        XCTAssertEqual(healed.voided, 20)
        for r in 0..<nrows {
            for c in 2..<6 {
                let v = e[r * ncols + c]
                XCTAssertTrue(v == 30 || v == 1, "healed post should take a real neighbour height, got \(v)")
            }
        }
        XCTAssertFalse(e.contains { $0 > 9000 })
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

final class LocalSummitTests: XCTestCase {
    /// A synthetic tile from a row-major grid (row 0 = north), ~33 m cells.
    private func makeTile(_ grid: [[Float]]) -> DEMTile {
        let flat = grid.flatMap { $0 }
        return DEMTile(ncols: grid[0].count, nrows: grid.count,
                       xllcorner: -120, yllcorner: 45, cellsize: 0.0003,
                       nodata: -9999, elevations: flat,
                       maxElevation: flat.max() ?? 0)
    }

    private func centerQuery(_ tile: DEMTile) -> (lat: Double, lon: Double) {
        (tile.yllcorner + Double(tile.nrows) * tile.cellsize / 2,
         tile.xllcorner + Double(tile.ncols) * tile.cellsize / 2)
    }

    /// Two bumps joined by a 600 m ridge over a 100 m plain: the union-find
    /// flood must credit the lower bump with prominence above the SADDLE
    /// (800 − 600), the higher with prominence above the window floor.
    func testTwoBumpsSplitProminenceAtTheSaddle() {
        var g = [[Float]](repeating: [Float](repeating: 100, count: 20), count: 20)
        for r in 4...6 { for c in 4...6 { g[r][c] = 900 } }
        g[5][5] = 1000
        for r in 4...6 { for c in 13...15 { g[r][c] = 700 } }
        g[5][14] = 800
        for c in 7...12 { g[5][c] = 600 }          // the connecting ridge
        let tile = makeTile(g)
        let q = centerQuery(tile)
        let summits = tile.localSummits(lat: q.lat, lon: q.lon,
                                        radiusMeters: 400, minProminence: 8)
        XCTAssertEqual(summits.count, 2)
        XCTAssertEqual(summits[0].elev, 1000)      // highest first
        XCTAssertEqual(summits[0].prominence, 900) // above the window floor
        XCTAssertEqual(summits[1].elev, 800)
        XCTAssertEqual(summits[1].prominence, 200) // above the 600 m saddle
        // Each summit sits on its bump's apex cell.
        XCTAssertEqual(summits[0].lon, -120 + (5 + 0.5) * 0.0003, accuracy: 1e-9)
        XCTAssertEqual(summits[1].lon, -120 + (14 + 0.5) * 0.0003, accuracy: 1e-9)
    }

    /// A flat 3-cell plateau must yield ONE candidate, not three.
    func testPlateauYieldsOneSummit() {
        var g = [[Float]](repeating: [Float](repeating: 100, count: 20), count: 20)
        g[10][9] = 500; g[10][10] = 500; g[10][11] = 500
        let tile = makeTile(g)
        let q = centerQuery(tile)
        let summits = tile.localSummits(lat: q.lat, lon: q.lon,
                                        radiusMeters: 400, minProminence: 8)
        XCTAssertEqual(summits.count, 1)
        XCTAssertEqual(summits[0].elev, 500)
        XCTAssertEqual(summits[0].prominence, 400)
    }

    /// Grid ripple below the prominence floor must not become a candidate.
    func testMinProminenceFiltersRipple() {
        var g = [[Float]](repeating: [Float](repeating: 100, count: 20), count: 20)
        for r in 9...11 { for c in 9...11 { g[r][c] = 300 } }
        g[10][10] = 320
        g[15][15] = 106                            // 6 m ripple on the plain
        let tile = makeTile(g)
        let q = centerQuery(tile)
        let summits = tile.localSummits(lat: q.lat, lon: q.lon,
                                        radiusMeters: 400, minProminence: 8)
        XCTAssertEqual(summits.map(\.elev), [320])
        XCTAssertEqual(summits[0].prominence, 220)
    }

    // MARK: matchedSummit — the eye and the dot pick the SAME cell

    /// The K2 bug: the catalog point sits on a low shoulder and the mountain's
    /// real apex is ~400 m away (SRTM void-fill displaces big summits like
    /// this). The LABEL always searched 600 m and scored on agreement with the
    /// catalog height, while the EYE took the highest cell within ~250 m — so
    /// "View" left you on the shoulder with the peak's own dot a few hundred
    /// meters off. `matchedSummit` is now the one rule both use.
    func testMatchedSummitReachesTheApexThatAgreesWithTheCatalogHeight() {
        var g = [[Float]](repeating: [Float](repeating: 100, count: 26), count: 26)
        for r in 11...13 { for c in 5...7 { g[r][c] = 380 } }
        g[12][6] = 400                              // the shoulder, at the catalog point
        for r in 11...13 { for c in 21...23 { g[r][c] = 880 } }
        g[12][22] = 900                             // the real apex, 16 cells (~380 m) east
        let tile = makeTile(g)
        let catalog = (lat: tile.yllcorner + (Double(26 - 1 - 12) + 0.5) * tile.cellsize,
                       lon: tile.xllcorner + (6 + 0.5) * tile.cellsize)
        let apex = tile.matchedSummit(lat: catalog.lat, lon: catalog.lon,
                                      catalogElevationMeters: 900)
        XCTAssertEqual(apex?.elev, 900)
        XCTAssertEqual(apex?.lon ?? 0, tile.xllcorner + (22 + 0.5) * tile.cellsize, accuracy: 1e-9)
        // What the eye used to do, and why the dot ended up beside you.
        XCTAssertEqual(tile.highestNear(lat: catalog.lat, lon: catalog.lon,
                                        radiusMeters: 250).elev, 400)
    }

    /// Standing on a labelled FALSE summit must keep you on its own top: the
    /// higher main summit next door overshoots the catalog height and is
    /// penalized 2×. (This is what replaced the old "45% of the distance to the
    /// nearest other peak" radius cap.)
    func testMatchedSummitStaysOnAFalseSummitInsteadOfClimbingTheMainOne() {
        var g = [[Float]](repeating: [Float](repeating: 100, count: 26), count: 26)
        for r in 11...13 { for c in 11...13 { g[r][c] = 380 } }
        g[12][12] = 400                             // the false summit (catalog 400 m)
        for r in 11...13 { for c in 19...21 { g[r][c] = 880 } }
        g[12][20] = 900                             // the main summit, ~190 m away
        let tile = makeTile(g)
        let catalog = (lat: tile.yllcorner + (Double(26 - 1 - 12) + 0.5) * tile.cellsize,
                       lon: tile.xllcorner + (12 + 0.5) * tile.cellsize)
        let apex = tile.matchedSummit(lat: catalog.lat, lon: catalog.lon,
                                      catalogElevationMeters: 400)
        XCTAssertEqual(apex?.elev, 400)
        XCTAssertEqual(apex?.lon ?? 0, tile.xllcorner + (12 + 0.5) * tile.cellsize, accuracy: 1e-9)
    }

    /// A STALE catalog height must not strand the peak below its own top.
    /// Mount Olympus East Peak: OSM tags 2324 m, the DEM's apex 9 m from the
    /// node reads 2367 m (98 m of prominence) and a 19 m-prominence ripple
    /// 246 m WNW reads 2311. Under the old unbounded 2×/m overshoot penalty
    /// the ripple's better "agreement" beat the apex by 18 points, so the
    /// label — and "Stand here" — sat on a nub between the East and Middle
    /// summits. Overshoot past the tolerance is now flat: the catalog number
    /// is wrong, and distance + prominence decide.
    func testMatchedSummitIgnoresAStaleCatalogHeightThatIsTooLow() {
        var g = [[Float]](repeating: [Float](repeating: 2100, count: 40), count: 40)
        // The true apex: a 2367 m dome at the catalog node.
        for r in 19...21 { for c in 19...21 { g[r][c] = 2340 } }
        g[20][20] = 2367
        // A 2300 m ridge running west off it, with an 11 m ripple on its end
        // ~240 m out — reading 2311, i.e. all but exactly the stale tag.
        for c in 10...18 { g[20][c] = 2300 }
        g[20][10] = 2311
        let tile = makeTile(g)
        let catalog = (lat: tile.yllcorner + (Double(40 - 1 - 20) + 0.5) * tile.cellsize,
                       lon: tile.xllcorner + (20 + 0.5) * tile.cellsize)
        let apex = tile.matchedSummit(lat: catalog.lat, lon: catalog.lon,
                                      catalogElevationMeters: 2324)
        XCTAssertEqual(apex?.elev, 2367)
        XCTAssertEqual(apex?.lon ?? 0, tile.xllcorner + (20 + 0.5) * tile.cellsize,
                       accuracy: 1e-9)
    }

    /// The cap is on OVERSHOOT only. A DEM that reads LOW is the expected
    /// failure (smoothing, void fill), so undershoot stays unbounded and the
    /// least-undershooting candidate still wins — this is what lets a
    /// void-filled summit's real apex be reached a few hundred meters away
    /// (the K2 case above) instead of the shoulder under the catalog point.
    func testUndershootPenaltyStaysUnboundedSoTheLeastLowApexWins() {
        let mLat = 111_320.0, mLon = 111_320.0 * cos(45 * .pi / 180)
        let near = DEMTile.LocalSummit(lat: 45.0, lon: -120.0, elev: 7500, prominence: 100)
        let far = DEMTile.LocalSummit(lat: 45.0, lon: -120.0 + 400 / mLon,
                                      elev: 8500, prominence: 100)
        func score(_ s: DEMTile.LocalSummit) -> Double {
            DEMTile.summitMatchScore(s, catalogLat: 45.0, catalogLon: -120.0,
                                     catalogElevationMeters: 8611,
                                     metersPerDegLat: mLat, metersPerDegLon: mLon)
        }
        XCTAssertGreaterThan(score(far), score(near))
    }

    /// Overshoot past the tolerance is FLAT: 200 m too high scores the same as
    /// 30 m too high, so a wildly wrong catalog height can't rank one wrong
    /// bump above another. (Below the tolerance it still discriminates, 2× per
    /// meter — that is what keeps a labelled false summit on its own bump.)
    func testOvershootPenaltySaturatesAtTheTolerance() {
        let mLat = 111_320.0, mLon = 111_320.0 * cos(45 * .pi / 180)
        func score(elev: Float) -> Double {
            DEMTile.summitMatchScore(
                DEMTile.LocalSummit(lat: 45.0, lon: -120.0, elev: elev, prominence: 50),
                catalogLat: 45.0, catalogLon: -120.0, catalogElevationMeters: 1000,
                metersPerDegLat: mLat, metersPerDegLon: mLon)
        }
        let tol = DEMTile.summitOvershootToleranceMeters
        XCTAssertEqual(score(elev: 1000 + Float(tol) + 5),
                       score(elev: 1000 + Float(tol) + 200), accuracy: 1e-9)
        XCTAssertLessThan(score(elev: Float(1000 + tol)), score(elev: 1000))
    }

    /// No catalog height (an OSM peak with no `ele` tag): nothing to agree
    /// with, so the higher candidate wins.
    func testMatchedSummitWithoutACatalogHeightPrefersTheHigherBump() {
        var g = [[Float]](repeating: [Float](repeating: 100, count: 26), count: 26)
        for r in 11...13 { for c in 11...13 { g[r][c] = 380 } }
        g[12][12] = 400
        for r in 11...13 { for c in 19...21 { g[r][c] = 880 } }
        g[12][20] = 900
        let tile = makeTile(g)
        let catalog = (lat: tile.yllcorner + (Double(26 - 1 - 12) + 0.5) * tile.cellsize,
                       lon: tile.xllcorner + (12 + 0.5) * tile.cellsize)
        XCTAssertEqual(tile.matchedSummit(lat: catalog.lat, lon: catalog.lon,
                                          catalogElevationMeters: nil)?.elev, 900)
    }

    // MARK: The leftover gate — a match must beat staying at the catalog point

    /// Two catalog records for one summit (Rainier/Columbia Crest), or two named
    /// tops the 30 m grid can't resolve: one claims the apex and the other used
    /// to take whatever maximum was left, however far and however flat —
    /// Columbia Crest walked 691 m onto a 9 m-prominence nub. The runner-up's
    /// own node is the honest anchor when the DEM says its height already
    /// agrees. (Cathedral Rocks, from the measured corpus: tag 3026 m, node
    /// reads 3027 m, only leftover an 8 m-prominence nub 250 m away.)
    func testAClaimedApexLeavesThePeakAtItsNodeInsteadOfAWanderingLeftover() {
        let mLat = 111_320.0, mLon = 111_320.0 * cos(46.8 * .pi / 180)
        let leftover = DEMTile.LocalSummit(lat: 46.8, lon: -121.76 + 250 / mLon,
                                           elev: 3123, prominence: 8)
        let score = DEMTile.summitMatchScore(
            leftover, catalogLat: 46.8, catalogLon: -121.76,
            catalogElevationMeters: 3026,
            metersPerDegLat: mLat, metersPerDegLon: mLon)
        let stayPut = DEMTile.stayPutScore(
            demElevationAtPoint: 3027, catalogLat: 46.8, catalogLon: -121.76,
            catalogElevationMeters: 3026)
        XCTAssertFalse(DEMTile.acceptsMatch(score: score, stayPut: stayPut))
    }

    /// The margin is NOT "the node wins ties": a node is a flank cell and a
    /// bump is a top, so a real apex nearby is still worth walking to even when
    /// the node's own height already agrees with the catalog. Refusing these
    /// would undo the summit snap itself.
    func testANearbyApexIsStillTakenWhenTheNodeAlreadyAgrees() {
        let mLat = 111_320.0, mLon = 111_320.0 * cos(46.8 * .pi / 180)
        let apex = DEMTile.LocalSummit(lat: 46.8, lon: -121.76 + 40 / mLon,
                                       elev: 1005, prominence: 60)
        let score = DEMTile.summitMatchScore(
            apex, catalogLat: 46.8, catalogLon: -121.76,
            catalogElevationMeters: 1000,
            metersPerDegLat: mLat, metersPerDegLon: mLon)
        let stayPut = DEMTile.stayPutScore(
            demElevationAtPoint: 1000, catalogLat: 46.8, catalogLon: -121.76,
            catalogElevationMeters: 1000)
        XCTAssertTrue(DEMTile.acceptsMatch(score: score, stayPut: stayPut))
    }

    /// A badly placed node (the void-fill / K2 case: it reads 1100 m below the
    /// surveyed height) makes staying put terrible, so the distant apex that
    /// agrees is still taken — the gate must not strand a peak on a shoulder.
    func testAVoidFilledApexIsStillReachedFromABadNode() {
        let mLat = 111_320.0, mLon = 111_320.0 * cos(35.88 * .pi / 180)
        let apex = DEMTile.LocalSummit(lat: 35.88, lon: 76.51 + 400 / mLon,
                                       elev: 8500, prominence: 100)
        let score = DEMTile.summitMatchScore(
            apex, catalogLat: 35.88, catalogLon: 76.51,
            catalogElevationMeters: 8611,
            metersPerDegLat: mLat, metersPerDegLon: mLon)
        let stayPut = DEMTile.stayPutScore(
            demElevationAtPoint: 7500, catalogLat: 35.88, catalogLon: 76.51,
            catalogElevationMeters: 8611)
        XCTAssertTrue(DEMTile.acceptsMatch(score: score, stayPut: stayPut))
    }

    /// Flat ground has no local maximum to stand on — the caller falls back to
    /// the catalog point rather than being handed an arbitrary cell.
    func testMatchedSummitIsNilWithNoBumpInReach() {
        let g = [[Float]](repeating: [Float](repeating: 100, count: 26), count: 26)
        let tile = makeTile(g)
        let q = centerQuery(tile)
        XCTAssertNil(tile.matchedSummit(lat: q.lat, lon: q.lon,
                                        catalogElevationMeters: 100))
    }
}

final class SightlineProfileTests: XCTestCase {
    /// A synthetic tile whose elevation varies only by COLUMN (west→east),
    /// on the equator so a cell is a fixed 0.0003° ≈ 33.4 m of easting.
    private func makeTile(profile: [Float]) -> DEMTile {
        let row = profile
        let grid = [[Float]](repeating: row, count: 21)
        return DEMTile(ncols: row.count, nrows: 21, xllcorner: 0, yllcorner: -0.00315,
                       cellsize: 0.0003, nodata: -9999, elevations: grid.flatMap { $0 },
                       maxElevation: profile.max() ?? 0)
    }

    private let cellMeters = 0.0003 * 111_320.0
    private func lon(col: Double) -> Double { (col + 0.5) * 0.0003 }

    private func profile(_ tile: DEMTile, eyeCol: Double, featCol: Double,
                         featElev: Double, camElev: Double)
        -> (blocked: Bool, crestHoriz: Double, crestTan: Double, colDepth: Double) {
        let horiz = (featCol - eyeCol) * cellMeters
        return TerrainMetalView.Coordinator.sightlineProfile(
            eyeLat: 0, eyeLon: lon(col: eyeCol),
            featLat: 0, featLon: lon(col: featCol),
            horiz: horiz, apparentUp: featElev - camElev,
            camElevMeters: camElev, heightScale: 1, curvatureK: 0,
            dem: tile, far: nil)
    }

    /// Summit hidden behind its OWN shoulder (ground rises continuously from
    /// the shoulder to the top): blocked, but with essentially no col — the
    /// case that pins the label to the visible crest.
    func testOwnShoulderBlocksWithShallowCol() {
        var p = [Float](repeating: 100, count: 45)
        for c in 10...30 { p[c] = 100 + Float(c - 10) * 35 }      // rise to 800
        for c in 31...40 { p[c] = 800 + Float(c - 30) * 20 }      // shoulder → 1000 summit
        let tile = makeTile(profile: p)
        let r = profile(tile, eyeCol: 5.5, featCol: 40.5, featElev: 1000, camElev: 101.6)
        XCTAssertTrue(r.blocked)
        XCTAssertLessThan(r.colDepth, 40, "one continuous mass — no hidden valley")
    }

    /// A SEPARATE foreground ridge with a deep valley behind it: blocked with
    /// a col of hundreds of meters — must NOT crest-pin.
    func testSeparateRidgeBlocksWithDeepCol() {
        var p = [Float](repeating: 100, count: 45)
        for c in 10...19 { p[c] = 100 + Float(c - 10) * 78 }      // ridge to ~800
        p[20] = 800
        for c in 21...29 { p[c] = 200 }                            // hidden valley
        for c in 30...40 { p[c] = 200 + Float(c - 30) * 80 }      // far summit 1000
        let tile = makeTile(profile: p)
        let r = profile(tile, eyeCol: 5.5, featCol: 40.5, featElev: 1000, camElev: 101.6)
        XCTAssertTrue(r.blocked)
        XCTAssertGreaterThan(r.colDepth, 200)
    }

    /// Standing on a summit plateau, the ground at your feet — the dome edge
    /// ~15–30 m out, inside the old march's 60 m blind gap — hides everything
    /// behind and below it. The valley feature must read BLOCKED, exactly as
    /// the renderer draws foreground ground at its angle ("points coming
    /// through the ground at my feet").
    func testSummitForegroundBlocksFeatureBelowTheDomeEdge() {
        var p = [Float](repeating: 200, count: 45)
        for c in 0...6 { p[c] = 1000 }                            // summit plateau
        for c in 7...10 { p[c] = 1000 - Float(c - 6) * 200 }      // dome falls away
        let tile = makeTile(profile: p)
        let r = profile(tile, eyeCol: 5.5, featCol: 40.5, featElev: 250, camElev: 1001.6)
        XCTAssertTrue(r.blocked, "the plateau edge is the occluder")
        XCTAssertLessThan(r.crestHoriz, 60, "the crest sits inside the old blind gap")
    }

    /// Same summit eye, feature ABOVE the horizon: the fine near-field
    /// sampling must not self-occlude on the eye's own plateau.
    func testSummitEyeStillSeesFeaturesAboveTheHorizon() {
        var p = [Float](repeating: 200, count: 45)
        for c in 0...6 { p[c] = 1000 }
        for c in 7...10 { p[c] = 1000 - Float(c - 6) * 200 }
        let tile = makeTile(profile: p)
        let r = profile(tile, eyeCol: 5.5, featCol: 40.5, featElev: 2000, camElev: 1001.6)
        XCTAssertFalse(r.blocked)
    }

    /// Concave approach (flat valley floor, then a steep final rise): the
    /// summit is genuinely visible — not blocked.
    func testClearSightlineOverConcaveGround() {
        var p = [Float](repeating: 100, count: 45)
        for c in 35...40 { p[c] = 100 + Float(c - 35) * 180 }     // steep rise to 1000
        let tile = makeTile(profile: p)
        let r = profile(tile, eyeCol: 5.5, featCol: 40.5, featElev: 1000, camElev: 101.6)
        XCTAssertFalse(r.blocked)
    }
}

final class CopernicusDEMTests: XCTestCase {
    // MARK: Synthetic COG builder — the exact layout the bucket serves
    // (little-endian classic TIFF, float32, tiled, deflate + predictor 3),
    // so the decoder is exercised against independently constructed bytes.

    /// zlib-wrap raw deflate the way the real tiles are stored (2-byte
    /// header; the decoder strips it and ignores the missing adler).
    private func zlibCompress(_ bytes: [UInt8]) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: bytes.count + 4096)
        let n = compression_encode_buffer(&dst, dst.count, bytes, bytes.count,
                                          nil, COMPRESSION_ZLIB)
        XCTAssertGreaterThan(n, 0)
        return [0x78, 0x9C] + dst[0..<n]
    }

    /// One tile's payload: floats → 4 byte planes (MSB first) per row,
    /// horizontal byte differencing, deflate.
    private func encodeTile(_ v: [Float], tileW: Int, tileH: Int) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: tileW * tileH * 4)
        for r in 0..<tileH {
            let base = r * tileW * 4
            for c in 0..<tileW {
                let bits = v[r * tileW + c].bitPattern
                raw[base + c] = UInt8(truncatingIfNeeded: bits >> 24)
                raw[base + tileW + c] = UInt8(truncatingIfNeeded: bits >> 16)
                raw[base + 2 * tileW + c] = UInt8(truncatingIfNeeded: bits >> 8)
                raw[base + 3 * tileW + c] = UInt8(truncatingIfNeeded: bits)
            }
            for i in stride(from: tileW * 4 - 1, through: 1, by: -1) {
                raw[base + i] = raw[base + i] &- raw[base + i - 1]
            }
        }
        return zlibCompress(raw)
    }

    private func makeTIFF(width: Int, height: Int, tileW: Int, tileH: Int,
                          values: [Float]) -> Data {
        let across = (width + tileW - 1) / tileW
        let down = (height + tileH - 1) / tileH
        var tiles: [[UInt8]] = []
        for t in 0..<(across * down) {
            let rowLo = (t / across) * tileH, colLo = (t % across) * tileW
            var v = [Float](repeating: 0, count: tileW * tileH)   // edge padding
            for r in 0..<tileH where rowLo + r < height {
                for c in 0..<tileW where colLo + c < width {
                    v[r * tileW + c] = values[(rowLo + r) * width + colLo + c]
                }
            }
            tiles.append(encodeTile(v, tileW: tileW, tileH: tileH))
        }
        var d = [UInt8](repeating: 0, count: 8)
        d[0] = 0x49; d[1] = 0x49; d[2] = 42                       // II, magic
        var offsets: [Int] = [], counts: [Int] = []
        for t in tiles { offsets.append(d.count); counts.append(t.count); d += t }
        func u32le(_ v: Int) -> [UInt8] {
            let b0 = UInt8(v & 0xFF)
            let b1 = UInt8((v >> 8) & 0xFF)
            let b2 = UInt8((v >> 16) & 0xFF)
            let b3 = UInt8((v >> 24) & 0xFF)
            return [b0, b1, b2, b3]
        }
        let offArrayAt = d.count
        for o in offsets { d += u32le(o) }
        let cntArrayAt = d.count
        for c in counts { d += u32le(c) }
        let ifdAt = d.count
        var entries: [[UInt8]] = []
        func entry(_ tag: Int, _ typ: Int, _ cnt: Int, _ val: Int) {
            var e: [UInt8] = [UInt8(tag & 0xFF), UInt8(tag >> 8), UInt8(typ), 0]
            e += u32le(cnt)
            e += u32le(val)
            entries.append(e)
        }
        entry(256, 3, 1, width); entry(257, 3, 1, height)
        entry(258, 3, 1, 32); entry(259, 3, 1, 8); entry(277, 3, 1, 1)
        entry(317, 3, 1, 3); entry(322, 3, 1, tileW); entry(323, 3, 1, tileH)
        entry(324, 4, offsets.count, offsets.count == 1 ? offsets[0] : offArrayAt)
        entry(325, 4, counts.count, counts.count == 1 ? counts[0] : cntArrayAt)
        entry(339, 3, 1, 3)
        d += [UInt8(entries.count), 0]
        for e in entries { d += e }
        d += u32le(0)                                             // no next IFD
        d[4] = UInt8(ifdAt & 0xFF); d[5] = UInt8((ifdAt >> 8) & 0xFF)
        d[6] = UInt8((ifdAt >> 16) & 0xFF); d[7] = UInt8((ifdAt >> 24) & 0xFF)
        return Data(d)
    }

    /// Multi-tile grid with edge-padded tiles decodes to the exact floats.
    func testDecodeGridRoundTrip() throws {
        let w = 6, h = 5                                          // 2×3 grid of 4×2 tiles
        let values: [Float] = (0..<(w * h)).map { (i: Int) -> Float in
            let cell: Int = (i / w) * 100 + (i % w)
            return Float(cell) + 0.25
        }
        let tiff = makeTIFF(width: w, height: h, tileW: 4, tileH: 2, values: values)
        let grid = try CopernicusDEM.decodeGrid(tiff: tiff)
        XCTAssertEqual(grid.width, w)
        XCTAssertEqual(grid.height, h)
        XCTAssertEqual(grid.values, values)
    }

    /// A changed upstream layout (stripes, LZW, no predictor…) must throw,
    /// never render garbage terrain.
    func testDecodeGridRejectsUnknownLayout() {
        let values = [Float](repeating: 1, count: 16)
        var tiff = makeTIFF(width: 4, height: 4, tileW: 4, tileH: 4, values: values)
        XCTAssertNoThrow(try CopernicusDEM.decodeGrid(tiff: tiff))
        // Flip compression tag value 8 → 5 (LZW) in place. Entry bytes:
        // tag 259 LE, type 3, count 1, value 8.
        if let range = tiff.firstRange(of: Data([3, 1, 3, 0, 1, 0, 0, 0, 8, 0, 0, 0])) {
            tiff[range.lowerBound + 8] = 5
            XCTAssertThrowsError(try CopernicusDEM.decodeGrid(tiff: tiff))
        } else {
            XCTFail("compression entry not found")
        }
        XCTAssertThrowsError(try CopernicusDEM.decodeGrid(tiff: Data([0x49, 0x49, 42, 0])))
    }

    private func post(_ hgt: Data, _ r: Int, _ c: Int) -> Int16 {
        let o = (r * 3601 + c) * 2
        return Int16(bitPattern: UInt16(hgt[o]) << 8 | UInt16(hgt[o + 1]))
    }

    /// Longitude/latitude interpolation onto the 1″ post grid: decoded posts
    /// land exactly, in-between posts are linear blends, the missing
    /// south/east edge posts clamp to the last real post.
    func testResampleInterpolatesAndClampsEdges() {
        // 2×2 grid: NW 0, NE 100, SW 200, SE 300.
        let hgt = CopernicusDEM.resampleToHGT([0, 100, 200, 300], width: 2, height: 2)
        XCTAssertEqual(hgt.count, 3601 * 3601 * 2)
        // 2 source rows/cols span the degree at 1800″ steps: post 1800 lands
        // EXACTLY on source row/col 1 (Copernicus leaves the south/east
        // half-degree… full-degree edge to the neighbouring tile).
        XCTAssertEqual(post(hgt, 0, 0), 0)
        XCTAssertEqual(post(hgt, 0, 1800), 100)     // x = 1800*2/3600 = col 1
        XCTAssertEqual(post(hgt, 0, 900), 50)       // halfway NW→NE
        XCTAssertEqual(post(hgt, 900, 0), 100)      // halfway NW→SW
        XCTAssertEqual(post(hgt, 0, 3600), 100)     // east edge clamps to NE
        XCTAssertEqual(post(hgt, 3600, 0), 200)     // south edge clamps to SW
        XCTAssertEqual(post(hgt, 3600, 3600), 300)
        XCTAssertEqual(post(hgt, 900, 900), 150)    // interior: bilinear blend
    }

    /// Non-finite / deep-negative source samples become the SRTM void
    /// sentinel the stitcher's fillVoids already handles.
    func testResampleMapsNodataToVoidSentinel() {
        let hgt = CopernicusDEM.resampleToHGT([Float.nan, -32767, 5, 5],
                                              width: 2, height: 2)
        XCTAssertEqual(post(hgt, 0, 0), -32768)
        XCTAssertEqual(post(hgt, 0, 3600), -32768)
    }

    /// The converter's gzip container must be readable by the same gunzip
    /// every cached skadi tile goes through.
    func testGzipRoundTripsThroughDEMFetcherGunzip() {
        var bytes = Data(capacity: 70_000)
        var seed: UInt32 = 0x2468ACE0
        for _ in 0..<70_000 {                        // xorshift: incompressible-ish
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            bytes.append(UInt8(truncatingIfNeeded: seed))
        }
        let gz = CopernicusDEM.gzip(bytes)
        XCTAssertNotNil(gz)
        XCTAssertEqual(DEMFetcher.gunzip(gz!), bytes)
    }

    /// Latitude gating and S3 object naming (incl. antimeridian wrap) —
    /// exactly the tiles SRTM never covered go to Copernicus.
    func testCoverageGateAndObjectNames() {
        XCTAssertFalse(CopernicusDEM.coversTile(tLat: 59))   // Alps…Oslo: skadi
        XCTAssertTrue(CopernicusDEM.coversTile(tLat: 60))    // 60–61°N band
        XCTAssertTrue(CopernicusDEM.coversTile(tLat: 64))    // Iceland
        XCTAssertFalse(CopernicusDEM.coversTile(tLat: -56))  // Tierra del Fuego: skadi
        XCTAssertTrue(CopernicusDEM.coversTile(tLat: -57))
        XCTAssertEqual(CopernicusDEM.objectName(tLat: 64, tLon: -18),
                       "Copernicus_DSM_COG_10_N64_00_W018_00_DEM")
        XCTAssertEqual(CopernicusDEM.objectName(tLat: -57, tLon: 170),
                       "Copernicus_DSM_COG_10_S57_00_E170_00_DEM")
        XCTAssertEqual(CopernicusDEM.objectName(tLat: 65, tLon: -181),
                       "Copernicus_DSM_COG_10_N65_00_E179_00_DEM")
        XCTAssertEqual(CopernicusDEM.objectName(tLat: 65, tLon: 180),
                       "Copernicus_DSM_COG_10_N65_00_W180_00_DEM")
    }

    /// Converter provenance: our fixed gzip header marks a tile as
    /// Copernicus-converted; skadi's server gzip (FNAME flag + real mtime,
    /// as served by the mirror) must read as stale at high latitudes.
    func testIsConvertedDistinguishesSkadiTiles() {
        let converted = CopernicusDEM.gzip(Data(repeating: 7, count: 64))!
        XCTAssertTrue(CopernicusDEM.isConverted(converted))
        var skadiStyle = Data([0x1F, 0x8B, 8, 8, 0x73, 3, 0x1C, 0x57, 2, 0xFF])
        skadiStyle.append(Data("N64W018.hgt\0".utf8))
        skadiStyle.append(Data(repeating: 0, count: 32))
        XCTAssertFalse(CopernicusDEM.isConverted(skadiStyle))
        XCTAssertFalse(CopernicusDEM.isConverted(Data([0x1F, 0x8B])))
    }

    /// End-to-end: synthetic COG → convertToHGTGZ → gunzip → SRTM1 bytes.
    func testConvertToHGTGZEndToEnd() throws {
        let values: [Float] = [10, 20, 30, 40]
        let tiff = makeTIFF(width: 2, height: 2, tileW: 2, tileH: 2, values: values)
        let gz = try CopernicusDEM.convertToHGTGZ(tiff: tiff)
        let hgt = DEMFetcher.gunzip(gz)
        XCTAssertEqual(hgt?.count, 3601 * 3601 * 2)
        XCTAssertEqual(post(hgt!, 0, 0), 10)
        XCTAssertEqual(post(hgt!, 3600, 3600), 40)
    }
}
