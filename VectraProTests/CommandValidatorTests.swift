//
//  CommandValidatorTests.swift
//  VectraProTests
//

import Testing
import CoreLocation
@testable import VectraPro

@MainActor
struct CommandValidatorTests {

    private func context(runway: Runway? = nil,
                         activeLoc: Set<String> = [],
                         holdingFixes: [ExerciseDetail.Fix] = []) -> CommandValidator.Context {
        CommandValidator.Context(runways: runway.map { [$0] } ?? [],
                                 activeLocalizerRunways: activeLoc,
                                 holdingFixes: holdingFixes)
    }

    private func isRejected(_ r: CommandValidator.Result) -> Bool {
        if case .rejected = r { return true }; return false
    }

    // MARK: altitude

    @Test func flightLevelWithinRangeIsOK() {
        let r = CommandValidator.validate([.flightLevel(250)], for: Fixtures.aircraft(), context: context())
        #expect(r == .ok)
    }

    @Test func flightLevelOutOfRangeRejected() {
        #expect(isRejected(CommandValidator.validate([.flightLevel(600)], for: Fixtures.aircraft(), context: context())))
        #expect(isRejected(CommandValidator.validate([.flightLevel(2)],   for: Fixtures.aircraft(), context: context())))
    }

    @Test func blockAltitudeOutOfRangeRejected() {
        #expect(isRejected(CommandValidator.validate([.altitudeBlock(low: 5, high: 600)],
                                                     for: Fixtures.aircraft(), context: context())))
    }

    // MARK: speed

    @Test func speedWithinLimitsIsOK() {
        #expect(CommandValidator.validate([.speed(250)], for: Fixtures.aircraft(), context: context()) == .ok)
        #expect(CommandValidator.validate([.minSpeed(180)], for: Fixtures.aircraft(), context: context()) == .ok)
    }

    @Test func speedOutsideLimitsRejected() {
        #expect(isRejected(CommandValidator.validate([.speed(50)],  for: Fixtures.aircraft(), context: context())))
        #expect(isRejected(CommandValidator.validate([.speed(900)], for: Fixtures.aircraft(), context: context())))
        #expect(isRejected(CommandValidator.validate([.maxSpeed(600)], for: Fixtures.aircraft(), context: context())))
    }

    // MARK: relative turn

    @Test func relativeTurnBounds() {
        #expect(CommandValidator.validate([.relativeTurn(30, .left)], for: Fixtures.aircraft(), context: context()) == .ok)
        #expect(isRejected(CommandValidator.validate([.relativeTurn(270, .right)], for: Fixtures.aircraft(), context: context())))
    }

    // MARK: hold

    @Test func holdAtKnownFixIsOK() {
        let ctx = context(holdingFixes: [Fixtures.fix("RE-01")])
        #expect(CommandValidator.validate([.hold("re01")], for: Fixtures.aircraft(), context: ctx) == .ok)
    }

    @Test func holdAtUnknownFixRejected() {
        let ctx = context(holdingFixes: [Fixtures.fix("RE-01")])
        #expect(isRejected(CommandValidator.validate([.hold("zz99")], for: Fixtures.aircraft(), context: ctx)))
    }

    // MARK: intercept (delegates to LocalizerGuidanceService)

    @Test func interceptRejectedWhenLocalizerNotActive() {
        let t = Fixtures.center
        let rwy = Fixtures.runway("09", at: t, "27", bearingAB: 90)
        var ac = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 8, bearing: 270), heading: 90)
        ac.altitudeFeet = 3000
        // activeLoc empty → not active
        let r = CommandValidator.validate([.interceptLocalizer(runway: "09")], for: ac,
                                          context: context(runway: rwy, activeLoc: []))
        #expect(isRejected(r))
    }

    @Test func interceptOKWhenActiveEstablishedAndReachable() {
        let t = Fixtures.center
        let rwy = Fixtures.runway("09", at: t, "27", bearingAB: 90)
        var ac = Fixtures.aircraft(at: Fixtures.offsetNM(from: t, nm: 8, bearing: 270), heading: 90)
        ac.altitudeFeet = 3000     // on/near glide, established, low enough
        let r = CommandValidator.validate([.interceptLocalizer(runway: "09")], for: ac,
                                          context: context(runway: rwy, activeLoc: ["9"]))
        #expect(r == .ok)
    }

    // MARK: all-or-nothing

    @Test func firstFailureInUtteranceIsReported() {
        // Valid heading + invalid speed → rejected (nothing applied).
        let r = CommandValidator.validate([.heading(90), .speed(9000)],
                                          for: Fixtures.aircraft(), context: context())
        #expect(isRejected(r))
    }
}
