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

    // MARK: V8 — 250 kt below the transition altitude

    @Test func highSpeedBelowTransitionRejected() {
        var low = Fixtures.aircraft(); low.altitudeFeet = 8_000
        #expect(isRejected(CommandValidator.validate([.speed(300)], for: low, context: context())))
    }

    @Test func highSpeedAboveTransitionIsOK() {
        var high = Fixtures.aircraft(); high.altitudeFeet = 18_000
        #expect(CommandValidator.validate([.speed(300)], for: high, context: context()) == .ok)
    }

    // MARK: V9 — aircraft state

    @Test func commandsRejectedDuringTakeoffRoll() {
        var rolling = Fixtures.aircraft()
        rolling.takeoffState = .groundRoll(runwayHeading: 90)
        #expect(isRejected(CommandValidator.validate([.speed(200)], for: rolling, context: context())))
    }

    @Test func holdRejectedWhileDeparting() {
        var climbing = Fixtures.aircraft()
        climbing.takeoffState = .climbout
        let ctx = context(holdingFixes: [Fixtures.fix("RE-01")])
        #expect(isRejected(CommandValidator.validate([.hold("re01")], for: climbing, context: ctx)))
    }

    // MARK: V11 — contradictory instructions

    @Test func conflictingHeadingInstructionsRejected() {
        let r = CommandValidator.validate([.presentHeading, .heading(90)],
                                          for: Fixtures.aircraft(), context: context())
        #expect(isRejected(r))
    }

    @Test func holdAndInterceptTogetherRejected() {
        let ctx = context(holdingFixes: [Fixtures.fix("RE-01")])
        let r = CommandValidator.validate([.hold("re01"), .interceptLocalizer(runway: "09")],
                                          for: Fixtures.aircraft(), context: ctx)
        #expect(isRejected(r))
    }

    // MARK: all-or-nothing

    @Test func firstFailureInUtteranceIsReported() {
        // Valid heading + invalid speed → rejected (nothing applied).
        let r = CommandValidator.validate([.heading(90), .speed(9000)],
                                          for: Fixtures.aircraft(), context: context())
        #expect(isRejected(r))
    }
}
