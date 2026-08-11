//
//  DeterminismSelfCheckTests.swift
//  VectraProTests
//
//  Runs the self-check on the **iOS simulator**. `ATCSimKitTests` runs the same check on **macOS**,
//  against the same compiled-in constant.
//
//  This pair is the cross-platform measurement the replay architecture called for. The concern was
//  concrete: an assessment is recorded on an iPad and reviewed by an instructor on whatever device
//  they have, and every aircraft position in this simulator comes out of great-circle maths whose
//  `sin`, `cos` and `atan2` are library functions rather than hardware instructions. If those differ
//  by a last bit between platforms, a replay is not quite what the trainee flew.
//
//  Two suites, two platforms, one expected value. Whichever platform disagrees, its suite fails, and
//  we find out from CI rather than from an instructor scoring the wrong thing.
//

import XCTest
import ATCSimKit
@testable import VectraPro

final class DeterminismSelfCheckTests: XCTestCase {

    /// The iOS half of the measurement.
    func testTheSimulatorAgreesWithTheRecordedFingerprint() {
        XCTAssertEqual(DeterminismSelfCheck.run(), .matches, """
            iOS produced \(String(format: "0x%016llX", DeterminismSelfCheck.fingerprint())), \
            macOS expects \(String(format: "0x%016llX", DeterminismSelfCheck.expectedFingerprint)).

            If only this suite fails, the two platforms compute the simulation's floating-point maths \
            differently, and a session recorded on one cannot be scored against a replay on the other \
            — which is the case the architecture treats as unscoreable rather than as a bug to paper \
            over. If both suites fail, the physics changed and every existing recording is invalidated.
            """)
    }

    /// The check is what would gate scoring on a device, so the answer it gives has to be usable
    /// without inspecting the fingerprint.
    func testATrustworthyPlatformSaysSo() {
        XCTAssertTrue(DeterminismSelfCheck.run().isTrustworthy)
    }
}
