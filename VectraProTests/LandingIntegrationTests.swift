//
//  LandingIntegrationTests.swift
//  VectraProTests
//
//  Drives the full localizer approach (guide → physics → reachedRunway), the
//  same order as MapViewModel.advanceStep, to verify an aircraft on final
//  actually descends, tracks in, and lands.
//

import Testing
import GeoKit
import CoreLocation
@testable import VectraPro

@MainActor
struct LandingIntegrationTests {

    private struct Outcome {
        var landed = false
        var gaveUp = false          // guide cleared interceptRunway (missed approach)
        var ticks = 0
        var finalDistNM = 0.0
        var finalAltFt = 0.0
    }

    /// Fly `ac` down the approach for up to `maxTicks` seconds.
    private func fly(_ ac: Aircraft, runway rwy: Runway, threshold t: CLLocationCoordinate2D,
                     maxTicks: Int = 3000) -> Outcome {
        var ac = ac
        let physics = AircraftPhysics.shared
        var out = Outcome()
        for _ in 0..<maxTicks {
            out.ticks += 1
            LocalizerGuidanceService.guide(&ac, runways: [rwy])
            if ac.interceptRunway == nil { out.gaveUp = true; break }
            physics.stepPhysics(&ac, dt: 1)
            if LocalizerGuidanceService.reachedRunway(ac, runways: [rwy]) { out.landed = true; break }
        }
        out.finalDistNM = Geo.distanceMeters(from: ac.position, to: t) / Distance.metersPerNauticalMile
        out.finalAltFt = ac.altitudeFeet
        return out
    }

    @Test func onCentrelineAtGlideAltitudeLands() {
        let t = Fixtures.center
        let rwy = Fixtures.runway("09", at: t, "27", bearingAB: 90)
        var ac = Fixtures.aircraft("LAND1", at: Fixtures.offsetNM(from: t, nm: 8, bearing: 270), heading: 90)
        ac.interceptRunway = "09"
        ac.altitudeFeet = 8 * 320       // on the 3° glide for 8 NM
        ac.speedKnots = 180

        let o = fly(ac, runway: rwy, threshold: t)
        #expect(o.landed,
                "not landed — gaveUp=\(o.gaveUp) ticks=\(o.ticks) distNM=\(o.finalDistNM) alt=\(o.finalAltFt)")
    }

    @Test func interceptFromModerateAltitudeLands() {
        let t = Fixtures.center
        let rwy = Fixtures.runway("09", at: t, "27", bearingAB: 90)
        // 15 NM out, 7000 ft (above the ~4800 ft glide for 15 NM), 250 kt.
        var ac = Fixtures.aircraft("HIGH1", at: Fixtures.offsetNM(from: t, nm: 15, bearing: 270), heading: 90)
        ac.interceptRunway = "09"
        ac.altitudeFeet = 7000
        ac.speedKnots = 250
        let o = fly(ac, runway: rwy, threshold: t)
        #expect(o.landed,
                "not landed — gaveUp=\(o.gaveUp) ticks=\(o.ticks) distNM=\(o.finalDistNM) alt=\(o.finalAltFt)")
    }

    @Test func interceptFromHighButReachableAltitudeLands() {
        let t = Fixtures.center
        let rwy = Fixtures.runway("09", at: t, "27", bearingAB: 90)
        // 15 NM out at 12000 ft — high, but reachable with the steeper ILS descent.
        var ac = Fixtures.aircraft("HIGH2", at: Fixtures.offsetNM(from: t, nm: 15, bearing: 270), heading: 90)
        ac.interceptRunway = "09"
        ac.altitudeFeet = 12_000
        ac.speedKnots = 250
        let o = fly(ac, runway: rwy, threshold: t)
        #expect(o.landed,
                "not landed — gaveUp=\(o.gaveUp) ticks=\(o.ticks) distNM=\(o.finalDistNM) alt=\(o.finalAltFt)")
    }

    @Test func offCentrelineInterceptsAndLands() {
        let t = Fixtures.center
        let rwy = Fixtures.runway("09", at: t, "27", bearingAB: 90)
        // 8 NM out, 2 NM off to the side, on the glide.
        let foot = Fixtures.offsetNM(from: t, nm: 8, bearing: 270)
        var ac = Fixtures.aircraft("LAND2", at: Fixtures.offsetNM(from: foot, nm: 2, bearing: 0), heading: 90)
        ac.interceptRunway = "09"
        ac.altitudeFeet = 8 * 320
        ac.speedKnots = 180

        let o = fly(ac, runway: rwy, threshold: t)
        #expect(o.landed,
                "not landed — gaveUp=\(o.gaveUp) ticks=\(o.ticks) distNM=\(o.finalDistNM) alt=\(o.finalAltFt)")
    }
}
