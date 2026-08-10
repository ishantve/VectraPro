//
//  AircraftCollisionDetectorTests.swift
//  VectraProTests
//
//  Aircraft-to-aircraft proximity/collision detection — safety-critical core.
//

import Testing
import ATCSimKit
import CoreLocation
@testable import VectraPro

@MainActor
struct AircraftCollisionDetectorTests {

    private let detector = AircraftCollisionDetector.shared

    /// Two aircraft `nm` apart (east), same altitude unless overridden.
    private func pair(nm: Double, altA: Double = 18_000, altB: Double = 18_000)
        -> (Aircraft, Aircraft) {
        var a = Fixtures.aircraft("A", at: Fixtures.center, heading: 0)
        var b = Fixtures.aircraft("B", at: Fixtures.offsetNM(from: Fixtures.center, nm: nm, bearing: 90),
                                  heading: 0)
        a.altitudeFeet = altA; b.altitudeFeet = altB
        return (a, b)
    }

    @Test func farApartHasNoConflict() {
        let (a, b) = pair(nm: 20)
        let r = detector.detectConflicts(in: [a, b])
        #expect(r.yellows.isEmpty && r.reds.isEmpty && r.destroyed.isEmpty)
    }

    @Test func withinFiveMilesFlagsYellowButNotRed() {
        let (a, b) = pair(nm: 4)               // 4 < 2.5+2.5, but > 3
        let r = detector.detectConflicts(in: [a, b])
        #expect(r.yellows.contains(a.id) && r.yellows.contains(b.id))
        #expect(r.reds.isEmpty)
        #expect(r.destroyed.isEmpty)
    }

    @Test func withinThreeMilesFlagsRed() {
        let (a, b) = pair(nm: 2)
        let r = detector.detectConflicts(in: [a, b])
        #expect(r.reds.contains(a.id) && r.reds.contains(b.id))
        #expect(r.yellows.contains(a.id))     // red implies yellow too
    }

    @Test func verticalSeparationSuppressesProximityFlags() {
        let (a, b) = pair(nm: 2, altA: 18_000, altB: 20_000)   // 2000 ft apart ≥ 1000
        let r = detector.detectConflicts(in: [a, b])
        #expect(r.yellows.isEmpty && r.reds.isEmpty)
    }

    @Test func verticalSeparationPreventsBodyCollision() {
        // Footprints overlap horizontally, but 2000 ft apart vertically → no crash.
        let (a, b) = pair(nm: 0.3, altA: 18_000, altB: 20_000)
        let r = detector.detectConflicts(in: [a, b])
        #expect(r.destroyed.isEmpty)
        #expect(r.yellows.isEmpty && r.reds.isEmpty)
    }

    @Test func overlappingCollidersDestroyBoth() {
        // ~0.3 NM apart, same heading → body diamonds overlap.
        let (a, b) = pair(nm: 0.3)
        let r = detector.detectConflicts(in: [a, b])
        #expect(r.destroyed.contains(a.id) && r.destroyed.contains(b.id))
        // Destroyed pairs skip the proximity flags.
        #expect(!r.yellows.contains(a.id))
    }

    @Test func singleAircraftHasNoConflict() {
        let solo = Fixtures.aircraft("SOLO")
        let r = detector.detectConflicts(in: [solo])
        #expect(r.yellows.isEmpty && r.reds.isEmpty && r.destroyed.isEmpty)
    }
}
