//
//  AircraftPhysicsTests.swift
//  VectraProTests
//
//  Core motion: turn-toward-target, speed & altitude ramps, and position
//  advance. Pure per-step maths that the whole simulation depends on.
//

import Testing
import GeoKit
import CoreLocation
@testable import VectraPro

@MainActor
struct AircraftPhysicsTests {

    private let physics = AircraftPhysics.shared

    // MARK: turn

    @Test func turnsTowardTargetWithoutOvershooting() {
        var ac = Fixtures.aircraft(heading: 0)
        ac.speedKnots = 250
        ac.targetHeading = 90

        physics.stepPhysics(&ac, dt: 1)

        #expect(ac.headingDegrees > 0)          // moved toward the target
        #expect(ac.headingDegrees < 90)         // but did not overshoot in one step
        #expect(ac.targetHeading == 90)         // still turning
    }

    @Test func snapsToTargetHeadingWhenWithinOneStep() {
        var ac = Fixtures.aircraft(heading: 89)
        ac.speedKnots = 250
        ac.targetHeading = 90

        physics.stepPhysics(&ac, dt: 1)

        #expect(abs(ac.headingDegrees - 90) < 0.001)
        #expect(ac.targetHeading == nil)        // turn complete → cleared
        #expect(ac.turnDirection == nil)
    }

    @Test func forcedTurnDirectionOverridesShortestWay() {
        // Shortest way from 10° to 350° is left (−20°); force a right turn instead.
        var ac = Fixtures.aircraft(heading: 10)
        ac.speedKnots = 250
        ac.targetHeading = 350
        ac.turnDirection = .right

        physics.stepPhysics(&ac, dt: 1)

        #expect(ac.headingDegrees > 10)         // went right (increasing), the long way
    }

    // MARK: speed

    @Test func acceleratesAndDeceleratesTowardTargetSpeed() {
        var climb = Fixtures.aircraft(); climb.speedKnots = 200; climb.targetSpeedKnots = 260
        physics.stepPhysics(&climb, dt: 1)
        #expect(climb.speedKnots > 200 && climb.speedKnots < 260)

        var slow = Fixtures.aircraft(); slow.speedKnots = 260; slow.targetSpeedKnots = 200
        physics.stepPhysics(&slow, dt: 1)
        #expect(slow.speedKnots < 260 && slow.speedKnots > 200)
    }

    @Test func snapsToTargetSpeedWhenClose() {
        var ac = Fixtures.aircraft(); ac.speedKnots = 259; ac.targetSpeedKnots = 260
        physics.stepPhysics(&ac, dt: 1)
        #expect(ac.speedKnots == 260)
        #expect(ac.targetSpeedKnots == nil)
    }

    // MARK: altitude

    @Test func climbsAndDescendsTowardTargetAltitude() {
        var climb = Fixtures.aircraft(); climb.altitudeFeet = 10_000; climb.targetAltitudeFeet = 12_000
        physics.stepPhysics(&climb, dt: 1)
        #expect(climb.altitudeFeet > 10_000 && climb.altitudeFeet < 12_000)

        var descend = Fixtures.aircraft(); descend.altitudeFeet = 10_000; descend.targetAltitudeFeet = 8_000
        physics.stepPhysics(&descend, dt: 1)
        #expect(descend.altitudeFeet < 10_000 && descend.altitudeFeet > 8_000)
    }

    // MARK: position

    @Test func advancesPositionAlongHeadingAtGroundSpeed() {
        var ac = Fixtures.aircraft(at: Fixtures.center, heading: 90)
        ac.speedKnots = 250                     // no targets → straight & level

        let start = ac.position
        physics.stepPhysics(&ac, dt: 1)

        // 250 kt for 1 s ≈ 128.6 m.
        let moved = Geo.distanceMeters(from: start, to: ac.position)
        let expected = 250 * Distance.metersPerNauticalMile / 3600
        #expect(abs(moved - expected) < 2.0)
        // …heading roughly east.
        #expect(abs(Geo.bearing(from: start, to: ac.position) - 90) < 1.0)
    }
}
