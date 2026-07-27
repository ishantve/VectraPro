//
//  ATCSimKitTests.swift
//  ATCSimKit
//
//  Standalone coverage for the extracted simulation core (models + stateless
//  services), using the kit's own public types.
//

import XCTest
import CoreLocation
import GeoKit
@testable import ATCSimKit

private enum F {
    static let center = CLLocationCoordinate2D(latitude: 28.5665, longitude: 77.1031)
    static func coord(_ a: Double, _ b: Double) -> CLLocationCoordinate2D { .init(latitude: a, longitude: b) }
    static func runway(_ dA: String = "09", _ dB: String = "27",
                       bearingAB: Double = 90, at a: CLLocationCoordinate2D = center) -> Runway {
        let b = Geo.offset(from: a, distanceMeters: 3000, bearingDegrees: bearingAB)
        return Runway(endA: .init(designator: dA, coordinate: a),
                      endB: .init(designator: dB, coordinate: b), lengthMeters: 3000)
    }
    static func fix(_ n: String, type: String = "HOLDING",
                    lat: Double? = 28.6, lon: Double? = 77.2) -> Fix {
        .init(fixName: n, type: type, latitude: lat, longitude: lon)
    }
    static func aircraft(_ cs: String = "TST", at p: CLLocationCoordinate2D = center,
                         heading: Double = 0) -> Aircraft {
        .init(callsign: cs, position: p, headingDegrees: heading)
    }
    static func type(_ i: String, wtc: String) -> AircraftType { .init(icaoCode: i, icaoWTC: wtc) }
    static func airline(_ i: String, _ c: String) -> Airline { .init(icaoCode: i, callSign: c) }
    static func offsetNM(from o: CLLocationCoordinate2D, nm: Double, bearing: Double) -> CLLocationCoordinate2D {
        Geo.offset(from: o, distanceMeters: nm * 1852, bearingDegrees: bearing)
    }
    static func angDiff(_ a: Double, _ b: Double) -> Double {
        var d = abs((a - b).truncatingRemainder(dividingBy: 360)); if d > 180 { d = 360 - d }; return d
    }
}

final class RunwayGeometryTests: XCTestCase {
    func testCanonical() {
        XCTAssertEqual(RunwayGeometry.canonical("08L"), "8l")
        XCTAssertEqual(RunwayGeometry.canonical("27"), "27")
    }
    func testThreshold() {
        let r = F.runway()
        let t = RunwayGeometry.threshold(for: "9", in: [r])
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.inbound, 90, accuracy: 1)
        XCTAssertNil(RunwayGeometry.threshold(for: "15", in: [r]))
    }
}

final class FixLookupTests: XCTestCase {
    func testTolerantMatchAndPosition() {
        let fixes = [F.fix("RE-01", lat: 28.6, lon: 77.2)]
        XCTAssertEqual(FixLookup.fix(named: "re01", in: fixes)?.fixName, "RE-01")
        XCTAssertNil(FixLookup.fix(named: "zz", in: fixes))
        XCTAssertNotNil(FixLookup.position(named: "re01", in: fixes))
    }
}

final class SequencingTests: XCTestCase {
    private let types = [F.type("LGT", wtc: "L"), F.type("B738", wtc: "M")]
    func testRequiredSeparation() {
        var l = F.aircraft("L"); l.aircraftType = "LGT"
        var m = F.aircraft("M"); m.aircraftType = "B738"
        XCTAssertEqual(SequencingSeparationService.requiredSeparationNM(l, m, aircraftTypes: types), 10)
        XCTAssertEqual(SequencingSeparationService.requiredSeparationNM(m, m, aircraftTypes: types), 8)
    }
    func testConflicts() {
        let t = F.center; let r = F.runway("09", at: t)
        var a = F.aircraft("A", at: F.offsetNM(from: t, nm: 3, bearing: 270)); a.interceptRunway = "09"
        var b = F.aircraft("B", at: F.offsetNM(from: t, nm: 6, bearing: 270)); b.interceptRunway = "09"
        let c = SequencingSeparationService.conflicts(among: [a, b], runways: [r], aircraftTypes: types)
        XCTAssertTrue(c.contains(a.id) && c.contains(b.id))
    }
}

final class CallsignResolverTests: XCTestCase {
    func testDirectAndAirline() {
        XCTAssertEqual(CallsignResolver.resolve(from: "aca 29", among: [F.aircraft("ACA29")], airlines: []), "ACA29")
        XCTAssertEqual(CallsignResolver.resolve(from: "air india 235",
                                                among: [F.aircraft("AIC235")],
                                                airlines: [F.airline("AIC", "AIR INDIA")]), "AIC235")
    }
}

