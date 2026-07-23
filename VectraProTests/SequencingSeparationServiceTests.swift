//
//  SequencingSeparationServiceTests.swift
//  VectraProTests
//

import Testing
@testable import VectraPro

@MainActor
struct SequencingSeparationServiceTests {

    private let types = [
        Fixtures.type("LGT", wtc: "L"),
        Fixtures.type("B738", wtc: "M"),
        Fixtures.type("B77W", wtc: "H"),
    ]

    // MARK: wake category

    @Test func wakeCategoryFromType() {
        var heavy = Fixtures.aircraft(); heavy.aircraftType = "B77W"
        #expect(SequencingSeparationService.wakeCategory(heavy, aircraftTypes: types) == "H")
    }

    @Test func wakeCategoryDefaultsToMediumWhenUnknownOrMissing() {
        var unknown = Fixtures.aircraft(); unknown.aircraftType = "ZZZZ"
        #expect(SequencingSeparationService.wakeCategory(unknown, aircraftTypes: types) == "M")

        let noType = Fixtures.aircraft()   // aircraftType nil
        #expect(SequencingSeparationService.wakeCategory(noType, aircraftTypes: types) == "M")
    }

    // MARK: required separation

    @Test func requiredSeparationIs10IfEitherIsLight_else8() {
        var light = Fixtures.aircraft("L"); light.aircraftType = "LGT"
        var med   = Fixtures.aircraft("M"); med.aircraftType = "B738"
        var heavy = Fixtures.aircraft("H"); heavy.aircraftType = "B77W"

        #expect(SequencingSeparationService.requiredSeparationNM(light, med, aircraftTypes: types) == 10)
        #expect(SequencingSeparationService.requiredSeparationNM(light, light, aircraftTypes: types) == 10)
        #expect(SequencingSeparationService.requiredSeparationNM(med, heavy, aircraftTypes: types) == 8)
        #expect(SequencingSeparationService.requiredSeparationNM(heavy, heavy, aircraftTypes: types) == 8)
    }

    // MARK: conflicts

    /// Two medium aircraft 3 NM apart on the same runway (< 8 NM) → both flagged.
    @Test func tooCloseInTrailFlagsBoth() {
        let threshold = Fixtures.center
        let rwy = Fixtures.runway("09", at: threshold, "27", bearingAB: 90)

        var lead = Fixtures.aircraft("LEAD", at: Fixtures.offsetNM(from: threshold, nm: 3, bearing: 270))
        var follow = Fixtures.aircraft("FOLW", at: Fixtures.offsetNM(from: threshold, nm: 6, bearing: 270))
        lead.interceptRunway = "09"; follow.interceptRunway = "09"   // both mediums (nil type → M)

        let conflicts = SequencingSeparationService.conflicts(
            among: [lead, follow], runways: [rwy], aircraftTypes: types)
        #expect(conflicts.contains(lead.id))
        #expect(conflicts.contains(follow.id))
    }

    /// Same runway but 12 NM apart (> 8 NM) → no conflict.
    @Test func adequateSpacingFlagsNothing() {
        let threshold = Fixtures.center
        let rwy = Fixtures.runway("09", at: threshold, "27", bearingAB: 90)

        var lead = Fixtures.aircraft("LEAD", at: Fixtures.offsetNM(from: threshold, nm: 3, bearing: 270))
        var follow = Fixtures.aircraft("FOLW", at: Fixtures.offsetNM(from: threshold, nm: 15, bearing: 270))
        lead.interceptRunway = "09"; follow.interceptRunway = "09"

        let conflicts = SequencingSeparationService.conflicts(
            among: [lead, follow], runways: [rwy], aircraftTypes: types)
        #expect(conflicts.isEmpty)
    }

    /// A single aircraft on final can't conflict with anyone.
    @Test func singleAircraftHasNoConflict() {
        let rwy = Fixtures.runway("09", "27", bearingAB: 90)
        var solo = Fixtures.aircraft("SOLO", at: Fixtures.offsetNM(from: Fixtures.center, nm: 4, bearing: 270))
        solo.interceptRunway = "09"
        let conflicts = SequencingSeparationService.conflicts(
            among: [solo], runways: [rwy], aircraftTypes: types)
        #expect(conflicts.isEmpty)
    }

    /// Aircraft not on any localizer are ignored entirely.
    @Test func aircraftNotOnFinalAreIgnored() {
        let rwy = Fixtures.runway("09", "27", bearingAB: 90)
        let a = Fixtures.aircraft("A", at: Fixtures.offsetNM(from: Fixtures.center, nm: 3, bearing: 270))
        let b = Fixtures.aircraft("B", at: Fixtures.offsetNM(from: Fixtures.center, nm: 4, bearing: 270))
        // interceptRunway nil on both
        let conflicts = SequencingSeparationService.conflicts(
            among: [a, b], runways: [rwy], aircraftTypes: types)
        #expect(conflicts.isEmpty)
    }
}
