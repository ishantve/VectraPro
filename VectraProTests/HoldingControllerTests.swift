//
//  HoldingControllerTests.swift
//  VectraProTests
//

import Testing
import CoreLocation
@testable import VectraPro

@MainActor
struct HoldingControllerTests {

    // MARK: steer

    @Test func steerTurnsTowardCommandedFix() {
        let fix = Fixtures.fix("REX", lat: 28.70, lon: 77.30)   // NE of centre
        var ac = Fixtures.aircraft(at: Fixtures.center, heading: 0)
        ac.holdingTargetName = "REX"

        HoldingController.steer(&ac, fixes: [fix])

        let expected = Geo.bearing(from: Fixtures.center, to: Fixtures.coord(28.70, 77.30))
        #expect(ac.targetHeading != nil)
        #expect(abs(ac.targetHeading! - expected) < 0.5)
        #expect(ac.turnDirection == nil)
    }

    @Test func steerDoesNothingWithoutHoldTarget() {
        let fix = Fixtures.fix("REX")
        var ac = Fixtures.aircraft()   // holdingTargetName nil
        HoldingController.steer(&ac, fixes: [fix])
        #expect(ac.targetHeading == nil)
    }

    // MARK: capture

    @Test func captureMovesAircraftToHoldingHangarWhenNoseReachesFix() {
        let fixCoord = Fixtures.coord(28.60, 77.20)
        let fix = Fixtures.fix("REX", lat: fixCoord.latitude, lon: fixCoord.longitude)

        // Nose reach = (noseOffsetNM + noseForwardNM) ≈ 1.84 NM ahead. Place the
        // aircraft that far south of the fix, heading north, so the nose hits it.
        let sample = Fixtures.aircraft()
        let noseReachNM = sample.noseOffsetNM + sample.noseForwardNM
        var ac = Fixtures.aircraft("HOLD1",
                                   at: Fixtures.offsetNM(from: fixCoord, nm: noseReachNM, bearing: 180),
                                   heading: 0)
        ac.holdingTargetName = "REX"

        var aircraft = [ac]
        var traffic: [Aircraft] = []
        let captured = HoldingController.capture(aircraft: &aircraft, traffic: &traffic, fixes: [fix])

        #expect(captured.contains(ac.id))
        #expect(aircraft.isEmpty)                       // removed from radar
        #expect(traffic.count == 1)                     // entered the hangar
        #expect(traffic.first?.holdingName == "REX")
        #expect(traffic.first?.holdingTargetName == nil)
        #expect(traffic.first?.holdingRadiusM ?? 0 > 0) // racetrack geometry seeded
    }

    @Test func captureIgnoresAircraftStillFarFromFix() {
        let fixCoord = Fixtures.coord(28.60, 77.20)
        let fix = Fixtures.fix("REX", lat: fixCoord.latitude, lon: fixCoord.longitude)
        var ac = Fixtures.aircraft("FAR",
                                   at: Fixtures.offsetNM(from: fixCoord, nm: 10, bearing: 180),
                                   heading: 0)
        ac.holdingTargetName = "REX"

        var aircraft = [ac]
        var traffic: [Aircraft] = []
        let captured = HoldingController.capture(aircraft: &aircraft, traffic: &traffic, fixes: [fix])

        #expect(captured.isEmpty)
        #expect(aircraft.count == 1)
        #expect(traffic.isEmpty)
    }

    // MARK: racetrack

    @Test func flyRacetracksAdvancesAHoldingAircraft() {
        let fixCoord = Fixtures.coord(28.60, 77.20)
        let fix = Fixtures.fix("REX", lat: fixCoord.latitude, lon: fixCoord.longitude)

        // Produce a holding aircraft via capture, then fly one step.
        let sample = Fixtures.aircraft()
        let noseReachNM = sample.noseOffsetNM + sample.noseForwardNM
        var ac = Fixtures.aircraft("HOLD1",
                                   at: Fixtures.offsetNM(from: fixCoord, nm: noseReachNM, bearing: 180),
                                   heading: 0)
        ac.holdingTargetName = "REX"

        var aircraft = [ac]
        var traffic: [Aircraft] = []
        _ = HoldingController.capture(aircraft: &aircraft, traffic: &traffic, fixes: [fix])
        #expect(traffic.count == 1)

        let before = traffic[0].holdingProgress
        HoldingController.flyRacetracks(traffic: &traffic, fixes: [fix],
                                        physics: AircraftPhysics.shared, dt: 1,
                                        sampleHistory: false, maxHistory: 500)

        #expect(traffic[0].holdingProgress > before)    // moved along the loop
    }
}