final class LocalizerGuidanceTests: XCTestCase {
    func testConeAndReach() {
        let t = F.center; let r = F.runway("09", at: t)
        var ac = F.aircraft(at: F.offsetNM(from: t, nm: 5, bearing: 270), heading: 90); ac.interceptRunway = "09"
        XCTAssertTrue(LocalizerGuidanceService.isInCone(aircraft: ac, runway: "09", runways: [r]))
        ac.altitudeFeet = 3000
        XCTAssertTrue(LocalizerGuidanceService.canReachRunway(aircraft: ac, runway: "09", runways: [r]))
        ac.altitudeFeet = 18000
        XCTAssertFalse(LocalizerGuidanceService.canReachRunway(aircraft: ac, runway: "09", runways: [r]))
    }
    func testGuideBoundedInterceptFarOff() {
        let t = F.center; let r = F.runway("09", at: t)
        let foot = F.offsetNM(from: t, nm: 10, bearing: 270)
        var ac = F.aircraft(at: F.offsetNM(from: foot, nm: 8, bearing: 0), heading: 90); ac.interceptRunway = "09"
        LocalizerGuidanceService.guide(&ac, runways: [r])
        XCTAssertLessThanOrEqual(F.angDiff(ac.targetHeading ?? 0, 90), 31)
    }
}

final class AircraftPhysicsTests: XCTestCase {
    func testTurnAndPositionAdvance() {
        let p = AircraftPhysics.shared
        var ac = F.aircraft(heading: 0); ac.speedKnots = 250; ac.targetHeading = 90
        p.stepPhysics(&ac, dt: 1)
        XCTAssertTrue(ac.headingDegrees > 0 && ac.headingDegrees < 90)

        var straight = F.aircraft(at: F.center, heading: 90); straight.speedKnots = 250
        let start = straight.position
        p.stepPhysics(&straight, dt: 1)
        XCTAssertEqual(Geo.distanceMeters(from: start, to: straight.position), 250 * 1852 / 3600, accuracy: 3)
    }
}

final class HoldingTests: XCTestCase {
    func testSteerAndCapture() {
        let fc = F.coord(28.6, 77.2); let fix = F.fix("REX", lat: fc.latitude, lon: fc.longitude)
        var steer = F.aircraft(at: F.center, heading: 0); steer.holdingTargetName = "REX"
        HoldingController.steer(&steer, fixes: [fix])
        XCTAssertNotNil(steer.targetHeading)

        let reach = F.aircraft().noseOffsetNM + F.aircraft().noseForwardNM
        var ac = F.aircraft("H", at: F.offsetNM(from: fc, nm: reach, bearing: 180), heading: 0)
        ac.holdingTargetName = "REX"
        var aircraft = [ac]; var traffic: [Aircraft] = []
        let captured = HoldingController.capture(aircraft: &aircraft, traffic: &traffic, fixes: [fix])
        XCTAssertTrue(captured.contains(ac.id))
        XCTAssertEqual(traffic.first?.holdingName, "REX")
    }
    func testRacetrackGeometry() {
        let rt = HoldingRacetrack(fix: F.center, inboundCourse: 90, speedKnots: 220)
        XCTAssertGreaterThan(rt.radiusM, 0)
        XCTAssertEqual(rt.totalLength, 2 * rt.legM + 2 * .pi * rt.radiusM, accuracy: 1e-6)
        XCTAssertLessThan(Geo.distanceMeters(from: rt.sample(at: 0).position, to: F.center), 5)
    }
}

final class CommandParserTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(CommandParser.parse(CommandParser.normalize("turn left heading 270")), [.headingTurn(270, .left)])
        XCTAssertEqual(CommandParser.parse(CommandParser.normalize("hold at papa juliet")), [.hold("PJ")])
        XCTAssertEqual(CommandParser.parse(CommandParser.normalize("climb flight level 250")), [.flightLevel(250)])
    }
}

final class CommandValidatorTests: XCTestCase {
    private func ctx(_ r: Runway? = nil, loc: Set<String> = [], fixes: [Fix] = []) -> CommandValidator.Context {
        .init(runways: r.map { [$0] } ?? [], activeLocalizerRunways: loc, holdingFixes: fixes)
    }
    func testEnvelopes() {
        XCTAssertEqual(CommandValidator.validate([.flightLevel(250)], for: F.aircraft(), context: ctx()), .ok)
        if case .ok = CommandValidator.validate([.flightLevel(600)], for: F.aircraft(), context: ctx()) { XCTFail() }
        if case .ok = CommandValidator.validate([.speed(50)], for: F.aircraft(), context: ctx()) { XCTFail() }
    }
    func testHoldFixMustExist() {
        let c = ctx(fixes: [F.fix("RE-01")])
        XCTAssertEqual(CommandValidator.validate([.hold("re01")], for: F.aircraft(), context: c), .ok)
        if case .ok = CommandValidator.validate([.hold("zz")], for: F.aircraft(), context: c) { XCTFail() }
    }
}
