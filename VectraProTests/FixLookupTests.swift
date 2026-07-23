//
//  FixLookupTests.swift
//  VectraProTests
//

import Testing
import CoreLocation
@testable import VectraPro

@MainActor
struct FixLookupTests {

    @Test func canonicalKeepsOnlyLettersAndDigitsLowercased() {
        #expect(FixLookup.canonical("RE-01") == "re01")
        #expect(FixLookup.canonical("VI 95") == "vi95")
        #expect(FixLookup.canonical("Papa-Juliet") == "papajuliet")
    }

    @Test func fixMatchesToleranceOfHyphensAndCase() {
        let fixes = [Fixtures.fix("RE-01"), Fixtures.fix("VI-95")]
        #expect(FixLookup.fix(named: "re01", in: fixes)?.fixName == "RE-01")
        #expect(FixLookup.fix(named: "RE01", in: fixes)?.fixName == "RE-01")
        #expect(FixLookup.fix(named: "vi 95", in: fixes)?.fixName == "VI-95")
    }

    @Test func fixReturnsNilWhenNoMatch() {
        let fixes = [Fixtures.fix("RE-01")]
        #expect(FixLookup.fix(named: "ZZ99", in: fixes) == nil)
        #expect(FixLookup.fix(named: "re01", in: []) == nil)
    }

    @Test func positionReturnsCoordinateWhenPresent() {
        let fixes = [Fixtures.fix("RE-01", lat: 28.6, lon: 77.2)]
        let pos = FixLookup.position(named: "re01", in: fixes)
        #expect(pos != nil)
        #expect(abs(pos!.latitude - 28.6) < 1e-9)
        #expect(abs(pos!.longitude - 77.2) < 1e-9)
    }

    @Test func positionIsNilWhenFixLacksCoordinates() {
        let fixes = [Fixtures.fix("RE-01", lat: nil, lon: nil)]
        #expect(FixLookup.position(named: "re01", in: fixes) == nil)
    }
}
