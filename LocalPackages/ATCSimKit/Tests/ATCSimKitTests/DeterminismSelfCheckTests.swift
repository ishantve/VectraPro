//
//  DeterminismSelfCheckTests.swift
//  ATCSimKitTests
//
//  Runs the self-check on **macOS**. `VectraProTests` runs it on the **iOS simulator**, against the
//  same compiled-in constant.
//
//  That pairing is the point: two platforms, one expected fingerprint. If the great-circle maths ever
//  computes differently between them, one of the two suites fails, and we learn it from CI rather
//  than from an instructor reviewing an assessment that is not what the trainee flew.
//

import XCTest
@testable import ATCSimKit

final class DeterminismSelfCheckTests: XCTestCase {

    /// The measurement the replay architecture asked for: does this platform agree?
    func testThisPlatformComputesTheSimulationAsExpected() {
        let result = DeterminismSelfCheck.run()
        XCTAssertEqual(result, .matches, """
            This platform produced \(String(format: "0x%016llX", DeterminismSelfCheck.fingerprint())) \
            instead of \(String(format: "0x%016llX", DeterminismSelfCheck.expectedFingerprint)).

            Either the physics changed — in which case every existing recording is invalidated and \
            the constant must be updated deliberately — or this platform computes floating-point \
            differently from the one the constant was generated on, which is exactly what this check \
            exists to detect. Do not paste the new value in to make this pass without deciding which.
            """)
    }

    /// The check must be repeatable within a process, or it cannot be repeatable across them.
    func testTheFingerprintIsStableWithinAProcess() {
        XCTAssertEqual(DeterminismSelfCheck.fingerprint(), DeterminismSelfCheck.fingerprint())
    }

    /// The scenario has to actually move, or the fingerprint would be of four stationary aircraft
    /// and would agree on every platform for the wrong reason.
    func testTheScenarioActuallyExercisesTheMaths() {
        XCTAssertGreaterThanOrEqual(DeterminismSelfCheck.steps, 100)
        // A stationary scenario would fingerprint the same as one stepped zero times.
        var clock = SimulationClock()
        for _ in 0..<DeterminismSelfCheck.steps { clock.advance() }
        XCTAssertNotEqual(DeterminismSelfCheck.fingerprint(),
                          StateHash(clock: clock, radar: [], hangar: []).value)
    }
}
