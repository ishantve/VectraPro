//
//  SimulationStateHashTests.swift
//  ATCSimKitTests
//
//  What matters about the fingerprint: it is stable across processes, it notices real changes, and
//  it ignores things that are not changes.
//

import XCTest
import CoreLocation
@testable import ATCSimKit

final class SimulationStateHashTests: XCTestCase {

    private func aircraft(_ callsign: String,
                          lat: Double = 28.5,
                          lon: Double = 77.1,
                          heading: Double = 90,
                          id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        -> Aircraft {
        Aircraft(id: id,
                 callsign: callsign,
                 position: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                 headingDegrees: heading)
    }

    private func hash(_ radar: [Aircraft], hangar: [Aircraft] = [], tick: Int = 0) -> StateHash {
        StateHash(clock: SimulationClock(tick: tick), radar: radar, hangar: hangar)
    }

    // MARK: - Stability

    /// **The property everything else depends on.** The fingerprint of a fixed state must be the
    /// same number on every run and in every process — otherwise it cannot compare a live run
    /// against a recorded one.
    ///
    /// A hard-coded value is the only way to check this from inside one process, and it is what
    /// would catch someone reaching for Swift's `Hasher`: that is seeded randomly per process, so
    /// this test would fail immediately and loudly rather than the fingerprint quietly becoming
    /// useless for its actual purpose.
    func testTheFingerprintOfAFixedStateIsAConstant() {
        var ac = aircraft("AIC123")
        ac.altitudeFeet = 26_000
        ac.speedKnots = 300
        ac.targetHeading = 250

        XCTAssertEqual(hash([ac], tick: 42).value, 0x0C75_B1C1_E649_1675)
    }

    func testTheSameStateHashesTheSame() {
        XCTAssertEqual(hash([aircraft("AIC123")]), hash([aircraft("AIC123")]))
    }

    // MARK: - Sensitivity

    func testMovementChangesTheFingerprint() {
        // ~1 m north — well above the ~0.1 m quantisation, well below anything the simulation acts
        // on, so this is the smallest difference that should still register.
        XCTAssertNotEqual(hash([aircraft("A", lat: 28.5)]),
                          hash([aircraft("A", lat: 28.500009)]))
    }

    func testTimeChangesTheFingerprint() {
        XCTAssertNotEqual(hash([aircraft("A")], tick: 1), hash([aircraft("A")], tick: 2))
    }

    /// Intent counts, not only position. Two aircraft in the same place turning different ways have
    /// not converged, and a fingerprint that said they had would hide a real divergence.
    func testADifferentTargetChangesTheFingerprint() {
        var turning = aircraft("A")
        turning.targetHeading = 270
        XCTAssertNotEqual(hash([aircraft("A")]), hash([turning]))
    }

    /// An absent target is not the same as a target of zero — a heading of zero is a real heading.
    func testAnAbsentTargetDiffersFromZero() {
        var zero = aircraft("A")
        zero.targetHeading = 0
        XCTAssertNotEqual(hash([aircraft("A")]), hash([zero]))
    }

    /// An aircraft moving between the radar and the hangar — a hold captured, a departure rolling —
    /// is a change of state, so the two lists are hashed separately rather than concatenated.
    func testMovingBetweenRadarAndHangarChangesTheFingerprint() {
        let ac = aircraft("A")
        XCTAssertNotEqual(hash([ac], hangar: []), hash([], hangar: [ac]))
    }

    func testAMissingAircraftChangesTheFingerprint() {
        let a = aircraft("A", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let b = aircraft("B", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        XCTAssertNotEqual(hash([a, b]), hash([a]))
        XCTAssertEqual(hash([a, b]).aircraftCount, 2)
    }

    // MARK: - Deliberate blindness

    /// Array order is not state. Two runs that produced the same aircraft in a different order have
    /// not diverged in any way that matters, and reporting it would cry wolf.
    func testArrayOrderDoesNotMatter() {
        let a = aircraft("A", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let b = aircraft("B", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        XCTAssertEqual(hash([a, b]), hash([b, a]))
    }

    /// The trail is derived and presentational; so are the label offset and the collider size. A
    /// change to any of them must not look like the simulation diverging.
    func testPresentationStateIsIgnored() {
        var decorated = aircraft("A")
        decorated.history = [CLLocationCoordinate2D(latitude: 1, longitude: 1)]
        decorated.labelBearingDegrees = 180
        decorated.colliderRadiusNM = 9
        XCTAssertEqual(hash([aircraft("A")]), hash([decorated]))
    }

    /// Floating-point noise below the quantisation step is not divergence — this is what lets a
    /// device recording be compared against a simulator replay without a false alarm on every tick.
    func testNoiseBelowTheQuantisationStepIsIgnored() {
        XCTAssertEqual(hash([aircraft("A", heading: 90)]),
                       hash([aircraft("A", heading: 90.000000001)]))
    }

    /// A NaN in the state is itself a bug. It must surface as a divergence, not as a trap inside
    /// the check that was supposed to find it.
    func testANonFiniteValueDoesNotCrashTheCheck() {
        var broken = aircraft("A")
        broken.altitudeFeet = .nan
        XCTAssertNotEqual(hash([aircraft("A")]), hash([broken]))
    }
}
