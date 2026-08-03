//
//  IsolatedDeinitScanTests.swift
//  VectraProTests
//
//  Constructs and releases every app class that is not a never-freed singleton.
//
//  The app target is @MainActor by default, which makes each class's implicit deinit
//  an isolated one, and the runtime hops an isolated deinit onto the main executor.
//  That hop aborted the process for RadialManager. Singletons hid the problem by
//  never being released; anything created per screen or per view is released for
//  real, so this walks them all and would abort here rather than in front of a user.
//

import XCTest
@testable import VectraPro

@MainActor
final class IsolatedDeinitScanTests: XCTestCase {

    func testLoginViewModelSurvivesRelease() {
        for _ in 0..<3 { _ = LoginViewModel() }
        XCTAssertTrue(true, "released without aborting")
    }

    func testHomeViewModelSurvivesRelease() {
        for _ in 0..<3 { _ = HomeViewModel() }
        XCTAssertTrue(true)
    }

    func testMapViewModelSurvivesRelease() {
        for _ in 0..<3 { _ = MapViewModel() }
        XCTAssertTrue(true)
    }

    func testCommandControllerSurvivesRelease() {
        let viewModel = MapViewModel()
        for _ in 0..<3 { _ = CommandController(mapViewModel: viewModel) }
        XCTAssertTrue(true)
    }

    func testAirtableConfigSurvivesRelease() {
        for _ in 0..<3 {
            _ = AirtableConfig(id: 1, organizationID: "org", authURL: "a", apiURL: "b",
                               analyticsID: 2, analyticsURL: "c", issuerURL: "d",
                               eramClientSecret: nil, eramClientID: nil,
                               eramRedirectURL: nil, nickname: "n",
                               basicVectoringClientID: "e", basicVectoringSecret: "f",
                               stratagemMobileID: "g", stratagemMobileSecret: "h",
                               metricsURL: "i", chatBotURL: "j", showIvyIcon: true,
                               savedAt: Date())
        }
        XCTAssertTrue(true)
    }

    /// The third singleton to be constructed per-session by tests, and the third to need a nonisolated
    /// deinit. The pattern is now clear enough to state: **any `final class` in this target that was a
    /// singleton has an untested deinit**, because a singleton is never released.
    func testCommandKeyboardHandlerSurvivesRelease() {
        for _ in 0..<3 { _ = CommandKeyboardHandler() }
    }

    /// Added after a determinism test crashed the process here. The spawner had always been a
    /// singleton, so it was never released and its isolated deinit never ran — the first code to
    /// create one per simulation found it immediately.
    func testAircraftSpawnerSurvivesRelease() {
        for _ in 0..<3 { _ = AircraftSpawner() }
    }

    func testRadialManagerSurvivesRelease() {
        // The one that actually aborted, kept as a regression guard.
        for _ in 0..<3 { _ = RadialManager() }
        XCTAssertTrue(true)
    }
}
