//
//  CallsignResolverTests.swift
//  VectraProTests
//

import Testing
@testable import VectraPro

@MainActor
struct CallsignResolverTests {

    @Test func directMatchOnCallsign() {
        let candidates = [Fixtures.aircraft("ACA29")]
        #expect(CallsignResolver.resolve(from: "aca29", among: candidates, airlines: []) == "ACA29")
    }

    @Test func directMatchWithSpaceBetweenLettersAndDigits() {
        let candidates = [Fixtures.aircraft("ACA29")]
        #expect(CallsignResolver.resolve(from: "aca 29", among: candidates, airlines: []) == "ACA29")
    }

    @Test func spokenAirlineNamePlusFlightNumber() {
        let candidates = [Fixtures.aircraft("AIC235")]
        let airlines = [Fixtures.airline("AIC", "AIR INDIA")]
        #expect(CallsignResolver.resolve(from: "air india 235", among: candidates, airlines: airlines) == "AIC235")
    }

    @Test func airlineMatchRequiresAnExistingCandidate() {
        // Spoken airline + number, but no such aircraft in the candidate list.
        let candidates = [Fixtures.aircraft("AIC999")]
        let airlines = [Fixtures.airline("AIC", "AIR INDIA")]
        #expect(CallsignResolver.resolve(from: "air india 235", among: candidates, airlines: airlines) == nil)
    }

    @Test func noMatchReturnsNil() {
        let candidates = [Fixtures.aircraft("ACA29")]
        #expect(CallsignResolver.resolve(from: "hello world", among: candidates, airlines: []) == nil)
    }
}
