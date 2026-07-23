//
//  LocalizerGuidanceServiceTests.swift
//  VectraProTests
//

import Testing
import CoreLocation
@testable import VectraPro

@MainActor
struct LocalizerGuidanceServiceTests {

    // Runway "09": threshold at centre, inbound course ≈ 090 (landing eastbound).
    // The approach extends WEST of the threshold (approachDir ≈ 270).
    private func setup() -> (rwy: Runway, threshold: CLLocationCoordinate2D) {
        let t = Fixtures.center
        return (Fixtures.runway("09", at: t, "27", bearingAB: 90), t)
    }

    // MARK: cone validation

    @Test func inConeWhenOnFinalAndHeadingInbound() {
        let (rwy, t) = setup()
        // 5 NM west of the threshold, heading ~inbound (090).
        var ac = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 5, bearing: 270), heading: 90)
        ac.interceptRunway = "09"
        #expect(LocalizerGuidanceService.isInCone(aircraft: ac, runway: "09", runways: [rwy]))
    }

    @Test func notInConeWhenHeadingAway() {
        let (rwy, t) = setup()
        var ac = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 5, bearing: 270), heading: 270)
        ac.interceptRunway = "09"
        #expect(!LocalizerGuidanceService.isInCone(aircraft: ac, runway: "09", runways: [rwy]))
    }

    @Test func notInConeWhenOutsidePositionFunnel() {
        let (rwy, t) = setup()
        // Well off to the side of the approach funnel (bearing 180 from threshold).
        var ac = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 5, bearing: 180), heading: 90)
        ac.interceptRunway = "09"
        #expect(!LocalizerGuidanceService.isInCone(aircraft: ac, runway: "09", runways: [rwy]))
    }

    // MARK: touchdown detection

    @Test func reachedRunwayNeedsThresholdAndGround() {
        let (rwy, t) = setup()

        var landed = Fixtures.aircraft(at: t); landed.interceptRunway = "09"; landed.altitudeFeet = 100
        #expect(LocalizerGuidanceService.reachedRunway(landed, runways: [rwy]))

        var highOverThreshold = Fixtures.aircraft(at: t); highOverThreshold.interceptRunway = "09"
        highOverThreshold.altitudeFeet = 1500
        #expect(!LocalizerGuidanceService.reachedRunway(highOverThreshold, runways: [rwy]))

        var lowButFar = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 5, bearing: 270))
        lowButFar.interceptRunway = "09"; lowButFar.altitudeFeet = 100
        #expect(!LocalizerGuidanceService.reachedRunway(lowButFar, runways: [rwy]))
    }

    // MARK: guidance

    @Test func guideSetsApproachSpeedAndDescentOnFinal() {
        let (rwy, t) = setup()
        var ac = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 6, bearing: 270), heading: 60)
        ac.interceptRunway = "09"
        ac.altitudeFeet = 6000

        LocalizerGuidanceService.guide(&ac, runways: [rwy])

        #expect(ac.interceptRunway == "09")                // still on the approach
        #expect(ac.targetSpeedKnots == LocalizerGuidanceService.approachSpeedKnots)
        #expect(ac.targetAltitudeFeet != nil)
        #expect(ac.targetAltitudeFeet! <= ac.altitudeFeet) // only ever descends
        #expect(ac.targetHeading != nil)
    }

    @Test func guideAbandonsApproachAfterOvershoot() {
        let (rwy, t) = setup()
        // Past the threshold (east of it) but still airborne.
        var ac = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 1, bearing: 90), heading: 90)
        ac.interceptRunway = "09"
        ac.altitudeFeet = 1500

        LocalizerGuidanceService.guide(&ac, runways: [rwy])

        #expect(ac.interceptRunway == nil)                 // missed approach → clearance dropped
        #expect(ac.targetAltitudeFeet == nil)
        #expect(ac.targetHeading != nil)                   // flies straight ahead on inbound
    }
}
