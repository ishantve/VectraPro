//
//  RunwayGeometryTests.swift
//  VectraProTests
//

import Testing
import CoreLocation
@testable import VectraPro

@MainActor
struct RunwayGeometryTests {

    @Test func canonicalStripsLeadingZerosAndLowercasesSide() {
        #expect(RunwayGeometry.canonical("08L") == "8l")
        #expect(RunwayGeometry.canonical("09")  == "9")
        #expect(RunwayGeometry.canonical("27R") == "27r")
        #expect(RunwayGeometry.canonical("27")  == "27")
        #expect(RunwayGeometry.canonical("36C") == "36c")
    }

    @Test func thresholdReturnsEndAndInboundCourse() {
        let a = Fixtures.center
        let rwy = Fixtures.runway("09", at: a, "27", bearingAB: 90)

        let t9 = RunwayGeometry.threshold(for: "9", in: [rwy])
        #expect(t9 != nil)
        #expect(approxEqual(t9!.threshold, a))
        #expect(abs(t9!.inbound - 90) < 1.0)          // inbound = bearing A→B

        // The opposite end lands on the reciprocal course.
        let t27 = RunwayGeometry.threshold(for: "27", in: [rwy])
        #expect(t27 != nil)
        #expect(abs(t27!.inbound - 270) < 1.0)
    }

    @Test func thresholdMatchesIgnoringLeadingZeroAndCase() {
        let rwy = Fixtures.runway("09", "27", bearingAB: 90)
        #expect(RunwayGeometry.threshold(for: "09", in: [rwy]) != nil)
        #expect(RunwayGeometry.threshold(for: "9",  in: [rwy]) != nil)
    }

    @Test func thresholdUnknownRunwayIsNil() {
        let rwy = Fixtures.runway("09", "27", bearingAB: 90)
        #expect(RunwayGeometry.threshold(for: "15", in: [rwy]) == nil)
        #expect(RunwayGeometry.threshold(for: "9", in: []) == nil)
    }

    @Test func departureThresholdUsesAssignedRunway() {
        let a = Fixtures.center
        let rwy = Fixtures.runway("09", at: a, "27", bearingAB: 90)
        var ac = Fixtures.aircraft()
        ac.assignedRunway = "09"

        let (coord, heading) = RunwayGeometry.departureThreshold(for: ac, in: [rwy], center: a)
        #expect(approxEqual(coord, a))
        #expect(abs(heading - 90) < 1.0)
    }

    @Test func departureThresholdFallsBackToFirstRunwayThenCenter() {
        let a = Fixtures.center
        let rwy = Fixtures.runway("09", at: a, "27", bearingAB: 90)
        var ac = Fixtures.aircraft()
        ac.assignedRunway = "NOPE"

        // Unknown assigned → first runway's endA.
        let (coord, _) = RunwayGeometry.departureThreshold(for: ac, in: [rwy], center: a)
        #expect(approxEqual(coord, a))

        // No runways at all → the given centre, heading 0.
        let fallbackCenter = Fixtures.coord(10, 20)
        let (c2, h2) = RunwayGeometry.departureThreshold(for: ac, in: [], center: fallbackCenter)
        #expect(approxEqual(c2, fallbackCenter))
        #expect(h2 == 0)
    }
}
